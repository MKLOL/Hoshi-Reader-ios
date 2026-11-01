"""Execute the production causal-position repository and sync lane without an iOS simulator."""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(shutil.which("swiftc"), "swiftc is required")
class ReadingPositionBehaviorTests(unittest.TestCase):
    def test_navigation_history_and_http_lane(self):
        with tempfile.TemporaryDirectory(prefix="hoshi-positions-") as work:
            binary = Path(work) / "positions"
            sources = [
                ROOT / "Features/ReadingPosition/ReadingPositionProtocol.swift",
                ROOT / "Features/ReadingPosition/ReadingPositionRepository.swift",
                ROOT / "Features/ReadingPosition/HttpReadingPositionLane.swift",
                ROOT / "Tests/Fixtures/reading-position-harness.swift",
            ]
            subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library", *map(str, sources), "-o", str(binary)], check=True, timeout=90)
            result = subprocess.run([str(binary)], check=True, capture_output=True, text=True, timeout=30)
            self.assertIn("PASS:", result.stdout)


if __name__ == "__main__":
    unittest.main()
