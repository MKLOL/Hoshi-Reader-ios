"""Manages the llama.cpp CUDA runtime on Windows.

Why the prebuilt server instead of `llama-cpp-python`: the RTX 5090 is Blackwell (sm_120), which
needs CUDA 12.8+ kernels. The pip wheels lag behind and building from source would mean installing
Visual Studio Build Tools plus the full CUDA toolkit. The official llama.cpp release ships a
ready-made Windows CUDA 13.3 build together with the CUDA runtime DLLs, so setup is "unzip and
run" and it supports the card out of the box.

We start `llama-server.exe` as a child process and talk to its OpenAI-compatible HTTP API.
"""

from __future__ import annotations

import os
import platform
import subprocess
import time
import urllib.request
import zipfile
from pathlib import Path
from typing import Callable

import requests

LLAMA_RELEASE = "b10182"
CUDA_TAG = "cuda-13.3"
_BASE = f"https://github.com/ggml-org/llama.cpp/releases/download/{LLAMA_RELEASE}"

# The server binary plus the CUDA runtime DLLs it links against.
ASSETS = [
    f"llama-{LLAMA_RELEASE}-bin-win-{CUDA_TAG}-x64.zip",
    f"cudart-llama-bin-win-{CUDA_TAG}-x64.zip",
]

# High port to avoid colliding with anything already listening (Ollama, dev servers).
DEFAULT_PORT = 18080


def runtime_dir(base: Path) -> Path:
    return base / f"llama.cpp-{LLAMA_RELEASE}-{CUDA_TAG}"


def server_exe(base: Path) -> Path:
    name = "llama-server.exe" if platform.system() == "Windows" else "llama-server"
    return runtime_dir(base) / name


def is_installed(base: Path) -> bool:
    return server_exe(base).exists()


def install(base: Path, log: Callable[[str], None] = print) -> Path:
    """Downloads and unpacks the llama.cpp CUDA build. Returns the server executable path."""
    target = runtime_dir(base)
    if is_installed(base):
        log("llama.cpp CUDA runtime already installed.")
        return server_exe(base)

    target.mkdir(parents=True, exist_ok=True)
    for asset in ASSETS:
        url = f"{_BASE}/{asset}"
        archive = target / asset
        if not archive.exists():
            log(f"Downloading {asset} (this can take a few minutes) ...")
            # Download to a .part file and rename only on success. Writing straight to the final
            # name would leave a truncated zip behind after any interruption, and the
            # `if not archive.exists()` check above would then skip re-downloading it forever —
            # bricking setup with an unexplained BadZipFile on every subsequent run.
            partial = archive.with_suffix(archive.suffix + ".part")
            try:
                with urllib.request.urlopen(url, timeout=120) as response, open(partial, "wb") as handle:
                    downloaded = 0
                    total = int(response.headers.get("Content-Length") or 0)
                    next_report = 1 << 25  # log roughly every 32 MB so a stall is visible
                    while chunk := response.read(1 << 20):
                        handle.write(chunk)
                        downloaded += len(chunk)
                        if downloaded >= next_report:
                            next_report += 1 << 25
                            if total:
                                log(f"  {downloaded / 1e6:.0f} / {total / 1e6:.0f} MB")
                            else:
                                log(f"  {downloaded / 1e6:.0f} MB")
                partial.replace(archive)
            except BaseException:
                partial.unlink(missing_ok=True)
                raise
        log(f"Extracting {asset} ...")
        with zipfile.ZipFile(archive) as zf:
            zf.extractall(target)
        archive.unlink(missing_ok=True)

    # Some releases nest the binaries one level down; flatten so server_exe() resolves.
    if not server_exe(base).exists():
        for candidate in target.rglob("llama-server*"):
            for item in candidate.parent.iterdir():
                item.replace(target / item.name)
            break
    if not server_exe(base).exists():
        raise RuntimeError(f"llama-server was not found under {target} after extraction.")
    log("llama.cpp CUDA runtime ready.")
    return server_exe(base)


class LlamaServer:
    """Starts llama-server.exe with a model loaded and shuts it down on exit."""

    def __init__(
        self,
        base: Path,
        model_path: Path,
        n_ctx: int = 16384,
        port: int = DEFAULT_PORT,
        n_gpu_layers: int = 999,
        log: Callable[[str], None] = print,
    ) -> None:
        self.exe = server_exe(base)
        if not self.exe.exists():
            raise RuntimeError("llama.cpp runtime is not installed. Run setup.bat first.")
        self.model_path = model_path
        self.port = port
        self.base_url = f"http://127.0.0.1:{port}"
        self._log = log
        self._process: subprocess.Popen | None = None
        self._args = [
            str(self.exe),
            "-m", str(model_path),
            "-c", str(n_ctx),
            "-ngl", str(n_gpu_layers),   # offload every layer to the GPU
            "--host", "127.0.0.1",
            "--port", str(port),
            "-fa", "on",                  # flash attention
            "--no-webui",
            # Re-use the cached prefix when consecutive requests share a long identical prompt
            # head. In focused mode every bubble on a page shares the page context, so this is
            # the difference between re-reading the page once and re-reading it per bubble.
            "--cache-reuse", "256",
            # Qwen3.5 thinks by default and reasoning tokens are billed against the reply budget.
            # Belt and braces with the per-request chat_template_kwargs in llm.py.
            "--reasoning-budget", "0",
        ]

    def _port_in_use(self) -> bool:
        import socket

        with socket.socket() as probe:
            probe.settimeout(0.5)
            return probe.connect_ex(("127.0.0.1", self.port)) == 0

    def _loaded_model(self) -> str | None:
        """The model path llama-server reports, used to catch attaching to a stale server."""
        try:
            props = requests.get(f"{self.base_url}/props", timeout=5).json()
        except (requests.RequestException, ValueError):
            return None
        return props.get("model_path") or props.get("default_generation_settings", {}).get("model")

    def start(self, timeout: float = 600.0) -> None:
        # A previous run that was closed with the window X leaves llama-server.exe alive holding
        # the GPU. The new process then fails to bind the port while the old one still answers
        # /health, so without this check we would happily translate the whole library with the
        # PREVIOUS model while stamping the blobs with the newly selected one.
        if self._port_in_use():
            raise RuntimeError(
                f"Port {self.port} is already in use — most likely a llama-server.exe left over "
                "from an earlier run. Close it (Task Manager > llama-server.exe) and try again."
            )
        self._log(f"Starting llama-server on port {self.port} ...")
        creation = subprocess.CREATE_NO_WINDOW if platform.system() == "Windows" else 0
        self._process = subprocess.Popen(
            self._args,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            cwd=str(self.exe.parent),
            creationflags=creation,
            env={**os.environ, "PATH": f"{self.exe.parent};{os.environ.get('PATH', '')}"},
        )
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self._process.poll() is not None:
                raise RuntimeError(
                    f"llama-server exited immediately (code {self._process.returncode}). "
                    "The model may be too large for the GPU."
                )
            try:
                health = requests.get(f"{self.base_url}/health", timeout=2)
                if health.status_code == 200:
                    loaded = self._loaded_model()
                    if loaded and Path(loaded).name != self.model_path.name:
                        self.stop()
                        raise RuntimeError(
                            f"llama-server is serving {Path(loaded).name}, not "
                            f"{self.model_path.name}. Close the stray server and retry."
                        )
                    self._log("Model loaded and server ready.")
                    return
            except requests.RequestException:
                pass
            time.sleep(1.0)
        self.stop()
        raise RuntimeError("llama-server did not become ready in time.")

    def stop(self) -> None:
        if self._process and self._process.poll() is None:
            self._process.terminate()
            try:
                self._process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                self._process.kill()
        self._process = None

    def __enter__(self) -> "LlamaServer":
        self.start()
        return self

    def __exit__(self, *_exc) -> None:
        self.stop()
