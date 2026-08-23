"""Orchestration for novels: discover EPUBs, export work, merge translations, upload one blob.

The EPUB counterpart of `pipeline.py`, and deliberately the same shape: everything is resumable,
the checkpoint on disk is the source of truth, and a book is only uploaded once it is complete for
the current model + prompt.

The unit of work here is a **chapter** rather than a page, because that is what a translator (an
LLM, a person, or an agent) can hold in its head at once and because a chapter is the natural
boundary for context.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from .epub import EpubBook, Sentence, load_epub, parse_epub, verify
from .epub_blob import Entry, SentencesBlob, blob_key, prompt_id
from .kv import KvClient, KvError

# Sentences before/after the paragraph being translated that ride along as context. A line of
# Japanese dialogue in isolation is frequently untranslatable — an unmarked subject, an implied
# object, a pronoun carried over two lines ago — and this window is what makes it readable.
CONTEXT_BEFORE = 6
CONTEXT_AFTER = 2

# Used only when the app has no synced prompt. The shipped default is bubble-worded ("For the manga
# speech bubble below…"), which reads oddly for prose, so novels get their own wording. A synced
# prompt always wins: matching the user's own online explanations is the whole point.
FALLBACK_PROMPT = (
    "You are a helpful Japanese reading tutor. For the sentence below, give a natural English "
    "translation, then a short, concise breakdown of any tricky vocabulary or grammar."
)


@dataclass
class BookRef:
    sync_id: str
    title: str
    content_type: str
    deleted: bool = False


# ---------------------------------------------------------------------------------------------
# Discovery / loading
# ---------------------------------------------------------------------------------------------


def discover_epubs(client: KvClient, log: Callable[[str], None] = print) -> list[BookRef]:
    """Lists every non-deleted EPUB on the server."""
    sync_ids: set[str] = set()
    for meta in client.list_all(prefix="books/"):
        parts = meta.key.split("/")
        if len(parts) >= 3 and parts[0] == "books":
            sync_ids.add(parts[1])

    books: list[BookRef] = []
    for sync_id in sorted(sync_ids):
        doc = client.get_json(f"books/{sync_id}/metadata")
        if not doc:
            continue
        content_type = (doc.get("contentType") or "").lower()
        if content_type != "epub" or doc.get("deletedAt"):
            continue
        books.append(BookRef(sync_id=sync_id, title=(doc.get("title") or sync_id),
                             content_type=content_type, deleted=False))
    log(f"Found {len(books)} EPUB(s) on the server.")
    return books


def fetch_epub_bytes(client: KvClient, sync_id: str) -> bytes | None:
    """Downloads `books/{syncId}/epub.zip`.

    Whole-file, unlike the manga path's range read: a novel's payload is a couple of megabytes
    (there are no page images), and we need nearly every member of it, so ranged reads would cost
    dozens of requests to save nothing.

    The payload is a zip of the book DIRECTORY, which for an EPUB is the unpacked book — so its
    layout (META-INF/container.xml + the OPF) is exactly what the parser expects.
    """
    return client.get(f"books/{sync_id}/epub.zip")


def load_book(
    sync_id: str,
    client: KvClient | None = None,
    local_path: Path | None = None,
    fallback_title: str = "",
    log: Callable[[str], None] = print,
) -> EpubBook | None:
    """Reads a book from a local `.epub` or from the sync server."""
    if local_path is not None:
        return load_epub(local_path, sync_id=sync_id, fallback_title=fallback_title)
    if client is None:
        raise ValueError("load_book needs either a local_path or a client.")
    raw = fetch_epub_bytes(client, sync_id)
    if raw is None:
        log(f"{sync_id}: no epub.zip on the server — sync the book from the device first.")
        return None
    return parse_epub(raw, sync_id=sync_id, fallback_title=fallback_title)


def fetch_user_prompt(
    client: KvClient | None,
    log: Callable[[str], None] = print,
    override: str | None = None,
) -> str:
    """The prompt to translate with: your local override, else the app's synced one, else default."""
    if override and override.strip():
        log("Using your locally edited prompt.")
        return override.strip()
    if client is None:
        return FALLBACK_PROMPT
    try:
        settings = client.get_json("app/ai_chat_settings")
    except KvError as exc:
        log(f"Could not read synced AI settings ({exc}); using the default tutor prompt.")
        return FALLBACK_PROMPT
    prompt = ((settings or {}).get("promptText") or "").strip()
    if not prompt:
        log("No synced prompt found; using the default tutor prompt.")
        return FALLBACK_PROMPT
    log("Using your synced ChatGPT prompt for the offline explanations.")
    return prompt


# ---------------------------------------------------------------------------------------------
# Checkpoints
# ---------------------------------------------------------------------------------------------


def state_path(out_dir: Path, sync_id: str) -> Path:
    # Sync ids are already filename-safe, but a stray separator would write outside out_dir.
    safe = "".join("_" if c in '/\\:*?"<>|' else c for c in sync_id)
    return out_dir / f"{safe}.json"


def load_saved(out_dir: Path, sync_id: str) -> dict | None:
    path = state_path(out_dir, sync_id)
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except ValueError:
        return None


def save_checkpoint(out_dir: Path, blob: SentencesBlob) -> Path:
    """Writes the checkpoint atomically.

    Temp-file-plus-rename, not a plain write: `load_saved` swallows a `ValueError`, so a checkpoint
    truncated by a crash or a full disk would come back as "nothing translated yet" and the next
    import would cheerfully overwrite hours of work with a handful of entries.
    """
    out_dir.mkdir(parents=True, exist_ok=True)
    path = state_path(out_dir, blob.sync_id)
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(blob.to_json(), ensure_ascii=False, indent=1), encoding="utf-8")
    tmp.replace(path)
    return path


class CheckpointMismatch(RuntimeError):
    """The checkpoint on disk was made with a different model or prompt."""


def resume(
    book: EpubBook, out_dir: Path, model: str, prompt: str, allow_reset: bool = False
) -> SentencesBlob:
    """A blob preloaded with whatever was already produced for this same model + prompt.

    Raises `CheckpointMismatch` when the checkpoint was made with a different model or prompt,
    rather than quietly starting from empty. Silently resetting was a work-destroying trap: the
    caller then saves the empty-plus-this-chapter blob straight over a checkpoint holding the whole
    book, and a prompt can change without the user doing anything wrong (a transient failure
    reading the synced settings is enough).
    """
    blob = SentencesBlob.for_book(book, model=model, prompt=prompt)
    saved = load_saved(out_dir, book.sync_id)
    if not saved:
        return blob
    saved_model, saved_prompt = saved.get("model"), saved.get("promptId")
    if saved_model != model or saved_prompt != prompt_id(prompt):
        if not allow_reset:
            raise CheckpointMismatch(
                f"{state_path(out_dir, book.sync_id)} holds "
                f"{len(saved.get('entries') or {})} sentence(s) made with model "
                f"{saved_model!r} / prompt {saved_prompt!r}, but this run uses {model!r} / "
                f"{prompt_id(prompt)!r}.\n"
                "Continuing would overwrite that work. Either match the previous run, or pass "
                "--new-run to start over deliberately."
            )
        return blob
    for key, value in (saved.get("entries") or {}).items():
        blob.entries[key] = Entry.from_json(value)
    return blob


def is_complete(saved: dict | None, book: EpubBook, model: str, prompt: str) -> bool:
    if not saved:
        return False
    if saved.get("model") != model or saved.get("promptId") != prompt_id(prompt):
        return False
    have = set((saved.get("entries") or {}).keys())
    return all(s.id in have for s in book.sentences)


# ---------------------------------------------------------------------------------------------
# The translator seam: export -> (anything translates it) -> import
# ---------------------------------------------------------------------------------------------


def _context_window(sentences: list[Sentence], first: int, last: int) -> tuple[list[Sentence], list[Sentence]]:
    before = sentences[max(0, first - CONTEXT_BEFORE):first]
    after = sentences[last + 1:last + 1 + CONTEXT_AFTER]
    return before, after


def _as_pairs(sentences: list[Sentence]) -> list[dict]:
    return [{"id": s.id, "jp": s.text} for s in sentences]


def export_sentences(
    book: EpubBook,
    out_dir: Path,
    target_dir: Path,
    done: set[str] | None = None,
    log: Callable[[str], None] = print,
) -> int:
    """Writes one file per chapter holding every sentence still needing a translation.

    One file per chapter, not one big file: a novel is a few thousand sentences, which is more than
    a translator can do well in a single pass. A chapter is ~100 sentences — one comfortable pass,
    and a natural place to stop and resume.
    """
    done = done if done is not None else set((load_saved(out_dir, book.sync_id) or {}).get("entries", {}))
    target_dir.mkdir(parents=True, exist_ok=True)

    index: list[dict] = []
    total_remaining = 0
    for chapter in book.chapters:
        if not chapter.sentences:
            continue
        todo = [s for s in chapter.sentences if s.id not in done]
        if not todo:
            continue

        by_paragraph: dict[int, list[Sentence]] = {}
        for sentence in chapter.sentences:
            by_paragraph.setdefault(sentence.paragraph, []).append(sentence)
        position = {s.id: i for i, s in enumerate(chapter.sentences)}

        paragraphs = []
        for _, group in sorted(by_paragraph.items()):
            wanted = [s for s in group if s.id not in done]
            if not wanted:
                continue
            before, after = _context_window(
                chapter.sentences, position[group[0].id], position[group[-1].id]
            )
            paragraphs.append({
                "context_before": _as_pairs(before),
                "translate": _as_pairs(wanted),
                "context_after": _as_pairs(after),
            })

        name = f"c{chapter.spine:03d}.json"
        (target_dir / name).write_text(json.dumps({
            "syncId": book.sync_id,
            "title": book.title,
            "spine": chapter.spine,
            "heading": chapter.heading,
            "remaining": len(todo),
            "paragraphs": paragraphs,
        }, ensure_ascii=False, indent=1), encoding="utf-8")
        index.append({"file": name, "spine": chapter.spine, "heading": chapter.heading,
                      "remaining": len(todo)})
        total_remaining += len(todo)

    (target_dir / "index.json").write_text(json.dumps({
        "syncId": book.sync_id,
        "title": book.title,
        "spineCount": book.spine_count,
        "totalSentences": len(book.sentences),
        "remaining": total_remaining,
        "chapters": index,
    }, ensure_ascii=False, indent=1), encoding="utf-8")

    log(f"Wrote {total_remaining} untranslated sentence(s) across {len(index)} chapter file(s) "
        f"to {target_dir}")
    return total_remaining


def _translation_docs(source: Path) -> tuple[list, list[str]]:
    """Accepts a single JSON file or a directory of them. Returns (docs, per-file errors).

    One unparseable file must not abort the run: aborting discarded the other forty-odd chapters
    in the same import, which is a lot of translation to lose to one stray comma.
    """
    paths = ([p for p in sorted(source.glob("*.json")) if p.name != "index.json"]
             if source.is_dir() else [source])
    docs, errors = [], []
    for path in paths:
        try:
            docs.append(json.loads(path.read_text(encoding="utf-8")))
        except (ValueError, OSError) as exc:
            errors.append(f"{path.name}: {exc}")
    return docs, errors


def _flatten(doc, sync_id: str) -> dict[str, dict]:
    """Normalizes the shapes a translator might hand back into `{sentenceId: {...}}`.

    Accepts `{id: {...}}`, `{syncId: {id: {...}}}` for THIS book, and `[{"id": …, …}, …]`.

    The wrapper is unwrapped only when its key is this book's syncId. The old heuristic unwrapped
    any single-key object, so a file belonging to a different book was accepted wholesale — and
    because sentence ids (`c{spine}s{start}`) collide freely between books, a good fraction of it
    would land on real sentences. Nothing downstream could catch that: the entry takes the text and
    address from THIS book and only the translation from the file, so the hash matches and the
    reader shows a confidently wrong translation.
    """
    if isinstance(doc, list):
        out = {}
        for item in doc:
            if isinstance(item, dict) and isinstance(item.get("id"), str):
                out[item["id"]] = item
        return out
    if not isinstance(doc, dict):
        return {}
    inner = doc.get(sync_id)
    if isinstance(inner, dict):
        return inner
    return doc


def import_translations(
    book: EpubBook,
    source: Path,
    out_dir: Path,
    model: str,
    prompt: str,
    log: Callable[[str], None] = print,
    allow_reset: bool = False,
) -> SentencesBlob:
    """Merges `{sentenceId: {translation, explanation}}` back into the checkpoint."""
    blob = resume(book, out_dir, model=model, prompt=prompt, allow_reset=allow_reset)
    by_id = {s.id: s for s in book.sentences}

    docs, file_errors = _translation_docs(source)
    for error in file_errors:
        log(f"  unreadable, skipped: {error}")

    added = unknown = empty = 0
    for doc in docs:
        for sentence_id, value in _flatten(doc, book.sync_id).items():
            sentence = by_id.get(sentence_id)
            if sentence is None or not isinstance(value, dict):
                unknown += 1
                continue
            translation = str(value.get("translation", "")).strip()
            if not translation:
                empty += 1
                continue
            blob.add(sentence_id, Entry.for_sentence(
                sentence, translation, str(value.get("explanation", "")).strip()
            ))
            added += 1

    save_checkpoint(out_dir, blob)
    log(f"{book.title}: +{added} -> {len(blob.entries)}/{len(book.sentences)} sentences"
        + (f", {unknown} id(s) not in this book" if unknown else "")
        + (f", {empty} empty" if empty else ""))
    if unknown and added == 0:
        log("  WARNING: nothing matched. Is this the right book's translations?")
    return blob


# ---------------------------------------------------------------------------------------------
# Verification / upload
# ---------------------------------------------------------------------------------------------


def verify_checkpoint(book: EpubBook, blob: SentencesBlob) -> list[str]:
    """Every problem that would make the reader drop a button, before we waste an upload on it."""
    problems = verify(book)
    if not book.sentences:
        problems.append("this EPUB produced no sentences at all — nothing to upload")
    # Blob-level identity. `--upload-only` reads an existing checkpoint, which may predate a
    # re-export: shipping its stale `spineCount` would break the reader's own sanity check.
    if blob.sync_id and blob.sync_id != book.sync_id:
        problems.append(f"checkpoint is for {blob.sync_id!r}, not {book.sync_id!r}")
    if blob.spine_count and blob.spine_count != book.spine_count:
        problems.append(
            f"checkpoint spineCount {blob.spine_count} != this EPUB's {book.spine_count}"
        )
    by_id = {s.id: s for s in book.sentences}
    for sentence_id, entry in sorted(blob.entries.items()):
        sentence = by_id.get(sentence_id)
        if sentence is None:
            problems.append(f"{sentence_id}: no such sentence in this EPUB")
            continue
        if entry.text != sentence.text:
            problems.append(f"{sentence_id}: stored text differs from the book's")
        if (entry.spine, entry.start, entry.length) != (sentence.spine, sentence.start, sentence.length):
            problems.append(f"{sentence_id}: address drifted from the book's")
        if not entry.translation.strip():
            problems.append(f"{sentence_id}: empty translation")
    missing = [s.id for s in book.sentences if s.id not in blob.entries]
    if missing:
        problems.append(f"{len(missing)} sentence(s) not translated yet, first: {missing[0]}")
    return problems


def upload_book(client: KvClient, blob: SentencesBlob, log: Callable[[str], None] = print) -> None:
    key = blob_key(blob.sync_id)
    body = blob.to_bytes()
    client.put(key, body, content_type="application/json")
    log(f"  uploaded {key} ({len(body) / 1024:.0f} KB, {len(blob.entries)} sentences)")
