"""Exercise the production cross-platform preferences codec/exchange without simulator UI."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ReaderPreferencesExchangeTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("swiftc"), "Swift compiler is required")
    def test_production_exchange_behavior(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "preferences"
            subprocess.run([
                "swiftc", "-swift-version", "6", "-parse-as-library",
                str(ROOT / "Features/HttpSync/ReaderPreferencesProtocol.swift"),
                str(ROOT / "Features/HttpSync/HttpReaderPreferencesLane.swift"),
                str(ROOT / "Tests/Fixtures/ReaderPreferencesHarness.swift"),
                "-o", str(executable),
            ], check=True, capture_output=True, text=True)
            subprocess.run([str(executable)], check=True, capture_output=True, text=True)
