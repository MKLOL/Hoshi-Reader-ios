import re
import shutil
import subprocess
import unittest
from pathlib import Path


class MangaUsageBridgeTests(unittest.TestCase):
    def test_reveal_events_carry_each_bubbles_mokuro_address_and_only_ocr_text(self):
        if shutil.which("node") is None:
            self.skipTest("Node is needed to execute the production manga tap handler")
        root = Path(__file__).resolve().parents[2]
        source = (root / "Features/MangaReader/MangaPageHtml.swift").read_text()
        handler = re.search(
            r"handleTap: (function\(x, y, maxLength\) \{.*?\n        \})\n      \};",
            source, re.S,
        ).group(1)
        script = r"""
        const assert = require('node:assert/strict');
        const messages = [];
        const boxes = [];
        let target;
        function box(block, text) {
          const classes = new Set();
          const value = {
            dataset: {ocrText:text, ...(block ? {hoshiBlock:block} : {})}, id: '',
            textContent: text + 'TranslateCopy',
            querySelector: selector => selector === 'p' ? {textContent:text} : null,
            classList: {contains:v=>classes.has(v), add:v=>classes.add(v), remove:v=>classes.delete(v)},
            closest(selector) { return selector === '.ocr-box' ? this : null; },
            setAttribute() {}
          };
          boxes.push(value);
          return value;
        }
        global.document = {elementFromPoint:()=>target};
        global.window = {
          webkit:{messageHandlers:{hoshiManga:{postMessage:message=>messages.push(message)}}},
          hoshiSelection:{selectText:()=> '__lookup__'},
          hoshiManga:{
            clearRevealed:()=>boxes.forEach(box=>box.classList.remove('revealed')),
            revealedBoxAt:()=>null, hitSlopBoxAt:()=>null,
            prepareReveal(){}, fitFurigana(){}, notifyScrollableBubbleRegions(){},
            annotationBaseHit(){return null;}, bubbleText:box=>box.dataset.ocrText,
            tryWrapFallback(){}, placeActions(){}, singleTapLookupValue:false
          }
        };
        """ + "window.hoshiManga.handleTap = " + handler + r""";
        const first = box('p0b0', '猫');
        const second = box('p0b1', '犬');
        const nextPage = box('p1b0', '鳥');
        for (const value of [first, first, second, nextPage, first]) {
          target = value;
          window.hoshiManga.handleTap(10,10,20);
        }
        assert.deepEqual(messages.map(event=>event.blockId), ['p0b0','p0b1','p1b0','p0b0']);
        assert.deepEqual(messages.map(event=>event.text), ['猫','犬','鳥','猫']);
        assert.ok(messages.every(event=>event.event === 'bubbleRevealed'));
        target = box(null, '魚');
        window.hoshiManga.handleTap(10,10,20);
        assert.equal(messages.at(-1).blockId, '');
        """
        subprocess.run(["node", "-e", script], check=True, timeout=5)


if __name__ == "__main__":
    unittest.main()
