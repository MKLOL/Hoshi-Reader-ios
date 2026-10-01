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
#   * `hoshi_pretranslate.epub.load_epub` on a generated EPUB yields exactly the Swift segmenter's
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

# (name, html, expected ruby per sentence as [(start, length, reading)]) — offsets are UTF-16 units
# into the sentence text. Copied from EpubSentenceSegmenterTest.kt; the tool has no notion of
# furigana, so these pin the two apps to each other.
RUBY_VECTORS = [
    (
        "furigana-ride-along-as-ruby-annotations",
        chapter(
            "<p>「<ruby>今日<rt>きょう</rt></ruby>も<ruby>学校<rt>がっこう</rt></ruby>か……」と、"
            "<ruby>私<rt>わたし</rt></ruby>は<ruby>小<rt>ちい</rt></ruby>さくつぶやいた。</p>"
        ),
        [[(1, 2, "きょう"), (4, 2, "がっこう"), (12, 1, "わたし"), (14, 1, "ちい")]],
    ),
    (
        "ruby-pairs-rp-and-unclosed-rt-follow-the-browser",
        chapter(
            "<p>　<ruby>漢<rt>かん</rt>字<rt>じ</rt></ruby>を<ruby>読<rp>(</rp><rt>よ</rt><rp>)</rp></ruby>む。"
            "<ruby>今<rt>いま</ruby>から<ruby>行</ruby>く。</p>"
        ),
        [[(0, 1, "かん"), (1, 1, "じ"), (3, 1, "よ")], [(0, 1, "いま")]],
    ),
    (
        "ruby-annotations-survive-the-overlong-split",
        chapter(f"<p>{CLAUSE}、<ruby>{CLAUSE}<rt>よみ</rt></ruby>、{CLAUSE}。</p>"),
        [[], [(0, 250, "よみ")], []],
    ),
]

MATCHABLE_COUNT_VECTORS = [("「今日は」", 1, 0), ("「今日は」", 3, 2), ("「今日は」", 99, 3)]

def write_synthetic_epub(path: Path) -> list[tuple[str, str]]:
    """A complete, original-text EPUB; return its content documents in declared spine order."""
    def document(body: str) -> str:
        return (
            '<?xml version="1.0" encoding="utf-8"?>'
            '<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="ja">'
            '<head><title>Ignored chapter title</title></head>'
            f'<body>{body}</body></html>'
        )

    chapters = [
        ("Text/opening.xhtml", document(
            '<h1>朝の散歩</h1><p><ruby>今日<rt>きょう</rt></ruby>は晴れ。'
            '「外へ行こう！」</p><p>Ver. 2.5 を読む。</p>'
        )),
        ("Text/note.xhtml", document(
            '<h2>覚え書き</h2><p>Ａ１とB2を比べる。<br/>次は何？</p>'
        )),
        ("Text/closing.xhtml", document(
            '<h1>帰り道</h1><p>caf&#233; で&#160;休む。&#x3042;の文字。</p>'
            f'<p>{CLAUSE}、{CLAUSE}、{CLAUSE}。</p><p>また明日。</p>'
        )),
    ]
    container = '''<?xml version="1.0" encoding="utf-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>'''
    package = '''<?xml version="1.0" encoding="utf-8"?>
<package version="3.0" unique-identifier="book-id" xmlns="http://www.idpf.org/2007/opf">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="book-id">urn:hoshi:sentence-parity-fixture</dc:identifier>
    <dc:title>Synthetic sentence parity</dc:title><dc:language>ja</dc:language>
    <meta property="dcterms:modified">2026-01-01T00:00:00Z</meta>
  </metadata>
  <manifest>
    <item id="closing" href="Text/closing.xhtml" media-type="application/xhtml+xml"/>
    <item id="navigation" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="opening" href="Text/opening.xhtml" media-type="application/xhtml+xml"/>
    <item id="note" href="Text/note.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine><itemref idref="opening"/><itemref idref="note" linear="no"/><itemref idref="closing"/></spine>
</package>'''
    navigation = '''<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>Contents</title></head><body><nav epub:type="toc"><ol>
<li><a href="Text/opening.xhtml">朝の散歩</a></li>
<li><a href="Text/note.xhtml">覚え書き</a></li>
<li><a href="Text/closing.xhtml">帰り道</a></li>
</ol></nav></body></html>'''
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        archive.writestr("META-INF/container.xml", container)
        archive.writestr("OEBPS/content.opf", package)
        archive.writestr("OEBPS/nav.xhtml", navigation)
        # Neither archive order nor manifest order may define sentence chapter addresses.
        for href, html in reversed(chapters):
            archive.writestr("OEBPS/" + href, html)
    return chapters


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
            "ruby": $0.ruby.map {{ [$0.start, $0.length, $0.reading] as [Any] }},
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

    def test_ruby_annotations_match_kotlin(self):
        for name, html, expected in RUBY_VECTORS:
            with self.subTest(vector=name):
                sentences = self.swift_sentences(0, html)
                self.assertEqual(len(expected), len(sentences))
                for sentence, ruby in zip(sentences, expected):
                    self.assertEqual([list(r) for r in ruby], sentence["ruby"])
                    for start, length, _ in ruby:
                        base = sentence["text"][start:start + length]
                        self.assertTrue(base and not base.isspace(), f"ruby base {start}+{length} is blank")
                # Furigana never change what the tool addresses.
                self.assertEqual(
                    tool_sentences(0, html),
                    [(s["id"], s["length"], s["text"]) for s in sentences],
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

    # MARK: the complete EPUB path

    def test_the_tool_and_the_app_agree_on_a_whole_epub(self):
        fixture = self.workdir / "sentence-parity.epub"
        chapters = write_synthetic_epub(fixture)
        book = tool_epub.load_epub(fixture, sync_id="sentence_parity")
        self.assertEqual([], tool_epub.verify(book), "the fixture EPUB does not verify")
        self.assertEqual("Synthetic sentence parity", book.title)
        self.assertEqual(len(chapters), book.spine_count)
        self.assertEqual(list(range(len(chapters))), [c.spine for c in book.chapters])
        self.assertEqual([href for href, _ in chapters], [c.href for c in book.chapters],
                         "spine order, including linear=no, defines sentence addresses")

        with zipfile.ZipFile(fixture) as archive:
            for chapter_data in book.chapters:
                with self.subTest(chapter=chapter_data.spine):
                    href, original_html = chapters[chapter_data.spine]
                    html = archive.read("OEBPS/" + href).decode("utf-8")
                    self.assertEqual(original_html, html)
                    swift = [
                        (s["id"], s["length"], s["text"])
                        for s in self.swift_sentences(chapter_data.spine, html)
                    ]
                    expected = [(s.id, s.length, s.text) for s in chapter_data.sentences]
                    self.assertEqual(expected, swift)
                    self.assertTrue(swift, "the fixture chapter should have sentences")


if __name__ == "__main__":
    unittest.main()
