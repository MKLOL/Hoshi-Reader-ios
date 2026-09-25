import re
import shutil
import subprocess
import unittest
from pathlib import Path


class MangaFractionalWrapTests(unittest.TestCase):
    def test_fractional_wrap_search_terminates_and_finds_largest_font(self):
        if shutil.which("node") is None:
            self.skipTest("Node is needed to run the production wrapping search")
        root = Path(__file__).resolve().parents[2]
        source = (root / "Features/MangaReader/MangaPageHtml.swift").read_text()
        function = re.search(r"function findMaxFitting\(start\) \{.*?\n          \}", source, re.S).group(0)
        script = """
        const MIN_FS = 1, MAX_FS = 400;
        let fs, steps, limit;
        function setFs(value) { fs = value; if (++steps > 100) throw Error('search did not terminate'); }
        function overflowing() { return fs > limit; }
        """ + function + """
        for (const [start, maximum] of [[12.2,24], [1.2,2], [18.75,28], [0.5,1], [35.2,8], [350.9,400]]) {
          steps=0; limit=maximum;
          const result = findMaxFitting(start);
          if (result !== maximum) throw Error(`Expected ${maximum}, got ${result}`);
        }
        """
        subprocess.run(["node", "-e", script], check=True, timeout=5)


if __name__ == "__main__":
    unittest.main()
