# iOS ⇄ server integration: the production sync stack in the simulator against a real server.
#
# Boots tools/sync-test-server/sync_test_server.py, hands its address to the HoshiReaderTests
# XCTest bundle (Tests/Integration/SyncIntegrationTests.swift), and runs it with xcodebuild on
# an iOS simulator. The bundle drives HttpSyncManager against the server, seeded with the corpus
# the ANDROID client published (Tests/Fixtures/sync-corpus.json — regenerate it from the Android
# repo with HOSHI_SYNC_CORPUS_OUT=... ./gradlew :app:testDebugUnitTest --tests '*SyncCorpusSnapshotTest*').
#
# Requires Xcode with an available iPhone simulator. Set HOSHI_IOS_SIMULATOR to a device name to
# pick a specific one, HOSHI_DERIVED_DATA to reuse a derived-data directory (default build/DD-sim).
#
# WARNING: the scenarios simulate fresh installs, so they WIPE the app's book library and sync
# settings on the simulator they run on. Without HOSHI_IOS_SIMULATOR the runner therefore picks a
# shut-down device, never one that is currently booted.

import json
import os
import re
import shutil
import subprocess
import sys
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SERVER = ROOT / "tools" / "sync-test-server" / "sync_test_server.py"
CORPUS = ROOT / "Tests" / "Fixtures" / "sync-corpus.json"
PROJECT = ROOT / "Hoshi Reader.xcodeproj"
SCHEME = "Hoshi Reader"
TEST_BUNDLE = "HoshiReaderTests"
TOKEN = "ios-integration-token"


MANGA_SYNC_ID = "integration_manga"
NOVEL_SYNC_ID = "integration_novel"


def runtime_version(runtime: str) -> tuple[int, ...]:
    """`com.apple.CoreSimulator.SimRuntime.iOS-18-6` -> (18, 6)."""
    return tuple(int(part) for part in re.findall(r"\d+", runtime.rsplit("iOS", 1)[-1]))


def pick_simulator() -> str | None:
    """The simulator to test on.

    `HOSHI_IOS_SIMULATOR` names one explicitly. Otherwise prefer a SHUT DOWN iPhone on the newest
    runtime: the suite wipes the app's library and sync settings on whichever device it runs on,
    so it must never grab the simulator a developer is using right now.
    """
    wanted = os.environ.get("HOSHI_IOS_SIMULATOR")
    listing = json.loads(subprocess.run(
        ["xcrun", "simctl", "list", "devices", "available", "-j"], check=True, capture_output=True, text=True
    ).stdout)
    candidates = []
    for runtime, devices in listing.get("devices", {}).items():
        if "iOS" not in runtime:
            continue
        for device in devices:
            if not device.get("isAvailable", True) or "iPhone" not in device.get("name", ""):
                continue
            if wanted and device["name"] != wanted:
                continue
            shutdown = device.get("state") != "Booted"
            candidates.append((shutdown, runtime_version(runtime), device["udid"]))
    if not candidates:
        return None
    candidates.sort(reverse=True)  # shut-down devices first, then the newest runtime
    return candidates[0][2]


def expected_corpus_keys(entries: list[dict]) -> set[str]:
    """Every key the Android client publishes for the corpus (SyncCorpusSnapshotTest.kt mirror)."""
    keys = {e["key"] for e in entries}
    chat_keys = {k for k in keys if k.startswith(f"books/{MANGA_SYNC_ID}/chat/")}
    shard_keys = {k for k in keys if k.startswith("sync/maps/bookmarks/")}
    if len(chat_keys) != 1 or len(shard_keys) != 1:
        raise AssertionError(
            f"stale corpus: expected one chat entry and one bookmark shard, found {sorted(chat_keys)} {sorted(shard_keys)}"
        )
    return {
        f"books/{MANGA_SYNC_ID}/payload.zip", f"books/{MANGA_SYNC_ID}/payload.manifest",
        f"books/{MANGA_SYNC_ID}/bookmark", f"books/{MANGA_SYNC_ID}/metadata", f"books/{MANGA_SYNC_ID}/pretranslations",
        f"books/{NOVEL_SYNC_ID}/epub.zip", f"books/{NOVEL_SYNC_ID}/epub.manifest",
        f"books/{NOVEL_SYNC_ID}/bookmark", f"books/{NOVEL_SYNC_ID}/metadata", f"books/{NOVEL_SYNC_ID}/sentences",
        "sync/maps/books.json",
    } | chat_keys | shard_keys


class ServerProcess:
    def __init__(self) -> None:
        self.process = subprocess.Popen(
            [sys.executable, str(SERVER), "--port", "0", "--token", TOKEN],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        line = self.process.stdout.readline()
        if not line.startswith("SYNC_TEST_SERVER_READY port="):
            raise RuntimeError(f"server did not start: {line!r} {self.process.stderr.read()}")
        self.port = int(line.strip().split("=", 1)[1])
        self.base = f"http://127.0.0.1:{self.port}"

    def call(self, method: str, path: str, body: bytes | None = None) -> bytes:
        request = urllib.request.Request(self.base + path, data=body, method=method)
        request.add_header("Authorization", f"Bearer {TOKEN}")
        if body is not None:
            request.add_header("Content-Type", "application/json; charset=utf-8")
        with urllib.request.urlopen(request) as response:
            return response.read()

    def stop(self) -> None:
        self.process.terminate()
        self.process.wait(timeout=10)
        for stream in (self.process.stdout, self.process.stderr):
            if stream:
                stream.close()


@unittest.skipUnless(shutil.which("xcodebuild") and shutil.which("xcrun"), "Xcode is required")
class IosSyncIntegration(unittest.TestCase):
    def test_production_sync_stack_against_real_server(self):
        self.assertTrue(CORPUS.is_file(), f"missing {CORPUS}")
        simulator = pick_simulator()
        self.assertIsNotNone(simulator, "no available iPhone simulator (xcrun simctl list devices available)")
        server = ServerProcess()
        try:
            server.call("POST", "/_test/load", CORPUS.read_bytes())
            loaded = json.loads(server.call("GET", "/_test/dump"))
            # A stale fixture (regenerate it from the Android repo, see the header) fails here,
            # not silently in the simulator.
            self.assertEqual(expected_corpus_keys(loaded["entries"]), {e["key"] for e in loaded["entries"]},
                             "the fixture must hold exactly what the Android client publishes")

            env = dict(os.environ)
            env["TEST_RUNNER_HOSHI_KV_BASE_URL"] = server.base
            env["TEST_RUNNER_HOSHI_KV_TOKEN"] = TOKEN
            env["TEST_RUNNER_HOSHI_SYNC_CORPUS"] = str(CORPUS)
            derived = os.environ.get("HOSHI_DERIVED_DATA", str(ROOT / "build" / "DD-sim"))
            command = [
                "xcodebuild", "test",
                "-project", str(PROJECT), "-scheme", SCHEME,
                "-destination", f"platform=iOS Simulator,id={simulator}",
                "-derivedDataPath", derived,
                f"-only-testing:{TEST_BUNDLE}",
            ]
            started = time.time()
            result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True, text=True)
            log = ROOT / "build" / "ios-sync-integration.log"
            log.parent.mkdir(parents=True, exist_ok=True)
            log.write_text(result.stdout + "\n--- stderr ---\n" + result.stderr)
            interesting = [
                line for line in result.stdout.splitlines()
                if "Test Case" in line or "error:" in line or "failed" in line.lower() or "** TEST" in line
            ]
            summary = "\n".join(interesting[-60:])
            self.assertEqual(
                0, result.returncode,
                f"xcodebuild test failed after {time.time() - started:.0f}s (full log: {log})\n{summary}",
            )
            self.assertIn("** TEST SUCCEEDED **", result.stdout, summary)
            executed = [line for line in interesting if "Test Case" in line and "passed" in line]
            self.assertGreaterEqual(len(executed), 5, f"expected the sync scenarios to run, saw:\n{summary}")
            self.assertNotIn("skipped", " ".join(interesting).lower(), f"scenarios must not skip:\n{summary}")

            # The simulator really talked to this server with the production client.
            requests = json.loads(server.call("GET", "/_test/requests"))["requests"]
            self.assertTrue(any(r["path"].startswith("/v1/kv") for r in requests), "no API traffic reached the server")
        finally:
            server.stop()


if __name__ == "__main__":
    unittest.main()
