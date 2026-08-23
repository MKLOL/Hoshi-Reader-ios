"""The `books/{syncId}/sentences` blob — one file per novel.

The EPUB counterpart of `blob.py`. Same reasoning: one key per book, not one per unit, because the
sync server is rate-limited and a novel has thousands of sentences. One blob is a single GET on the
device.

Entries are addressed `c{spine}s{normalizedStart}` — see `epub.py` and
docs/EPUB_TRANSLATION_ARCHITECTURE.md §3/§4.

Keep this shape in sync with:
  - iOS  Features/AI/EpubTranslationStore.swift  (HttpSyncSentencesBlob)
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass, field
from datetime import datetime, timezone

from .epub import EpubBook, Sentence, text_hash

# Bump when the shape changes incompatibly; readers ignore blobs with a newer version.
BLOB_VERSION = 1
# Distinguishes this from the bubble-addressed manga blob. A reader checks it before trusting the
# entry keys, so a blob written to the wrong key can never be read as the wrong kind.
BLOB_KIND = "epub"


def prompt_id(prompt: str) -> str:
    return "sha256:" + hashlib.sha256(prompt.encode("utf-8")).hexdigest()[:32]


def rfc3339_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


@dataclass
class Entry:
    spine: int
    start: int
    length: int
    text: str
    translation: str
    explanation: str

    def to_json(self) -> dict:
        return {
            "spine": self.spine,
            "start": self.start,
            "len": self.length,
            "text": self.text,
            "hash": text_hash(self.text),
            "translation": self.translation,
            "explanation": self.explanation,
        }

    @classmethod
    def from_json(cls, doc: dict) -> "Entry":
        return cls(
            spine=int(doc.get("spine", 0)),
            start=int(doc.get("start", 0)),
            length=int(doc.get("len", 0)),
            text=doc.get("text", ""),
            translation=doc.get("translation", ""),
            explanation=doc.get("explanation", ""),
        )

    @classmethod
    def for_sentence(cls, sentence: Sentence, translation: str, explanation: str) -> "Entry":
        return cls(
            spine=sentence.spine,
            start=sentence.start,
            length=sentence.length,
            # Always the BOOK's text, never the translator's echo of it — the reader verifies the
            # hash of this against what it finds in the DOM.
            text=sentence.text,
            translation=translation.strip(),
            explanation=explanation.strip(),
        )


@dataclass
class SentencesBlob:
    sync_id: str
    title: str
    model: str
    prompt: str
    spine_count: int = 0
    generated_at: str = field(default_factory=rfc3339_now)
    entries: dict[str, Entry] = field(default_factory=dict)
    # Set when rehydrating a saved blob, whose original prompt text is not stored. Without it
    # `to_json` would recompute promptId from an empty prompt and a re-upload would overwrite the
    # server copy with the hash of "" — silently destroying prompt-change invalidation.
    prompt_id_override: str | None = None

    def add(self, sentence_id: str, entry: Entry) -> None:
        self.entries[sentence_id] = entry

    def to_json(self) -> dict:
        return {
            "version": BLOB_VERSION,
            "kind": BLOB_KIND,
            "syncId": self.sync_id,
            "title": self.title,
            "model": self.model,
            "promptId": self.prompt_id_override or prompt_id(self.prompt),
            "generatedAt": self.generated_at,
            "spineCount": self.spine_count,
            # Sorted so the file is stable across runs and diffable.
            "entries": {key: entry.to_json() for key, entry in sorted(self.entries.items())},
        }

    def to_bytes(self) -> bytes:
        # ensure_ascii=False keeps the Japanese readable and roughly halves the byte size.
        return json.dumps(self.to_json(), ensure_ascii=False, separators=(",", ":")).encode("utf-8")

    @classmethod
    def from_json(cls, doc: dict) -> "SentencesBlob":
        blob = cls(
            sync_id=doc.get("syncId", ""),
            title=doc.get("title", ""),
            model=doc.get("model", ""),
            prompt="",
            spine_count=int(doc.get("spineCount", 0)),
            generated_at=doc.get("generatedAt", ""),
            prompt_id_override=doc.get("promptId") or None,
        )
        for key, value in (doc.get("entries") or {}).items():
            blob.entries[key] = Entry.from_json(value)
        return blob

    @classmethod
    def for_book(cls, book: EpubBook, model: str, prompt: str) -> "SentencesBlob":
        return cls(
            sync_id=book.sync_id,
            title=book.title,
            model=model,
            prompt=prompt,
            spine_count=book.spine_count,
        )


def blob_key(sync_id: str) -> str:
    return f"books/{sync_id}/sentences"
