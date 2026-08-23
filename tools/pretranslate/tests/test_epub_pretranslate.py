"""Unit tests for the EPUB (novel) path. No GPU, no network, no real book needed.

The invariant everything here defends: a sentence's address `c{spine}s{start}` must resolve, in the
reader's normalized-character offset space, to exactly that sentence. If it does not, the reader
places its translate button on the wrong text — or, because it hash-checks first, silently places
no button at all.
"""

from __future__ import annotations

import io
import json
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from hoshi_pretranslate import epub  # noqa: E402
from hoshi_pretranslate import epub_pipeline as ep  # noqa: E402
from hoshi_pretranslate.epub_blob import Entry, SentencesBlob, blob_key, prompt_id  # noqa: E402

CONTAINER = """<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>"""

OPF = """<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>テスト本</dc:title></metadata>
  <manifest>
    <item id="cover" href="cover.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="cover" linear="no"/>
    <itemref idref="ch1"/>
    <itemref idref="ch2"/>
  </spine>
</package>"""

COVER = "<html><body><p></p></body></html>"

# Exercises: ruby (the reading must NOT count), a numeric entity (must decode to a character),
# a block boundary with no terminator, quotes that trail the terminator, and a <style> in body.
CH1 = """<html><head><title>ignored</title></head><body>
<h1>第一章</h1>
<p><ruby>猫<rt>ねこ</rt></ruby>が鳴いた。「そうだね」と彼は言った。</p>
<p>&#12354;いうえお</p>
<p>終わりのない行</p>
</body></html>"""

CH2 = """<html><body><p>ひとつ。ふたつ。</p></body></html>"""


def make_epub() -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr("mimetype", "application/epub+zip")
        archive.writestr("META-INF/container.xml", CONTAINER)
        archive.writestr("OEBPS/content.opf", OPF)
        archive.writestr("OEBPS/cover.xhtml", COVER)
        archive.writestr("OEBPS/ch1.xhtml", CH1)
        archive.writestr("OEBPS/ch2.xhtml", CH2)
    return buffer.getvalue()


class Normalization(unittest.TestCase):
    def test_keeps_only_matchable_characters(self):
        self.assertEqual(epub.normalize("その日、彼は「何も」言わなかった。"), "その日彼は何も言わなかった")

    def test_keeps_ascii_and_fullwidth_alphanumerics(self):
        self.assertEqual(epub.normalize("Hello, ３４!"), "Hello３４")

    def test_drops_all_whitespace(self):
        self.assertEqual(epub.normalize("あ　い\n う\t"), "あいう")

    def test_keeps_extension_a_ideographs(self):
        self.assertEqual(epub.normalize("㐀"), "㐀")

    def test_hash_is_over_the_normalized_form(self):
        # Whitespace and punctuation differences must not change a sentence's identity: the reader
        # reassembles the sentence from DOM nodes and will not match our raw string byte for byte.
        self.assertEqual(epub.text_hash("あい、うえ。"), epub.text_hash("あい う え"))


class Parsing(unittest.TestCase):
    def setUp(self):
        self.book = epub.parse_epub(make_epub(), sync_id="test-01")

    def test_title_comes_from_the_opf(self):
        self.assertEqual(self.book.title, "テスト本")

    def test_spine_keeps_non_linear_items(self):
        # EPUBKit keeps them and the reader indexes chapters by position in the unfiltered spine,
        # so dropping the cover here would shift every later chapter.
        self.assertEqual(self.book.spine_count, 3)
        self.assertEqual([c.spine for c in self.book.chapters], [0, 1, 2])

    def test_furigana_readings_are_not_counted(self):
        chapter = self.book.chapters[1]
        self.assertIn("猫が鳴いた", chapter.normalized)
        self.assertNotIn("ねこ", chapter.normalized)

    def test_numeric_entities_are_decoded_not_left_as_digits(self):
        # &#12354; is あ. Left undecoded it would contribute the matchable digits "12354" and shift
        # every offset after it.
        chapter = self.book.chapters[1]
        self.assertIn("あいうえお", chapter.normalized)
        self.assertNotIn("12354", chapter.normalized)

    def test_head_and_title_text_is_excluded(self):
        self.assertNotIn("ignored", self.book.chapters[1].normalized)

    def test_addresses_resolve_exactly(self):
        self.assertEqual(epub.verify(self.book), [])

    def test_every_sentence_window_matches_its_text(self):
        for chapter in self.book.chapters:
            for sentence in chapter.sentences:
                window = chapter.normalized[sentence.start:sentence.start + sentence.length]
                self.assertEqual(window, epub.normalize(sentence.text), sentence.id)

    def test_closing_quote_after_the_terminator_stays_with_the_sentence(self):
        texts = [s.text for s in self.book.chapters[1].sentences]
        self.assertIn("「そうだね」と彼は言った。", texts)

    def test_a_block_with_no_terminator_still_becomes_a_sentence(self):
        texts = [s.text for s in self.book.chapters[1].sentences]
        self.assertIn("終わりのない行", texts)

    def test_ids_are_unique_and_ordered_within_a_chapter(self):
        for chapter in self.book.chapters:
            starts = [s.start for s in chapter.sentences]
            self.assertEqual(starts, sorted(starts))
            self.assertEqual(len(starts), len(set(starts)))

    def test_id_format(self):
        sentence = self.book.chapters[2].sentences[0]
        self.assertEqual(sentence.id, f"c2s{sentence.start}")


def build_epub(body: str, opf_at_root: bool = False, href: str = "ch1.xhtml") -> bytes:
    """A one-chapter EPUB with a configurable layout, for the structural edge cases."""
    prefix = "" if opf_at_root else "OEBPS/"
    opf = f'''<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>T</dc:title></metadata>
<manifest><item id="a" href="{href}" media-type="application/xhtml+xml"/></manifest>
<spine><itemref idref="a"/></spine></package>'''
    container = f'''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
<rootfiles><rootfile full-path="{prefix}content.opf" media-type="application/oebps-package+xml"/>
</rootfiles></container>'''
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr("META-INF/container.xml", container)
        archive.writestr(f"{prefix}content.opf", opf)
        archive.writestr(f"{prefix}ch1.xhtml", body)
    return buffer.getvalue()


class ExactOffsets(unittest.TestCase):
    """Pins the actual output, not a self-comparison.

    Every other addressing assertion in this file compares `_segment`'s sentences against
    `_segment`'s own normalized string, so a systematic shift — a subtree wrongly skipped, a
    `<script>` leaking text — passes them all. These pin the literal expected values.
    """

    BODY = ("<html><body>"
            "<p><ruby>猫<rt>ねこ</rt></ruby>が鳴いた。「そうだね」と彼は言った。</p>"
            "<p>&#12354;いうえお</p>"
            "<p>終わりのない行</p>"
            "</body></html>")

    def setUp(self):
        self.chapter = epub.parse_epub(build_epub(self.BODY), sync_id="t").chapters[0]

    def test_normalized_string_is_exactly_this(self):
        self.assertEqual(
            self.chapter.normalized,
            "猫が鳴いたそうだねと彼は言ったあいうえお終わりのない行",
        )

    def test_sentence_count_is_exactly_four(self):
        self.assertEqual(len(self.chapter.sentences), 4)

    def test_addresses_are_exactly_these(self):
        self.assertEqual(
            [(s.start, s.length, s.text) for s in self.chapter.sentences],
            [
                (0, 5, "猫が鳴いた。"),
                # The brackets are not matchable, so the address covers そうだねと彼は言った only.
                (5, 10, "「そうだね」と彼は言った。"),
                (15, 5, "あいうえお"),
                (20, 7, "終わりのない行"),
            ],
        )


class StructuralEdgeCases(unittest.TestCase):
    def chapter(self, body: str, **kwargs):
        return epub.parse_epub(build_epub(body, **kwargs), sync_id="t").chapters[0]

    def test_svg_title_inside_body_is_kept(self):
        # Both String.filtered() and the DOM walker keep it; skipping `title` by name did not.
        chapter = self.chapter(
            "<html><body><figure><svg><title>図の説明</title></svg></figure>"
            "<p>本文です。</p></body></html>")
        self.assertEqual(chapter.normalized, "図の説明本文です")

    def test_head_title_is_still_excluded(self):
        chapter = self.chapter("<html><head><title>ignored</title></head>"
                               "<body><p>本文です。</p></body></html>")
        self.assertEqual(chapter.normalized, "本文です")

    def test_an_unclosed_head_does_not_swallow_the_chapter(self):
        # </head> is optional in HTML5 and these chapters are served as text/html.
        chapter = self.chapter("<html><head><title>T</title>"
                               "<body><p>本文です。</p></body></html>")
        self.assertEqual(chapter.normalized, "本文です")

    def test_closing_ruby_closes_an_unclosed_rt(self):
        chapter = self.chapter(
            "<html><body><p><ruby>猫<rt>ねこ</ruby>が鳴いた。あとの文。</p></body></html>")
        self.assertEqual(chapter.normalized, "猫が鳴いたあとの文")

    def test_script_text_in_body_is_flagged(self):
        # The DOM walker counts it (it rejects only rt/rp) while we and Swift drop it, so the three
        # implementations cannot agree on this chapter. Report rather than guess.
        chapter = self.chapter(
            "<html><body><script>var abc=1;</script><p>本文です。</p></body></html>")
        self.assertTrue(any("script" in w for w in chapter.warnings), chapter.warnings)

    def test_style_text_in_body_is_flagged(self):
        chapter = self.chapter(
            "<html><body><style>p{color:red}</style><p>本文です。</p></body></html>")
        self.assertTrue(any("style" in w for w in chapter.warnings), chapter.warnings)

    def test_dot_slash_href_with_the_opf_at_the_archive_root(self):
        # The layout of the only real book in the project, and the form that used to be lost.
        chapter = self.chapter("<html><body><p>本文です。</p></body></html>",
                               opf_at_root=True, href="./ch1.xhtml")
        self.assertEqual(chapter.normalized, "本文です")

    def test_href_with_a_fragment_resolves(self):
        chapter = self.chapter("<html><body><p>本文です。</p></body></html>", href="ch1.xhtml#top")
        self.assertEqual(chapter.normalized, "本文です")

    def test_an_unreadable_member_is_reported_not_swallowed(self):
        book = epub.parse_epub(build_epub("<html><body><p>あ。</p></body></html>",
                                          href="missing.xhtml"), sync_id="t")
        self.assertTrue(epub.verify(book))
        self.assertEqual(book.spine_count, 1)  # the spine slot is still occupied

    def test_the_oracle_catches_a_divergence(self):
        # A direct test of the cross-check itself: the oracle must agree on ordinary markup.
        body = "<html><body><p><ruby>猫<rt>ねこ</rt></ruby>が鳴いた。</p></body></html>"
        self.assertEqual(epub.filtered_oracle(body), "猫が鳴いた")


class Segmentation(unittest.TestCase):
    def test_an_overlong_run_is_split_at_a_comma(self):
        long_run = ("あ" * 300) + "、" + ("い" * 300)
        parts = [long_run]
        normalized, sentences = epub._segment(0, parts)
        self.assertGreater(len(sentences), 1)
        self.assertEqual(normalized, epub.normalize(long_run))
        for sentence in sentences:
            self.assertLessEqual(sentence.length, epub.MAX_SENTENCE_CHARS)
            window = normalized[sentence.start:sentence.start + sentence.length]
            self.assertEqual(window, epub.normalize(sentence.text))

    def test_a_run_with_no_matchable_characters_is_dropped(self):
        _, sentences = epub._segment(0, ["・・・", None, "……"])
        self.assertEqual(sentences, [])


class Blob(unittest.TestCase):
    def setUp(self):
        self.book = epub.parse_epub(make_epub(), sync_id="test-01")

    def test_round_trips(self):
        blob = SentencesBlob.for_book(self.book, model="codex", prompt="p")
        sentence = self.book.sentences[0]
        blob.add(sentence.id, Entry.for_sentence(sentence, "t", "e"))
        restored = SentencesBlob.from_json(json.loads(blob.to_bytes().decode("utf-8")))
        self.assertEqual(restored.sync_id, "test-01")
        self.assertEqual(restored.spine_count, 3)
        self.assertEqual(restored.entries[sentence.id].translation, "t")

    def test_kind_marks_it_as_the_sentence_blob(self):
        blob = SentencesBlob.for_book(self.book, model="codex", prompt="p")
        self.assertEqual(blob.to_json()["kind"], "epub")

    def test_rehydrated_blob_keeps_the_original_prompt_id(self):
        blob = SentencesBlob.for_book(self.book, model="codex", prompt="the real prompt")
        original = blob.to_json()["promptId"]
        restored = SentencesBlob.from_json(blob.to_json())
        self.assertEqual(restored.to_json()["promptId"], original)
        self.assertNotEqual(original, prompt_id(""))

    def test_entry_stores_the_books_text_not_the_translators(self):
        sentence = self.book.sentences[0]
        entry = Entry.for_sentence(sentence, "  translation  ", "  explanation  ")
        self.assertEqual(entry.text, sentence.text)
        self.assertEqual(entry.translation, "translation")
        self.assertEqual(entry.to_json()["hash"], sentence.hash)

    def test_key(self):
        self.assertEqual(blob_key("test-01"), "books/test-01/sentences")


class ExportImport(unittest.TestCase):
    def setUp(self):
        self.book = epub.parse_epub(make_epub(), sync_id="test-01")
        self.tmp = tempfile.TemporaryDirectory()
        self.out = Path(self.tmp.name) / "out"
        self.todo = Path(self.tmp.name) / "todo"

    def tearDown(self):
        self.tmp.cleanup()

    def test_export_writes_one_file_per_chapter_plus_an_index(self):
        remaining = ep.export_sentences(self.book, self.out, self.todo, done=set(), log=lambda _: None)
        self.assertEqual(remaining, len(self.book.sentences))
        index = json.loads((self.todo / "index.json").read_text(encoding="utf-8"))
        self.assertEqual(index["remaining"], remaining)
        self.assertTrue((self.todo / "c001.json").exists())

    def test_export_skips_what_is_already_done(self):
        done = {s.id for s in self.book.chapters[1].sentences}
        remaining = ep.export_sentences(self.book, self.out, self.todo, done=done, log=lambda _: None)
        self.assertEqual(remaining, len(self.book.sentences) - len(done))
        self.assertFalse((self.todo / "c001.json").exists())

    def test_export_carries_neighbouring_sentences_as_context(self):
        ep.export_sentences(self.book, self.out, self.todo, done=set(), log=lambda _: None)
        doc = json.loads((self.todo / "c001.json").read_text(encoding="utf-8"))
        later = [p for p in doc["paragraphs"] if p["context_before"]]
        self.assertTrue(later, "a later paragraph should see the ones before it")

    def _import(self, payload):
        source = Path(self.tmp.name) / "done.json"
        source.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
        return ep.import_translations(
            self.book, source, self.out, model="codex", prompt="p", log=lambda _: None
        )

    def test_import_merges_and_checkpoints(self):
        sentence = self.book.sentences[0]
        blob = self._import({sentence.id: {"translation": "T", "explanation": "E"}})
        self.assertEqual(blob.entries[sentence.id].translation, "T")
        self.assertTrue(ep.state_path(self.out, "test-01").exists())

    def test_import_accepts_the_syncid_wrapped_shape(self):
        sentence = self.book.sentences[0]
        blob = self._import({"test-01": {sentence.id: {"translation": "T", "explanation": ""}}})
        self.assertEqual(blob.entries[sentence.id].translation, "T")

    def test_import_ignores_unknown_ids_and_empty_translations(self):
        sentence = self.book.sentences[0]
        blob = self._import({
            sentence.id: {"translation": "T"},
            "c9s999": {"translation": "nope"},
            self.book.sentences[1].id: {"translation": "   "},
        })
        self.assertEqual(set(blob.entries), {sentence.id})

    def test_import_resumes_across_runs(self):
        first, second = self.book.sentences[0], self.book.sentences[1]
        self._import({first.id: {"translation": "A"}})
        blob = self._import({second.id: {"translation": "B"}})
        self.assertEqual(set(blob.entries), {first.id, second.id})

    def test_a_different_prompt_refuses_rather_than_wiping_the_checkpoint(self):
        first = self.book.sentences[0]
        self._import({first.id: {"translation": "A"}})
        with self.assertRaises(ep.CheckpointMismatch):
            ep.resume(self.book, self.out, model="codex", prompt="a different prompt")
        # And the file on disk is untouched — this is the whole point.
        saved = ep.load_saved(self.out, "test-01")
        self.assertEqual(set(saved["entries"]), {first.id})

    def test_new_run_resets_deliberately(self):
        first = self.book.sentences[0]
        self._import({first.id: {"translation": "A"}})
        blob = ep.resume(self.book, self.out, model="codex", prompt="other", allow_reset=True)
        self.assertEqual(blob.entries, {})

    def test_a_foreign_syncid_wrapper_is_not_unwrapped(self):
        # Sentence ids collide freely between books, and nothing downstream could catch this: the
        # entry takes text + address from THIS book, so the hash matches and the reader shows a
        # confidently wrong translation.
        first = self.book.sentences[0]
        blob = self._import({"some-other-book": {first.id: {"translation": "WRONG BOOK"}}})
        self.assertEqual(blob.entries, {})

    def test_a_list_of_entries_is_accepted(self):
        first = self.book.sentences[0]
        blob = self._import([{"id": first.id, "translation": "T", "explanation": "E"}])
        self.assertEqual(blob.entries[first.id].translation, "T")

    def test_one_malformed_file_does_not_lose_the_others(self):
        source = Path(self.tmp.name) / "done"
        source.mkdir()
        good, bad = self.book.sentences[0], self.book.sentences[1]
        (source / "c001.json").write_text(
            json.dumps({good.id: {"translation": "T"}}), encoding="utf-8")
        (source / "c002.json").write_text("{ this is not json", encoding="utf-8")
        (source / "c003.json").write_text(
            json.dumps({bad.id: {"translation": "U"}}), encoding="utf-8")
        blob = ep.import_translations(
            self.book, source, self.out, model="codex", prompt="p", log=lambda _: None
        )
        self.assertEqual(set(blob.entries), {good.id, bad.id})

    def test_checkpoint_write_is_atomic(self):
        first = self.book.sentences[0]
        self._import({first.id: {"translation": "A"}})
        leftovers = list(self.out.glob("*.tmp"))
        self.assertEqual(leftovers, [])

    def test_is_complete_only_when_every_sentence_is_present(self):
        self._import({s.id: {"translation": "T"} for s in self.book.sentences[:-1]})
        saved = ep.load_saved(self.out, "test-01")
        self.assertFalse(ep.is_complete(saved, self.book, "codex", "p"))
        self._import({s.id: {"translation": "T"} for s in self.book.sentences})
        saved = ep.load_saved(self.out, "test-01")
        self.assertTrue(ep.is_complete(saved, self.book, "codex", "p"))


class Verification(unittest.TestCase):
    def setUp(self):
        self.book = epub.parse_epub(make_epub(), sync_id="test-01")

    def test_a_complete_checkpoint_has_no_problems(self):
        blob = SentencesBlob.for_book(self.book, model="codex", prompt="p")
        for sentence in self.book.sentences:
            blob.add(sentence.id, Entry.for_sentence(sentence, "T", "E"))
        self.assertEqual(ep.verify_checkpoint(self.book, blob), [])

    def test_missing_sentences_are_reported(self):
        blob = SentencesBlob.for_book(self.book, model="codex", prompt="p")
        problems = ep.verify_checkpoint(self.book, blob)
        self.assertTrue(any("not translated yet" in p for p in problems))

    def test_a_drifted_address_is_reported(self):
        blob = SentencesBlob.for_book(self.book, model="codex", prompt="p")
        sentence = self.book.sentences[0]
        entry = Entry.for_sentence(sentence, "T", "E")
        entry.start += 3
        blob.add(sentence.id, entry)
        self.assertTrue(any("address drifted" in p for p in ep.verify_checkpoint(self.book, blob)))

    def test_text_drifting_from_the_book_is_reported(self):
        blob = SentencesBlob.for_book(self.book, model="codex", prompt="p")
        for sentence in self.book.sentences:
            blob.add(sentence.id, Entry.for_sentence(sentence, "T", "E"))
        blob.entries[self.book.sentences[0].id].text = "まったく違う文。"
        self.assertTrue(any("stored text differs" in p
                            for p in ep.verify_checkpoint(self.book, blob)))

    def test_a_checkpoint_for_another_book_is_reported(self):
        blob = SentencesBlob.for_book(self.book, model="codex", prompt="p")
        blob.sync_id = "some-other-book"
        self.assertTrue(any("checkpoint is for" in p
                            for p in ep.verify_checkpoint(self.book, blob)))

    def test_a_stale_spine_count_is_reported(self):
        blob = SentencesBlob.for_book(self.book, model="codex", prompt="p")
        blob.spine_count = 99
        self.assertTrue(any("spineCount" in p for p in ep.verify_checkpoint(self.book, blob)))

    def test_an_empty_translation_is_reported(self):
        blob = SentencesBlob.for_book(self.book, model="codex", prompt="p")
        for sentence in self.book.sentences:
            blob.add(sentence.id, Entry.for_sentence(sentence, "T", "E"))
        blob.entries[self.book.sentences[0].id].translation = ""
        self.assertTrue(any("empty translation" in p for p in ep.verify_checkpoint(self.book, blob)))


if __name__ == "__main__":
    unittest.main(verbosity=2)
