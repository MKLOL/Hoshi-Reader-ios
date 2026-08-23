"""Offline tests for the Gemini EPUB Batch API workflow."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from hoshi_pretranslate.epub import Chapter, EpubBook, Sentence  # noqa: E402
from hoshi_pretranslate.gemini_epub_batch import (  # noqa: E402
    BatchWorkflowError,
    build_chunks,
    process_result_bytes,
    render_chunk_prompt,
    request_for_chunk,
    validate_entries,
)


def sentence(index: int, text: str | None = None) -> Sentence:
    return Sentence(
        spine=1,
        start=index * 10,
        length=2,
        text=text or f"文{index}。",
        paragraph=index,
    )


def book_with(count: int) -> EpubBook:
    sentences = [sentence(index) for index in range(count)]
    chapter = Chapter(
        spine=1,
        href="chapter.xhtml",
        heading="第一章",
        normalized="".join("文一" for _ in sentences),
        sentences=sentences,
    )
    return EpubBook(sync_id="book-2", title="本二", spine_count=2, chapters=[chapter])


def valid_value(surface: str = "猫", reading: str = "ねこ") -> dict[str, str]:
    return {
        "translation": "The cat cried.",
        "explanation": (
            f"**Words**\n- {surface}【{reading}】 (*neko*) — cat\n\n"
            "**Grammar**\nA concise explanation."
        ),
    }


class Planning(unittest.TestCase):
    def test_chunks_are_small_and_carry_four_before_one_after(self):
        book = book_with(12)
        chunks = build_chunks(
            book,
            done_ids=set(),
            target_count=7,
            targets_per_request=5,
            context_before=4,
            context_after=1,
        )
        self.assertEqual([len(chunk.targets) for chunk in chunks], [5, 2])
        self.assertEqual(len(chunks[0].context_before), 0)
        self.assertEqual(len(chunks[0].context_after), 1)
        self.assertEqual(len(chunks[1].context_before), 4)
        self.assertEqual(len(chunks[1].context_after), 1)

    def test_done_sentences_are_not_resubmitted_and_split_the_run(self):
        book = book_with(8)
        chunks = build_chunks(
            book,
            done_ids={book.sentences[2].id},
            target_count=8,
            targets_per_request=5,
            context_before=4,
            context_after=1,
        )
        target_ids = [sentence.id for chunk in chunks for sentence in chunk.targets]
        self.assertNotIn(book.sentences[2].id, target_ids)
        self.assertEqual(len(target_ids), 7)

    def test_request_has_structured_output_and_unambiguous_context_labels(self):
        book = book_with(7)
        chunk = build_chunks(book, set(), 5, 5, 4, 1)[0]
        rendered = render_chunk_prompt(book, chunk)
        request = request_for_chunk(book, chunk, "PROMPT", "medium")
        self.assertIn("CONTEXT BEFORE (reference only)", rendered)
        self.assertIn("TARGETS (translate every one, and only these)", rendered)
        self.assertEqual(request["key"], chunk.key)
        config = request["request"]["generationConfig"]
        self.assertEqual(config["responseMimeType"], "application/json")
        self.assertEqual(config["responseJsonSchema"]["properties"]["translations"]["maxItems"], 5)
        self.assertEqual(config["thinkingConfig"]["thinkingLevel"], "medium")


class Validation(unittest.TestCase):
    def setUp(self):
        self.target = sentence(0, "猫が鳴いた。")
        self.by_id = {self.target.id: self.target}

    def test_accepts_complete_exact_result(self):
        value = {
            "translation": "The cat cried.",
            "explanation": (
                "**Words**\n"
                "- 猫【ねこ】 (*neko*) — cat\n"
                "- が【が】 (*ga*) — subject marker\n"
                "- 鳴いた【ないた】 (*naita*) — cried\n\n"
                "**Grammar**\nThe subject is marked by が."
            ),
        }
        self.assertEqual(
            validate_entries({self.target.id: value}, [self.target.id], self.by_id)[self.target.id],
            value,
        )

    def test_accepts_plain_bullets_in_grammar_section(self):
        value = valid_value()
        value["explanation"] += (
            "\n- The subject is marked by が.\n"
            "- 鳴いた is the past form of 鳴く."
        )
        self.assertEqual(
            validate_entries({self.target.id: value}, [self.target.id], self.by_id)[self.target.id],
            value,
        )

    def test_rejects_kanji_in_reading(self):
        with self.assertRaisesRegex(BatchWorkflowError, "kana-only"):
            validate_entries(
                {self.target.id: valid_value(surface="猫", reading="猫")},
                [self.target.id],
                self.by_id,
            )

    def test_rejects_surface_not_present_in_target(self):
        with self.assertRaisesRegex(BatchWorkflowError, "not in the target"):
            validate_entries(
                {self.target.id: valid_value(surface="犬", reading="いぬ")},
                [self.target.id],
                self.by_id,
            )

    def test_rejects_punctuation_as_a_word(self):
        with self.assertRaisesRegex(BatchWorkflowError, "punctuation-only"):
            validate_entries(
                {self.target.id: valid_value(surface="。", reading="。")},
                [self.target.id],
                self.by_id,
            )

    def test_rejects_missing_or_extra_ids(self):
        with self.assertRaisesRegex(BatchWorkflowError, "wrong result IDs"):
            validate_entries({}, [self.target.id], self.by_id)


class Collection(unittest.TestCase):
    def test_keyed_jsonl_is_saved_in_import_format_with_usage(self):
        target = sentence(0, "猫が鳴いた。")
        chapter = Chapter(1, "c.xhtml", "", "猫が鳴いた", [target])
        book = EpubBook("book-2", "本二", 2, [chapter])
        payload = {
            "translations": [
                {
                    "id": target.id,
                    "translation": "The cat cried.",
                    "explanation": (
                        "**Words**\n"
                        "- 猫【ねこ】 (*neko*) — cat\n"
                        "- が【が】 (*ga*) — subject marker\n"
                        "- 鳴いた【ないた】 (*naita*) — cried\n\n"
                        "**Grammar**\nThe subject is marked by が."
                    ),
                }
            ]
        }
        response_line = {
            "key": "c001-s0-n1",
            "response": {
                "candidates": [{"content": {"parts": [{"text": json.dumps(payload)}]}}],
                "usageMetadata": {
                    "promptTokenCount": 100,
                    "candidatesTokenCount": 50,
                    "thoughtsTokenCount": 10,
                    "totalTokenCount": 160,
                },
            },
        }
        plan = {"chunks": [{"key": "c001-s0-n1", "targetIds": [target.id]}]}
        with tempfile.TemporaryDirectory() as temporary:
            done = Path(temporary)
            saved, failures, usage = process_result_bytes(
                (json.dumps(response_line) + "\n").encode(), plan, book, done
            )
            self.assertEqual(saved, 1)
            self.assertEqual(failures, [])
            self.assertEqual(usage["totalTokens"], 160)
            document = json.loads((done / "c001-s0-n1.json").read_text())
            self.assertEqual(document[target.id]["translation"], "The cat cried.")


if __name__ == "__main__":
    unittest.main()
