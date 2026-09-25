"""Run production selection code: scan/highlight supplementary kanji in UTF-16 DOM ranges."""
import json
from pathlib import Path
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]

@unittest.skipUnless(shutil.which('node'), 'node required')
class SelectionUnicodeTests(unittest.TestCase):
    def test_scan_limits_are_codepoints_and_dom_ranges_remain_utf16(self):
        source = ROOT / 'Features/Reader/ReaderWebView/selection.js'
        script = r'''
const assert = require('assert');
global.window = { getSelection: () => null, scanNonJapaneseText: false };
global.document = { addEventListener() {}, elementFromPoint: () => null, body: {} };
global.CSS = { highlights: new Map() };
let message;
global.webkit = { messageHandlers: { textSelected: { postMessage: m => message = m } } };
eval(require('fs').readFileSync(SOURCE, 'utf8'));
const select = window.hoshiSelection;
assert(select.isJapaneseChar('𠮷'));
const first = { textContent: '𠮷野' }, second = { textContent: '家です。' };
select.getCharacterAtPoint = () => ({ node: first, offset: 0 });
select.findParagraph = () => document.body;
select.createWalker = () => ({ currentNode: first, nextNode() { if (this.currentNode === first) return this.currentNode = second; return null; } });
select.getSentence = () => '𠮷野家です。';
select.getSelectionRect = () => ({x:0,y:0,width:10,height:10});
for (const [limit, expected] of [[1, '𠮷'], [2,'𠮷野'], [3,'𠮷野家'], [20,'𠮷野家です']]) {
  select.clearSelection();
  assert.equal(select.selectText(0, 0, limit), expected);
  assert.equal(message.text, expected);
  const rebuilt = select.selection.ranges.map(r => r.node.textContent.slice(r.start,r.end)).join('');
  assert.equal(rebuilt, expected);
}
select.clearSelection(); select.selectText(0,0,3);
const ranges=[];
document.createRange = () => { const r={setStart(node,offset){this.start=offset;},setEnd(node,offset){this.end=offset;}}; ranges.push(r); return r; };
global.Highlight = class { constructor(...r) { this.ranges=r; } };
select.highlightSelection(1);
assert.equal(ranges[0].end,2);
'''.replace('SOURCE', json.dumps(str(source)))
        subprocess.run(['node', '-e', script], check=True, timeout=10)

if __name__ == '__main__':
    unittest.main()
