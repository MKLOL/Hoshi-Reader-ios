"""The `books/{syncId}/pretranslations` blob — one file per book.

Deliberately ONE key per volume rather than one per bubble: a volume has a few thousand bubbles,
and the sync server is rate-limited to ~500 requests/minute, so per-bubble keys would take minutes
per book and hammer the server. One blob is a single GET on the device.

The readers address a bubble by `p{page}b{block}` (its mokuro page + block index), which is stable
across re-imports because it is derived from the OCR file itself. `hash` is a short digest of the
source Japanese: the reader uses it to detect that a bubble's text changed (a re-OCR) and to fall
back to a text match when indices shifted.

Keep this shape in sync with:
  - iOS     Features/HttpSync/SyncBlobs.swift        (HttpSyncPretranslationsBlob)
  - Android features/sync/http/HttpSyncBlobs.kt      (PretranslationsBlob)
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass, field
from datetime import datetime, timezone

# Bump when the shape changes incompatibly; readers ignore blobs with a newer major version.
BLOB_VERSION = 1


def text_hash(text: str) -> str:
    """Short, stable digest of a bubble's source Japanese."""
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]


def prompt_id(prompt: str) -> str:
    return "sha256:" + hashlib.sha256(prompt.encode("utf-8")).hexdigest()[:32]


def rfc3339_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


@dataclass
class Entry:
    text: str
    translation: str
    explanation: str

    def to_json(self) -> dict:
        return {
            "text": self.text,
            "hash": text_hash(self.text),
            "translation": self.translation,
            "explanation": self.explanation,
        }


@dataclass
class PretranslationsBlob:
    sync_id: str
    title: str
    model: str
    prompt: str
    generated_at: str = field(default_factory=rfc3339_now)
    entries: dict[str, Entry] = field(default_factory=dict)
    # Set only when rehydrating a saved blob, whose original prompt text is not stored. Without
    # it `to_json` would recompute promptId from an empty prompt and a re-upload would overwrite
    # the server copy with the hash of "" — silently destroying prompt-change invalidation.
    prompt_id_override: str | None = None

    def add(self, block_id: str, entry: Entry) -> None:
        self.entries[block_id] = entry

    def to_json(self) -> dict:
        return {
            "version": BLOB_VERSION,
            "syncId": self.sync_id,
            "title": self.title,
            "model": self.model,
            "promptId": self.prompt_id_override or prompt_id(self.prompt),
            "generatedAt": self.generated_at,
            # Flat map keyed by `p{page}b{block}` so a reader lookup is a single dictionary hit.
            "entries": {key: entry.to_json() for key, entry in sorted(self.entries.items())},
        }

    def to_bytes(self) -> bytes:
        # ensure_ascii=False keeps the Japanese readable and roughly halves the byte size.
        return json.dumps(self.to_json(), ensure_ascii=False, separators=(",", ":")).encode("utf-8")

    @classmethod
    def from_json(cls, doc: dict) -> "PretranslationsBlob":
        blob = cls(
            sync_id=doc.get("syncId", ""),
            title=doc.get("title", ""),
            model=doc.get("model", ""),
            prompt="",
            generated_at=doc.get("generatedAt", ""),
            prompt_id_override=doc.get("promptId") or None,
        )
        for key, value in (doc.get("entries") or {}).items():
            blob.entries[key] = Entry(
                text=value.get("text", ""),
                translation=value.get("translation", ""),
                explanation=value.get("explanation", ""),
            )
        return blob


def blob_key(sync_id: str) -> str:
    return f"books/{sync_id}/pretranslations"
