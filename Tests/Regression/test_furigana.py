"""Execute the shared production furigana alignment used by dictionary and transcript HTML."""
import shutil
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(shutil.which("node"), "node required")
class FuriganaTests(unittest.TestCase):
    def run_script(self, assertions, *, popup=False):
        script = "const assert = require('node:assert/strict');\n"
        script += (ROOT / "Features/Shared/furigana.js").read_text()
        if popup:
            script += "\nglobal.window = {};\n"
            script += (ROOT / "Features/Popup/popup.js").read_text()
        script += "\n" + assertions
        subprocess.run(["node", "-e", script], check=True, timeout=10)

    def test_dictionary_sections_open_by_the_collapse_settings(self):
        self.run_script(r"""
        const open = (mode, collapsed, expandFirst, name, first) => {
            window.collapseMode = mode; window.collapsedDictionaries = collapsed; window.expandFirstDictionary = expandFirst;
            return dictionaryStartsOpen(name, first);
        };
        assert.equal(open('Expand All', ['JMdict'], false, 'JMdict', false), true);
        assert.equal(open('Collapse All', [], false, 'JMdict', true), false);
        assert.equal(open('Collapse All', [], true, 'JMdict', true), true);
        assert.equal(open('Collapse All', [], true, 'Jitendex', false), false);
        assert.equal(open('Custom', ['Jitendex'], false, 'JMdict', false), true);
        assert.equal(open('Custom', ['Jitendex'], false, 'Jitendex', false), false);
        assert.equal(open('Custom', ['Jitendex'], true, 'Jitendex', true), true);
        // A page that sets none of them, as the card preview once did, shows everything.
        assert.equal(open(undefined, undefined, undefined, 'JMdict', false), true);
        assert.equal(open('Custom', undefined, undefined, 'JMdict', false), true);
        """, popup=True)

    def test_okurigana_is_not_repeated_above_the_word(self):
        self.run_script(r"""
        const cases = [
            ['例えば', 'たとえば', [['例', 'たと'], ['えば', '']]],
            ['食べる', 'たべる', [['食', 'た'], ['べる', '']]],
            ['読みます', 'よみます', [['読', 'よ'], ['みます', '']]],
            ['取り戻す', 'とりもどす', [['取', 'と'], ['り', ''], ['戻', 'もど'], ['す', '']]],
            ['お祝い', 'おいわい', [['お', ''], ['祝', 'いわ'], ['い', '']]],
            ['世界中', 'せかいじゅう', [['世界中', 'せかいじゅう']]],
            ['今日', 'きょう', [['今日', 'きょう']]],
        ];
        for (const [base, reading, expected] of cases) {
            assert.deepEqual(segmentFurigana(base, reading, {strict: true}), expected);
        }
        """)

    def test_kana_only_and_different_kana_scripts_stay_plain(self):
        self.run_script(r"""
        for (const [base, reading] of [['ひらがな', 'ひらがな'], ['カタカナ', 'かたかな'],
                                        ['かな', 'カナ'], ['コーヒー', 'こーひー']]) {
            const result = segmentFurigana(base, reading, {strict: true});
            assert.equal(result.map(([text]) => text).join(''), base);
            assert(result.every(([, ruby]) => ruby === ''));
        }
        """)

    def test_decomposed_kana_preserves_original_utf16_offsets(self):
        self.run_script(r"""
        const prefix = '😀';
        const base = '歯か\u3099痛い';
        const segments = segmentFurigana(base, 'はがいたい', {strict: true});
        assert.deepEqual(segments, [['歯', 'は'], ['か\u3099', ''], ['痛', 'いた'], ['い', '']]);
        assert.equal(segments.map(([text]) => text).join(''), base);
        let offset = prefix.length;
        const annotations = [];
        for (const [text, reading] of segments) {
            if (reading) annotations.push({start: offset, length: text.length, reading});
            offset += text.length;
        }
        assert.deepEqual(annotations, [
            {start: 2, length: 1, reading: 'は'},
            {start: 5, length: 1, reading: 'いた'},
        ]);
        assert.equal((prefix + base).slice(5, 6), '痛');
        """)

    def test_repeated_kana_ambiguity_does_not_guess_a_base(self):
        self.run_script(r"""
        for (const [base, reading] of [['漢あ字', 'かああじ'], ['漢あ字あ漢', 'ああああああ']]) {
            assert.deepEqual(segmentFurigana(base, reading, {strict: true}), [[base, '']]);
            assert.deepEqual(segmentFurigana(base, reading), [[base, reading]]);
        }
        """)

    def test_every_short_repeated_anchor_alignment_is_unique_or_plain(self):
        self.run_script(r"""
        const base = '漢あ字あ漢';
        for (let length = 1; length <= 8; ++length) {
            for (let bits = 0; bits < 2 ** length; ++bits) {
                const reading = Array.from({length}, (_, i) => (bits >> i) & 1 ? 'か' : 'あ').join('');
                const candidates = [];
                // Exhaust the possible positions of the two printed kana anchors. Each kanji
                // group must retain at least one reading character on its side of the anchors.
                for (let first = 1; first < length - 1; ++first) {
                    for (let second = first + 2; second < length - 1; ++second) {
                        if (reading[first] === 'あ' && reading[second] === 'あ') {
                            candidates.push([
                                ['漢', reading.slice(0, first)], ['あ', ''],
                                ['字', reading.slice(first + 1, second)], ['あ', ''],
                                ['漢', reading.slice(second + 1)],
                            ]);
                        }
                    }
                }
                const expected = candidates.length === 1 ? candidates[0] : [[base, '']];
                assert.deepEqual(segmentFurigana(base, reading, {strict: true}), expected, reading);
            }
        }
        """)

    def test_failed_alignment_and_invalid_reading_stay_plain(self):
        self.run_script(r"""
        for (const [base, reading] of [['食べる', 'たべた'], ['例えば', 'たとえ'],
                                        ['本', 'book'], ['本', ''], ['本', '漢'],
                                        ['本', 'ほん。'], ['読😀む', 'よむ']]) {
            assert.deepEqual(segmentFurigana(base, reading, {strict: true}), [[base, '']]);
        }
        """)

    def test_repeated_anchors_and_oversized_tokens_finish_without_guessing(self):
        self.run_script(r"""
        const base = '漢あ'.repeat(35) + '字い';
        assert.deepEqual(segmentFurigana(base, 'あ'.repeat(150), {strict: true}), [[base, '']]);
        const oversized = '本'.repeat(513);
        assert.deepEqual(segmentFurigana(oversized, 'ほん'.repeat(513), {strict: true}), [[oversized, '']]);
        """)

    def test_dictionary_consumers_still_use_shared_segments(self):
        self.run_script(r"""
        assert.equal(constructFuriganaPlain('例えば', 'たとえば'), '例[たと]えば ');
        assert.equal(constructFuriganaPlain('カタカナ', 'かたかな'), 'カタカナ[かたかな]');
        assert.deepEqual(segmentFurigana('食べる', 'not-a-reading'), [['食べる', 'not-a-reading']]);
        assert.equal(getLanguageFromText('漢字', null), 'ja');
        assert.equal(getLanguageFromText('カタカナ', null), 'ja');
        assert.equal(getLanguageFromText('漢字', 'zh'), 'zh');
        """, popup=True)


if __name__ == "__main__":
    unittest.main()
