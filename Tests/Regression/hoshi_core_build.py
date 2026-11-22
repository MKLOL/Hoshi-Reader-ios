"""Build and link the pinned Hoshi Core for stand-alone Swift regression executables."""
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def swift_hoshi_core_flags() -> list[str]:
    source = Path(os.environ.get(
        "HOSHI_CORE_SOURCE",
        ROOT / "Dependencies/HoshiReaderAndroid/shared/hoshi-core",
    )).resolve()
    manifest = source / "Cargo.toml"
    if not manifest.is_file():
        raise RuntimeError("Hoshi Core source is missing. Run bash tools/prepare-hoshi-core.sh.")
    cargo_home = Path(os.environ.get("CARGO_HOME", Path.home() / ".cargo"))
    cargo = shutil.which("cargo") or str(cargo_home / "bin/cargo")
    target = ROOT / "build/shared-core-host"
    subprocess.run([
        cargo, "build", "--lib", "--release", "--locked", "--offline",
        "--manifest-path", str(manifest), "--target-dir", str(target),
    ], check=True, timeout=90)
    return [
        "-import-objc-header", str(source / "include/hoshi_core.h"),
        str(ROOT / "Features/SharedCore/HoshiCore.swift"),
        str(target / "release/libhoshi_core.a"),
    ]
