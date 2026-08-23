"""Unit tests for the parts that do not need a GPU or the real sync server."""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from hoshi_pretranslate import blob as blobmod  # noqa: E402
from hoshi_pretranslate import llm, pipeline  # noqa: E402
from hoshi_pretranslate.kv import encode_key  # noqa: E402
from hoshi_pretranslate.mokuro import Bubble, bubbles_by_page, parse_mokuro  # noqa: E402

SAMPLE = {
    "title": "Sample",
    "volume": "Sample Vol 1",
    "pages": [
        {
            "img_width": 800,
            "img_height": 1200,
            "img_path": "images/0001.jpg",
            "blocks": [
                {"box": [1, 2, 3, 4], "vertical": True, "font_size": 20, "lines": ["おはよう", "ございます"]},
                {"box": [5, 6, 7, 8], "vertical": True, "font_size": 18, "lines": ["   "]},
                {"box": [9, 10, 11, 12], "vertical": False, "font_size": 16, "lines": ["うん"]},
            ],
        },
        {
            "img_width": 800,
            "img_height": 1200,
            "img_path": "images/0002.jpg",
            "blocks": [{"box": [1, 2, 3, 4], "vertical": True, "font_size": 20, "lines": ["そうか"]}],
        },
    ],
}


class MokuroParsing(unittest.TestCase):
    def test_bubble_addresses_use_original_block_indices(self):
        volume = parse_mokuro(json.dumps(SAMPLE), "sample-1", "fallback")
        ids = [b.block_id for b in volume.bubbles]
        # Block 1 is blank and dropped, but block 2 keeps index 2 — the readers look up by the
        # mokuro index, so a dropped neighbour must never shift a bubble's address.
        self.assertEqual(ids, ["p0b0", "p0b2", "p1b0"])

    def test_title_prefers_volume(self):
        volume = parse_mokuro(json.dumps(SAMPLE), "sample-1", "fallback")
        self.assertEqual(volume.title, "Sample Vol 1")

    def test_lines_join_with_newline(self):
        volume = parse_mokuro(json.dumps(SAMPLE), "sample-1", "fallback")
        self.assertEqual(volume.bubbles[0].text, "おはよう\nございます")

    def test_grouping_by_page(self):
        volume = parse_mokuro(json.dumps(SAMPLE), "sample-1", "fallback")
        pages = bubbles_by_page(volume)
        self.assertEqual(sorted(pages), [0, 1])
        self.assertEqual(len(pages[0]), 2)


class BlobFormat(unittest.TestCase):
    def test_round_trip(self):
        original = blobmod.PretranslationsBlob(
            sync_id="sample-1", title="Sample", model="qwen", prompt="p"
        )
        original.add("p0b0", blobmod.Entry(text="おはよう", translation="Morning", explanation="greeting"))
        restored = blobmod.PretranslationsBlob.from_json(json.loads(original.to_bytes()))
        self.assertEqual(restored.entries["p0b0"].translation, "Morning")
        self.assertEqual(restored.title, "Sample")

    def test_entries_carry_a_text_hash_for_reocr_detection(self):
        entry = blobmod.Entry(text="おはよう", translation="Morning", explanation="x")
        self.assertEqual(entry.to_json()["hash"], blobmod.text_hash("おはよう"))

    def test_japanese_is_not_escaped(self):
        b = blobmod.PretranslationsBlob(sync_id="s", title="t", model="m", prompt="p")
        b.add("p0b0", blobmod.Entry(text="おはよう", translation="Morning", explanation=""))
        self.assertIn("おはよう".encode("utf-8"), b.to_bytes())

    def test_one_key_per_book(self):
        self.assertEqual(blobmod.blob_key("my-book"), "books/my-book/pretranslations")


class Prompting(unittest.TestCase):
    def setUp(self):
        volume = parse_mokuro(json.dumps(SAMPLE), "sample-1", "fallback")
        pages = bubbles_by_page(volume)
        self.page0 = pages[0]
        self.page1 = pages[1]

    def test_focused_prompt_includes_previous_page_context(self):
        prompt = llm.build_focused_prompt(self.page1[0], self.page1, self.page0, "style")
        self.assertIn("Previous page", prompt)
        self.assertIn("おはよう", prompt)          # context from page 0
        self.assertIn("ONLY bubble [p1b0]", prompt)  # the focused target

    def test_context_comes_before_the_target_so_the_prefix_cache_hits(self):
        # Every bubble on a page must share a byte-identical prompt prefix, otherwise llama.cpp
        # re-reads the whole page context for each bubble.
        a = llm.build_focused_prompt(self.page0[0], self.page0, [], "style")
        b = llm.build_focused_prompt(self.page0[1], self.page0, [], "style")
        shared = llm.build_context(self.page0, [], "style")
        self.assertTrue(a.startswith(shared))
        self.assertTrue(b.startswith(shared))

    def test_first_page_has_no_previous_page_section(self):
        prompt = llm.build_focused_prompt(self.page0[0], self.page0, [], "style")
        self.assertNotIn("Previous page", prompt)

    def test_collect_ignores_ids_the_model_invented(self):
        reply = {
            "bubbles": [
                {"id": "p0b0", "translation": "Morning", "explanation": "greeting"},
                {"id": "p9b9", "translation": "nope", "explanation": "hallucinated"},
            ]
        }
        got = llm._collect(reply, self.page0)
        self.assertEqual(list(got), ["p0b0"])

    def test_thinking_preamble_is_stripped(self):
        self.assertEqual(llm.strip_thinking("<think>hmm</think>{\"a\":1}"), '{"a":1}')


class ResumeLogic(unittest.TestCase):
    def setUp(self):
        self.volume = parse_mokuro(json.dumps(SAMPLE), "sample-1", "fallback")

    def _saved(self, ids, model="qwen", prompt="p"):
        return {
            "model": model,
            "promptId": blobmod.prompt_id(prompt),
            "entries": {i: {"text": "", "translation": "t", "explanation": "e"} for i in ids},
        }

    def test_complete_when_every_bubble_present(self):
        saved = self._saved(["p0b0", "p0b2", "p1b0"])
        self.assertTrue(pipeline.is_complete(saved, self.volume, "qwen", "p"))

    def test_incomplete_when_a_bubble_is_missing(self):
        saved = self._saved(["p0b0"])
        self.assertFalse(pipeline.is_complete(saved, self.volume, "qwen", "p"))

    def test_changing_the_model_invalidates_saved_work(self):
        saved = self._saved(["p0b0", "p0b2", "p1b0"])
        self.assertFalse(pipeline.is_complete(saved, self.volume, "other-model", "p"))

    def test_changing_the_prompt_invalidates_saved_work(self):
        saved = self._saved(["p0b0", "p0b2", "p1b0"])
        self.assertFalse(pipeline.is_complete(saved, self.volume, "qwen", "different prompt"))


class KeyEncoding(unittest.TestCase):
    def test_slashes_stay_literal_but_segments_are_escaped(self):
        self.assertEqual(encode_key("books/My Book/pretranslations"), "books/My%20Book/pretranslations")

    def test_japanese_sync_ids_are_percent_encoded(self):
        self.assertEqual(encode_key("books/あ/metadata"), "books/%E3%81%82/metadata")


if __name__ == "__main__":
    unittest.main(verbosity=2)
