"""Curated GGUF catalog for the 32 GB RTX 5090, best-for-this-task first.

Sizing rule: weights must leave room for the KV cache and CUDA overhead. On a 32 GB card, keeping
weights at or under ~23 GB leaves a comfortable ~8 GB for a 16k-token context plus the runtime.

Why Qwen3.5 dense: it is the family the readers already use on-device, it has a native CJK
tokenizer (fewer tokens per Japanese line, so both cheaper and more accurate), and unlike the
translate-only Gemma build it both translates AND explains grammar — which is what the tutor
prompt asks for.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Callable

VRAM_BYTES_5090 = 32 * 1000**3


@dataclass(frozen=True)
class GgufModel:
    id: str
    display_name: str
    repo: str
    filename: str
    size_bytes: int
    context_length: int
    note: str
    recommended: bool = False

    @property
    def size_gb(self) -> float:
        return self.size_bytes / 1000**3

    def fits(self, vram_bytes: int = VRAM_BYTES_5090) -> bool:
        """True when weights plus a working KV cache should stay resident on the GPU."""
        return self.size_bytes + 4 * 1000**3 <= vram_bytes

    def label(self) -> str:
        tag = "  [recommended]" if self.recommended else ""
        fit = "" if self.fits() else "  [tight - may spill to CPU]"
        return f"{self.display_name} - {self.size_gb:.1f} GB{tag}{fit}"


CATALOG: list[GgufModel] = [
    GgufModel(
        id="qwen3.5-27b-q6k",
        display_name="Qwen3.5 27B  Q6_K",
        repo="unsloth/Qwen3.5-27B-GGUF",
        filename="Qwen3.5-27B-Q6_K.gguf",
        size_bytes=22_450_000_000,
        context_length=32768,
        note=(
            "Best quality that fully fits the 5090. Dense 27B at a near-lossless quant - the "
            "sweet spot for nuanced Japanese and grammar explanations."
        ),
        recommended=True,
    ),
    GgufModel(
        id="qwen3.5-27b-q5km",
        display_name="Qwen3.5 27B  Q5_K_M",
        repo="unsloth/Qwen3.5-27B-GGUF",
        filename="Qwen3.5-27B-Q5_K_M.gguf",
        size_bytes=19_610_000_000,
        context_length=32768,
        note="Same model, lighter quant. ~3 GB more headroom for context; a touch below Q6_K.",
    ),
    GgufModel(
        id="qwen3.5-27b-q8",
        display_name="Qwen3.5 27B  Q8_0",
        repo="unsloth/Qwen3.5-27B-GGUF",
        filename="Qwen3.5-27B-Q8_0.gguf",
        size_bytes=28_600_000_000,
        context_length=32768,
        note=(
            "Maximum quality, but only ~3 GB spare on a 32 GB card - keep the context small or "
            "it will spill into system RAM and crawl."
        ),
    ),
    GgufModel(
        id="qwen3.5-35b-a3b-q4km",
        display_name="Qwen3.5 35B-A3B  Q4_K_M (fast MoE)",
        repo="unsloth/Qwen3.5-35B-A3B-GGUF",
        filename="Qwen3.5-35B-A3B-Q4_K_M.gguf",
        size_bytes=22_020_000_000,
        context_length=32768,
        note=(
            "Mixture-of-experts: only ~3B parameters active per token, so several times faster "
            "than the dense 27B. Good if you want the whole library done overnight; slightly "
            "weaker on subtle Japanese."
        ),
    ),
    GgufModel(
        id="qwen3.5-9b-q6k",
        display_name="Qwen3.5 9B  Q6_K (quick test)",
        repo="unsloth/Qwen3.5-9B-GGUF",
        filename="Qwen3.5-9B-Q6_K.gguf",
        size_bytes=7_460_000_000,
        context_length=32768,
        note="Small and quick - use it to verify the pipeline end to end before a full run.",
    ),
]

DEFAULT_MODEL_ID = "qwen3.5-27b-q6k"


def by_id(model_id: str) -> GgufModel | None:
    return next((m for m in CATALOG if m.id == model_id), None)


def default_model() -> GgufModel:
    model = by_id(DEFAULT_MODEL_ID)
    assert model is not None
    return model


def local_path(model: GgufModel, models_dir: Path) -> Path:
    return models_dir / model.filename


def is_downloaded(model: GgufModel, models_dir: Path) -> bool:
    path = local_path(model, models_dir)
    if not path.exists():
        return False
    # A partially-downloaded GGUF is worse than a missing one: llama.cpp fails deep inside the
    # loader with an opaque error. Treat anything well short of the advertised size as absent.
    return path.stat().st_size >= int(model.size_bytes * 0.98)


def download_url(model: GgufModel) -> str:
    """Direct Hugging Face download URL (public repos need no auth; redirects to the CDN)."""
    return f"https://huggingface.co/{model.repo}/resolve/main/{model.filename}?download=true"


def download(
    model: GgufModel,
    models_dir: Path,
    log: Callable[[str], None] = print,
    progress: Callable[[int, int], None] | None = None,
    should_stop: Callable[[], bool] = lambda: False,
) -> Path:
    """Downloads the GGUF, resuming a partial file, and returns its local path.

    Written directly against `requests` rather than `huggingface_hub` for two reasons: the hub
    client writes a tqdm bar to stderr, which is `None` under `pythonw.exe` and crashed the whole
    download with "NoneType has no attribute write"; and a 22 GB transfer needs visible progress
    plus a resume that survives closing the app.
    """
    import requests

    models_dir.mkdir(parents=True, exist_ok=True)
    target = local_path(model, models_dir)
    if is_downloaded(model, models_dir):
        log(f"Model already present: {target.name}")
        return target

    partial = target.with_suffix(target.suffix + ".part")
    done = partial.stat().st_size if partial.exists() else 0
    headers = {}
    if done:
        # Resume where the last attempt stopped instead of re-fetching tens of GB.
        headers["Range"] = f"bytes={done}-"
        log(f"Resuming {model.filename} at {done / 1e9:.2f} GB ...")
    else:
        log(f"Downloading {model.filename} ({model.size_gb:.1f} GB) from {model.repo} ...")

    with requests.get(download_url(model), headers=headers, stream=True, timeout=(30, 300)) as response:
        if done and response.status_code == 200:
            # Server ignored the Range header — start over rather than corrupting the file by
            # appending a second copy of the whole body to it.
            done = 0
            partial.unlink(missing_ok=True)
        elif done and response.status_code == 416:
            # Already have every byte; fall through to the rename below.
            response.close()
            partial.replace(target)
            log(f"Downloaded to {target}")
            return target
        response.raise_for_status()

        total = done + int(response.headers.get("Content-Length") or 0)
        mode = "ab" if done else "wb"
        last_report = done
        with open(partial, mode) as handle:
            for chunk in response.iter_content(chunk_size=1 << 20):
                if should_stop():
                    log("Download stopped — run Download again to resume where it left off.")
                    return target
                handle.write(chunk)
                done += len(chunk)
                if progress is not None:
                    progress(done, total)
                if done - last_report >= (1 << 28):  # log about every 256 MB
                    last_report = done
                    log(f"  {done / 1e9:.1f} / {total / 1e9:.1f} GB")

    if total and done < total:
        raise RuntimeError(
            f"Download ended early ({done / 1e9:.2f} of {total / 1e9:.2f} GB). "
            "Press Download again to resume."
        )
    partial.replace(target)
    log(f"Downloaded to {target}")
    return target
