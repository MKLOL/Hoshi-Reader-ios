#!/usr/bin/env python3
"""Run the real-server iOS regression gate on a newly created disposable simulator."""
import json
import importlib.util
import os
import shlex
import shutil
from pathlib import Path
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]


def require_dependencies():
    if importlib.util.find_spec("regex") is None:
        raise RuntimeError(
            "The regression gate requires the pretranslation tool's regex dependency. "
            "Activate a Python virtual environment and run: python -m pip install 'regex>=2024.5.15'"
        )
    missing = [tool for tool in ("xcodebuild", "xcrun", "swift", "swiftc", "node") if not shutil.which(tool)]
    if missing:
        raise RuntimeError("The full regression gate requires these commands on PATH: " + ", ".join(missing))


def simulator_type(runtimes):
    available = sorted(
        (r for r in runtimes if r.get("isAvailable") and ".iOS-" in r["identifier"]),
        key=lambda r: tuple(int(p) for p in r["version"].split(".")), reverse=True,
    )
    for runtime in available:
        for device in runtime.get("supportedDeviceTypes", []):
            if device.get("productFamily") == "iPhone":
                return device["identifier"], runtime["identifier"]
    raise RuntimeError("Install an iOS simulator runtime in Xcode before running the regression gate.")


def main():
    require_dependencies()
    listing = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "runtimes", "-j"], text=True))
    device_type, runtime = simulator_type(listing["runtimes"])
    name = "Hoshi regression iPhone " + uuid.uuid4().hex[:8]
    device = subprocess.check_output(["xcrun", "simctl", "create", name, device_type, runtime], text=True).strip()
    if not device:
        raise RuntimeError("Simulator creation returned no device ID.")
    env = dict(os.environ, HOSHI_IOS_SIMULATOR=name)
    # The release gate always runs the complete hosted suite, regardless of shell test filters.
    env["HOSHI_XCODEBUILD_ARGS"] = (
        "-IDEPackageEnablePrebuilts=NO CODE_SIGN_IDENTITY=- "
        "-parallel-testing-enabled NO -collect-test-diagnostics never"
    )
    try:
        for suite in ("tools/sync-test-server", "Tests/Regression"):
            tests = subprocess.run(
                [sys.executable, "-m", "unittest", "discover", "-s", suite, "-v"],
                cwd=ROOT, env=env, check=False,
            )
            if tests.returncode:
                return tests.returncode
        command = [
            "xcodebuild", "test", "-project", "Hoshi Reader.xcodeproj", "-scheme", "HoshiReaderUITests",
            "-destination", f"platform=iOS Simulator,id={device}",
            "-derivedDataPath", env.get("HOSHI_DERIVED_DATA", str(ROOT / "build/DD-sim")),
            "-only-testing:HoshiReaderUITests/PodcastTranscriptUITests",
        ] + shlex.split(env["HOSHI_XCODEBUILD_ARGS"])
        log = ROOT / "build/ios-podcast-ui.log"
        log.parent.mkdir(parents=True, exist_ok=True)
        with log.open("w") as output:
            ui = subprocess.run(command, cwd=ROOT, env=env, stdout=output, stderr=subprocess.STDOUT, check=False, timeout=900)
        output = log.read_text()
        required = ("testTimestampPlaybackWordLookupEnglishAndFollowing", "testReaderAppearanceIsAvailableInsideTranscript")
        passed = all(any("PodcastTranscriptUITests" in line and method in line and "passed" in line
                         for line in output.splitlines()) for method in required)
        if ui.returncode or "** TEST SUCCEEDED **" not in output or not passed:
            print(f"Podcast UI regression gate failed; see {log}", file=sys.stderr)
            return ui.returncode or 1
        return 0
    finally:
        # Never erase, replace, or select a developer's existing simulator.
        subprocess.run(["xcrun", "simctl", "shutdown", device], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        subprocess.run(["xcrun", "simctl", "delete", device], check=True)


if __name__ == "__main__":
    raise SystemExit(main())
