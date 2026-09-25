import json
import shutil
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class SasayakiRangeHighlightTests(unittest.TestCase):
    def run_script(self, reader, test):
        if shutil.which('node') is None:
            self.skipTest('Node is required to execute reader highlighting')
        script = r'''
        const assert = require('node:assert/strict');
        global.Node = {TEXT_NODE:3, ELEMENT_NODE:1};
        global.CSS = {highlights:new Map()};
        global.Highlight = class { constructor(...ranges) { this.ranges=ranges; } };
        const classes = new Set();
        const ruby = {nodeType:1, classList:{add:v=>classes.add(v),remove:v=>classes.delete(v)}};
        const plainParent = {closest:()=>null};
        const rubyParent = {closest:()=>ruby};
        let plain = {nodeType:3,textContent:'読書',parentElement:plainParent};
        const rubyText = {nodeType:3,textContent:'漢字',parentElement:rubyParent};
        global.document = {
          body:{}, scrollingElement:{scrollTop:0,scrollLeft:0}, documentElement:{},
          createRange:()=>({setStart(node,offset){this.start={node,offset};},setEnd(node,offset){this.end={node,offset};}}),
          createElement:()=>{throw Error('CSS Highlight mode must not insert wrapper elements');}
        };
        global.window = {CSS,Highlight,innerWidth:400,innerHeight:600,scrollX:0,scrollY:0,
            getComputedStyle:()=>({textEmphasisStyle:'none'}), scrollTo:offset=>window.lastScroll=offset};
        global.requestAnimationFrame = fn=>fn();
        ''' + (ROOT / reader).read_text() + r'''
        const reader = window.hoshiReader;
        reader.createWalker=()=>{ const nodes=[plain,rubyText];let index=0;return {nextNode:()=>nodes[index++]}; };
        reader.buildNodeOffsets=()=>{};
        ''' + test
        subprocess.run(['node', '-e', script], check=True, timeout=5)

    def test_range_highlight_keeps_ruby_and_dom_and_survives_rebuild(self):
        for reader in ['Features/Reader/ReaderWebView/reader.js', 'Features/Reader/ScrollReaderWebView/scrollreader.js']:
            with self.subTest(reader=reader):
                self.run_script(reader, r'''
                reader.applySasayakiCues([{id:'ruby',start:2,length:2},{id:'plain',start:0,length:2}]);
                assert.equal(reader.cueWrappers.size,0);
                reader.highlightSasayakiCue('plain',false);
                const range=CSS.highlights.get('hoshi-sasayaki').ranges[0];
                assert.equal(range.start.node,plain);
                assert.equal(range.start.offset,0);
                assert.equal(range.end.offset,2);
                reader.highlightSasayakiCue('ruby',false);
                assert.equal(CSS.highlights.has('hoshi-sasayaki'),false);
                assert.equal(classes.has('hoshi-sasayaki-ruby-active'),true);
                reader.clearSasayakiCue();
                assert.equal(classes.size,0);
                reader.highlightSasayakiCue('plain',false);
                plain={...plain}; // a highlight/translation button rebuilt the text nodes
                reader.refreshSasayakiCues();
                assert.equal(CSS.highlights.get('hoshi-sasayaki').ranges[0].start.node,plain);
                reader.resetSasayakiCues();
                assert.equal(CSS.highlights.size,0);
                assert.equal(reader.cueTargets.size,0);
                window.CSS=null;
                let fallback=[];
                reader.wrapSasayakiCueRanges=cues=>fallback=cues;
                reader.applySasayakiCues([{id:'fallback',start:0,length:4}]);
                assert.equal(fallback.length,1);
                ''')

    def test_continuous_range_scroll_aligns_to_leading_edge(self):
        self.run_script('Features/Reader/ScrollReaderWebView/scrollreader.js', r'''
        reader.isVertical=()=>true;
        document.scrollingElement.scrollLeft=-100;
        reader.scrollToTarget({getClientRects:()=>[{left:-60,right:-20,top:0,bottom:60}]});
        assert.equal(window.lastScroll.left,-520);
        reader.isVertical=()=>false;
        document.scrollingElement.scrollTop=500;
        reader.scrollToTarget({getClientRects:()=>[{left:0,right:40,top:700,bottom:760}]});
        assert.equal(window.lastScroll.top,1200);
        assert.equal(reader.scrollToTarget({getClientRects:()=>[{left:0,right:40,top:100,bottom:160}]}),false);
        ''')


if __name__ == '__main__':
    unittest.main()
