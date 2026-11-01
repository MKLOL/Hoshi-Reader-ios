from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class TtuImportBehaviorTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("swiftc"), "Swift compiler is required")
    def test_production_statistics_imports(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "imports"
            sources = ["Models/Statistics.swift", "Features/Statistics/ReadingStatisticsMath.swift",
                       "Features/Statistics/ImportedReadingBaseline.swift", "Tests/Fixtures/ImportedReadingHarness.swift"]
            compiled = subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library",
                                       *[str(ROOT / source) for source in sources], "-o", str(executable)],
                                      capture_output=True, text=True)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run([str(executable)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
