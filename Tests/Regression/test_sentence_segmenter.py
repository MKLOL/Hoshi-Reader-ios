# Behavior test for sentence mode's segmenter (`Features/Reader/Sentence/EpubSentenceSegmenter.swift`).
#
# A sentence shown on its own in sentence mode finds its stored pre-translation by the address the
# desktop tool wrote: `c{spine}s{start}` plus a hash of the sentence's normalized text. If the app's
# segmentation drifts from `tools/pretranslate/hoshi_pretranslate/epub.py` by a single character,
# every address after the drift resolves to nothing — or, worse, to the wrong sentence. So the
# three implementations are pinned to each other here:
#
#   * the Swift segmenter, compiled straight out of the shipping source with `swiftc`
#     (this repo has no Swift test target — same approach as test_payload_content_hash.py);
#   * the Python tool itself, imported and run over the same fixtures;
#   * the Kotlin segmenter's golden vectors, copied verbatim from Android's
#     app/src/test/java/moe/antimony/hoshi/features/reader/sentence/EpubSentenceSegmenterTest.kt.
#
# Plus two invariants that are cheap here and impossible in a unit test:
#   * the Swift `isMatchable` predicate equals `EpubTranslationStore.normalize`'s ICU character
#     class on all 1,112,064 Unicode scalars (the predicate exists only because per-character
#     NSRegularExpression is too slow);
#   * `hoshi_pretranslate.epub.load_epub` on a real EPUB yields exactly the Swift segmenter's
#     (id, length, text) triples, chapter for chapter.
#
# Changing a vector means changing the tool and BOTH apps, or none of them.

import json
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SEGMENTER_SOURCE = ROOT / "Features/Reader/Sentence/EpubSentenceSegmenter.swift"
ENTITIES_SOURCE = ROOT / "Features/Reader/Sentence/HtmlEntities.swift"
TRANSLATION_STORE_SOURCE = ROOT / "Features/AI/EpubTranslationStore.swift"
PRETRANSLATE = ROOT / "tools/pretranslate"

sys.path.insert(0, str(PRETRANSLATE))

try:
    from hoshi_pretranslate import epub as tool_epub
except ImportError:  # pragma: no cover - reported by the skip below
    tool_epub = None


def chapter(body: str) -> str:
    """The Android test's fixture wrapper: a real document, with text outside `<body>`."""
    return f"<html><head><title>ignored 無視</title></head><body>{body}</body></html>"


CLAUSE = "あ" * 250

# (name, spine, html, expected [(id, length, text)], expected paragraphs or None)
# Copied from EpubSentenceSegmenterTest.kt. `run_tool` is False only where the Python parser
# cannot see the fixture at all (a fragment with no <body>), which the apps accept on purpose.
VECTORS = [
    (
        "terminators-end-sentences-and-swallow-closing-brackets",
        3,
        chapter("<p>「行こう！」と彼は言った。本当に？</p>"),
        [("c3s0", 3, "「行こう！」"), ("c3s3", 6, "と彼は言った。"), ("c3s9", 3, "本当に？")],
        None,
        True,
    ),
    (
        "ascii-period-is-not-a-terminator",
        0,
        chapter("<p>Ver. 2.5 が出た。</p>"),
        [("c0s0", 8, "Ver. 2.5 が出た。")],
        None,
        True,
    ),
    (
        "block-boundaries-end-sentences-without-punctuation",
        0,
        chapter("<h1>第一章</h1><p>朝だ<br/>起きる</p><div>終わり。</div>"),
        [("c0s0", 3, "第一章"), ("c0s3", 2, "朝だ"), ("c0s5", 3, "起きる"), ("c0s8", 3, "終わり。")],
        [1, 3, 4, 6],
        True,
    ),
    (
        "furigana-scripts-and-head-are-not-text",
        0,
        chapter(
            "<p><ruby>漢<rt>かん</rt>字<rt>じ</rt></ruby>を読む。</p>"
            "<script>var x = '。';</script><style>p{}</style>"
        ),
        [("c0s0", 5, "漢字を読む。")],
        None,
        True,
    ),
    (
        "unclosed-rt-is-closed-by-the-ruby-end-tag-like-a-browser",
        0,
        chapter("<p><ruby>今<rt>いま</ruby>から行く。</p>"),
        [("c0s0", 5, "今から行く。")],
        None,
        True,
    ),
    (
        "offsets-count-matchable-characters-like-the-readers-filter",
        0,
        chapter("<p>今日は　いい天気です。</p><p>　明日も、晴れ？</p>"),
        [("c0s0", 9, "今日は いい天気です。"), ("c0s9", 5, "明日も、晴れ？")],
        None,
        True,
    ),
    (
        "whitespace-inside-a-sentence-collapses-to-single-spaces",
        0,
        chapter("<p>one\n   two&nbsp;&nbsp;three。</p>"),
        [("c0s0", 11, "one two three。")],
        None,
        True,
    ),
    (
        "overlong-runs-split-at-the-last-comma",
        0,
        chapter(f"<p>{CLAUSE}、{CLAUSE}、{CLAUSE}。</p>"),
        [
            ("c0s0", 250, CLAUSE + "、"),
            ("c0s250", 250, CLAUSE + "、"),
            ("c0s500", 250, CLAUSE + "。"),
        ],
        None,
        True,
    ),
    (
        "text-before-body-is-ignored",
        0,
        chapter("<p>本文。</p>"),
        [("c0s0", 2, "本文。")],
        None,
        True,
    ),
    (
        # U+FA11 is a compatibility ideograph the tool's \p{Unified_Ideograph} matches; the old
        # reader filter did not, and every address after it drifted by one.
        "compat-ideographs-are-matchable",
        0,
        chapter("<p>山﨑さん。次。</p>"),
        [("c0s0", 4, "山﨑さん。"), ("c0s4", 1, "次。")],
        None,
        True,
    ),
    (
        # The tool decodes every HTML5 name (html.unescape), not a hand-picked few: an undecoded
        # name is ASCII letters, i.e. matchable, and shifts every address after it.
        "html5-named-entities-decode",
        0,
        chapter("<p>caf&eacute; は良い。&yen;100だ。次の文。</p>"),
        [("c0s0", 6, "café は良い。"), ("c0s6", 4, "¥100だ。"), ("c0s10", 3, "次の文。")],
        None,
        True,
    ),
    (
        # Legacy semicolon-less names, numeric references without `;`, the longest-prefix rule
        # (`&notit;` is `¬` + `it;`) and the standard's invalid-reference replacements.
        "legacy-and-numeric-entities-follow-html-unescape",
        0,
        chapter("<p>a&ampb。&#12354&#x3042;&notit;。&#128;&#0;&#x1;x。</p>"),
        [("c0s0", 2, "a&b。"), ("c0s2", 4, "ああ¬it;。"), ("c0s6", 1, "€\ufffdx。")],
        None,
        True,
    ),
    (
        # script/style content is raw text: a `<` inside it must not start a tag, or the end tag
        # is swallowed and the whole chapter vanishes.
        "script-and-style-content-is-raw-text",
        0,
        "<html><head><script>for(i=0;i<n;i++){}</script></head><body><p>本文。</p>"
        "<script>if (a < b) {}</script><p>次。</p><style>a>b{}</style><p>三。</p></body></html>",
        [("c0s0", 2, "本文。"), ("c0s2", 1, "次。"), ("c0s3", 1, "三。")],
        [1, 3, 5],
        True,
    ),
    (
        # A `<` that starts no markup is text; CDATA sections and comments are skipped whole.
        "stray-less-than-cdata-and-comments",
        0,
        chapter("<p>if a < b then。次。</p><p>第一<![CDATA[x > y]]>章。<!-- 。 -->終。</p>"),
        [("c0s0", 8, "if a < b then。"), ("c0s8", 1, "次。"), ("c0s9", 3, "第一章。"), ("c0s12", 1, "終。")],
        None,
        True,
    ),
    (
        "unknown-entities-survive-and-nbsp-collapses",
        0,
        chapter("<p>&bogus; a&nbsp;b。</p>"),
        [("c0s0", 7, "&bogus; a b。")],
        None,
        True,
    ),
    (
        # `html.parser` gates every text node on having seen `<body>`, so the tool sees nothing
        # here. Both apps treat a body-less fragment as all body instead, because the reader can be
        # handed a chapter that was already unwrapped. Swift-only on purpose.
        "a-bodyless-fragment-is-not-ignored",
        0,
        "<p>断片。</p>",
        [("c0s0", 2, "断片。")],
        None,
        False,
    ),
]

ENTITY_VECTORS = [
    ("a&lt;b&gt;&amp;&quot;&apos;&hellip;&#x78;", "a<b>&\"'…x"),
    ("&bogus; &", "&bogus; &"),
    ("a&ampb", "a&b"),
    ("&notit;", "¬it;"),
    ("&#128;&#0;&#x1;", "€\ufffd"),
    ("&amp\r", "&\r"),
    ("&" + "a" * 40 + ";", "&" + "a" * 40 + ";"),
    ("&#x110000;&#xD800;&#99999999999999999999;", "\ufffd\ufffd\ufffd"),
    ("&Tab;&NewLine;&#65;", "\t\nA"),
]

MATCHABLE_COUNT_VECTORS = [("「今日は」", 1, 0), ("「今日は」", 3, 2), ("「今日は」", 99, 3)]

DEMO_EPUB = Path(
    "/private/tmp/claude-501/-Users-dragosristache-Hoshi-Reader-Android/"
    "42c6980a-e211-49df-9a08-246fc648b285/scratchpad/sentence-demo.epub"
)


def _extract_braced(source: str, signature: str) -> str:
    match = re.search(signature, source)
    if not match:
        raise AssertionError(f"signature not found: {signature}")
    open_index = source.index("{", match.end())
    depth = 0
    for index in range(open_index, len(source)):
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[match.start():index + 1]
    raise AssertionError("unbalanced braces")


def build_harness_source() -> str:
    """A `main.swift` around the real segmenter, plus the real normalizer for the class check."""
    normalize = _extract_braced(
        TRANSLATION_STORE_SOURCE.read_text(encoding="utf-8"),
        r"static func normalize\(_ text: String\) -> String",
    )
    return f"""
import Foundation

// Lifted verbatim from Features/AI/EpubTranslationStore.swift, so the exhaustive class check
// below compares the segmenter against the character class the app actually ships.
enum ShippedNormalizer {{
{normalize}
}}

func segmentJob(_ job: [String: Any]) -> [String: Any] {{
    let spine = job["spine"] as? Int ?? 0
    let html = job["html"] as? String ?? ""
    let sentences = EpubSentenceSegmenter.segment(spine: spine, html: html).map {{
        [
            "id": $0.id,
            "start": $0.start,
            "length": $0.length,
            "text": $0.text,
            "paragraph": $0.paragraph,
        ] as [String: Any]
    }}
    return ["sentences": sentences]
}}

func classMismatches() -> [String] {{
    var mismatches: [String] = []
    for value in UInt32(0)...0x10FFFF {{
        if value >= 0xD800 && value <= 0xDFFF {{ continue }}
        guard let scalar = Unicode.Scalar(value) else {{ continue }}
        let viaRegex = !ShippedNormalizer.normalize(String(scalar)).isEmpty
        if viaRegex != EpubSentenceSegmenter.isMatchable(scalar) {{
            mismatches.append(String(format: "U+%04X", value))
            if mismatches.count > 20 {{ return mismatches }}
        }}
    }}
    return mismatches
}}

let input = FileHandle.standardInput.readDataToEndOfFile()
let jobs = (try? JSONSerialization.jsonObject(with: input)) as? [[String: Any]] ?? []
var results: [[String: Any]] = []
for job in jobs {{
    switch job["op"] as? String ?? "" {{
    case "segment":
        results.append(segmentJob(job))
    case "entities":
        results.append(["text": EpubSentenceSegmenter.decodeEntities(job["text"] as? String ?? "")])
    case "matchableCount":
        results.append(["count": EpubSentenceSegmenter.matchableCount(
            job["text"] as? String ?? "",
            scalarOffset: job["offset"] as? Int ?? 0
        )])
    case "matchableClass":
        results.append(["mismatches": classMismatches()])
    default:
        results.append(["error": "unknown op"])
    }}
}}
let out = try JSONSerialization.data(withJSONObject: results)
FileHandle.standardOutput.write(out)
"""


def tool_chapter(spine: int, html: str):
    """The desktop tool's own extractor + segmenter: (normalized chapter text, sentences)."""
    extractor = tool_epub._ChapterTextExtractor()
    extractor.feed(html)
    extractor.close()
    return tool_epub._segment(spine, extractor.parts)


def tool_sentences(spine: int, html: str):
    """(id, length, text) from the desktop tool."""
    return [(s.id, s.length, s.text) for s in tool_chapter(spine, html)[1]]


@unittest.skipUnless(shutil.which("swiftc"), "swiftc is required to compile the Swift segmenter")
@unittest.skipIf(tool_epub is None, "hoshi_pretranslate (and its `regex` dependency) is required")
class SentenceSegmenterParityTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workdir = Path(tempfile.mkdtemp(prefix="hoshi-sentence-segmenter-"))
        harness = cls.workdir / "main.swift"
        harness.write_text(build_harness_source(), encoding="utf-8")
        cls.binary = cls.workdir / "harness"
        subprocess.run(
            ["swiftc", "-O", "-o", str(cls.binary), str(SEGMENTER_SOURCE), str(ENTITIES_SOURCE), str(harness)],
            check=True,
            capture_output=True,
            text=True,
        )

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.workdir, ignore_errors=True)

    def run_jobs(self, jobs):
        result = subprocess.run(
            [str(self.binary)],
            input=json.dumps(jobs),
            check=True,
            capture_output=True,
            text=True,
        )
        return json.loads(result.stdout)

    def swift_sentences(self, spine: int, html: str):
        payload = self.run_jobs([{"op": "segment", "spine": spine, "html": html}])[0]
        return payload["sentences"]

    # MARK: the golden vectors

    def test_golden_vectors_match_kotlin_and_the_tool(self):
        for name, spine, html, expected, paragraphs, run_tool in VECTORS:
            with self.subTest(vector=name):
                sentences = self.swift_sentences(spine, html)
                triples = [(s["id"], s["length"], s["text"]) for s in sentences]
                self.assertEqual(expected, triples)
                if paragraphs is not None:
                    self.assertEqual(paragraphs, [s["paragraph"] for s in sentences])
                if run_tool:
                    self.assertEqual(
                        expected,
                        tool_sentences(spine, html),
                        "the desktop tool disagrees with the shipped vector",
                    )

    def test_entities_decode_and_unknown_ones_survive(self):
        jobs = [{"op": "entities", "text": raw} for raw, _ in ENTITY_VECTORS]
        results = self.run_jobs(jobs)
        for (raw, expected), result in zip(ENTITY_VECTORS, results):
            with self.subTest(entity=raw):
                self.assertEqual(expected, result["text"])

    def test_matchable_count_maps_a_tap_offset_onto_the_normalized_text(self):
        jobs = [{"op": "matchableCount", "text": t, "offset": o} for t, o, _ in MATCHABLE_COUNT_VECTORS]
        results = self.run_jobs(jobs)
        for (text, offset, expected), result in zip(MATCHABLE_COUNT_VECTORS, results):
            with self.subTest(text=text, offset=offset):
                self.assertEqual(expected, result["count"])

    # MARK: invariants

    def test_matchable_predicate_equals_the_shipped_character_class(self):
        mismatches = self.run_jobs([{"op": "matchableClass"}])[0]["mismatches"]
        self.assertEqual([], mismatches, "isMatchable diverged from EpubTranslationStore.normalize")

    def test_every_sentence_addresses_its_own_characters(self):
        # The invariant sentence mode and the reader both rely on: the window
        # [start, start + length) of the chapter's normalized text IS this sentence. The chapter
        # text comes from the tool, so this also proves the Swift offsets index the tool's string.
        for name, spine, html, _, _, run_tool in VECTORS:
            if not run_tool:
                continue
            with self.subTest(vector=name):
                normalized, _ = tool_chapter(spine, html)
                total = 0
                for sentence in self.swift_sentences(spine, html):
                    start, length = sentence["start"], sentence["length"]
                    window = normalized[start:start + length]
                    self.assertEqual(tool_epub.normalize(sentence["text"]), window)
                    total += length
                self.assertEqual(len(normalized), total, "sentences must cover the whole chapter")

    # MARK: the real book

    @unittest.skipUnless(DEMO_EPUB.is_file(), f"fixture EPUB not present: {DEMO_EPUB}")
    def test_the_tool_and_the_app_agree_on_a_whole_epub(self):
        book = tool_epub.load_epub(DEMO_EPUB, sync_id="sentence_demo")
        self.assertEqual([], tool_epub.verify(book), "the fixture EPUB does not verify")
        self.assertGreaterEqual(len(book.chapters), 2)

        with zipfile.ZipFile(DEMO_EPUB) as archive:
            for chapter_data in book.chapters:
                with self.subTest(chapter=chapter_data.spine):
                    member = tool_epub._resolve_href("OEBPS", chapter_data.href)
                    html = archive.read(member).decode("utf-8")
                    swift = [
                        (s["id"], s["length"], s["text"])
                        for s in self.swift_sentences(chapter_data.spine, html)
                    ]
                    expected = [(s.id, s.length, s.text) for s in chapter_data.sentences]
                    self.assertEqual(expected, swift)
                    self.assertTrue(swift, "the fixture chapter should have sentences")


if __name__ == "__main__":
    unittest.main()
