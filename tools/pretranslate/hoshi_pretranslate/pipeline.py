"""Orchestration: discover manga on the sync server, translate, upload one blob per book.

Everything is resumable. Each volume's work-in-progress blob is written to disk after every page,
so a crash, a reboot, or closing the window mid-run costs at most one page. A second run skips
volumes that are already complete for the same model + prompt.
"""

from __future__ import annotations

import json
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

from .blob import Entry, PretranslationsBlob, blob_key, prompt_id
from .kv import KvClient, KvError
from .mokuro import Volume, bubbles_by_page, fetch_mokuro_json, parse_mokuro

# The default tutor prompt, matching the readers' AiChatDefaults.prompt. Only used when the
# server has no synced ai_chat_settings blob.
FALLBACK_PROMPT = (
    "You are a helpful Japanese reading tutor. For the manga speech bubble below, give a natural "
    "English translation, then a short, concise breakdown of any tricky vocabulary or grammar."
)


@dataclass
class BookRef:
    sync_id: str
    title: str
    content_type: str
    deleted: bool = False


@dataclass
class Progress:
    """Live counters the GUI renders."""

    book_index: int = 0
    book_total: int = 0
    book_title: str = ""
    page_index: int = 0
    page_total: int = 0
    bubbles_done: int = 0
    bubbles_total: int = 0
    finished_books: list[str] = field(default_factory=list)

    # Throughput measured over this volume only (resumed work is excluded, so the rate reflects
    # actual GPU output rather than being flattered by bubbles that were already on disk).
    bubbles_this_run: int = 0
    elapsed_seconds: float = 0.0

    @property
    def bubbles_per_minute(self) -> float:
        if self.elapsed_seconds <= 0 or self.bubbles_this_run <= 0:
            return 0.0
        return self.bubbles_this_run * 60.0 / self.elapsed_seconds

    @property
    def eta_seconds(self) -> float:
        """Seconds left on the CURRENT volume, or 0 while there is no rate yet."""
        rate = self.bubbles_per_minute / 60.0
        remaining = max(0, self.bubbles_total - self.bubbles_done)
        return remaining / rate if rate > 0 else 0.0

    def eta_text(self) -> str:
        seconds = self.eta_seconds
        if seconds <= 0:
            return "estimating..."
        if seconds < 90:
            return f"{seconds:.0f}s left"
        minutes = seconds / 60
        if minutes < 90:
            return f"{minutes:.0f} min left"
        return f"{minutes / 60:.1f} h left"


def fetch_user_prompt(
    client: KvClient,
    log: Callable[[str], None] = print,
    override: str | None = None,
) -> str:
    """The prompt to translate with: your local override if set, else the one the app synced."""
    if override and override.strip():
        log("Using your locally edited prompt.")
        return override.strip()
    try:
        settings = client.get_json("app/ai_chat_settings")
    except KvError as exc:
        log(f"Could not read synced AI settings ({exc}); using the default tutor prompt.")
        return FALLBACK_PROMPT
    if not settings:
        log("No synced AI settings found; using the default tutor prompt.")
        return FALLBACK_PROMPT
    prompt = (settings.get("promptText") or "").strip()
    if not prompt:
        return FALLBACK_PROMPT
    log("Using your synced ChatGPT prompt for the offline explanations.")
    return prompt


def discover_manga(client: KvClient, log: Callable[[str], None] = print) -> list[BookRef]:
    """Lists every non-deleted mokuro book on the server."""
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
        deleted = bool(doc.get("deletedAt"))
        if content_type != "mokuro" or deleted:
            continue
        books.append(
            BookRef(
                sync_id=sync_id,
                title=(doc.get("title") or sync_id),
                content_type=content_type,
                deleted=deleted,
            )
        )
    log(f"Found {len(books)} manga volume(s) on the server.")
    return books


def load_volume(client: KvClient, book: BookRef, log: Callable[[str], None] = print) -> Volume | None:
    raw = fetch_mokuro_json(client, book.sync_id, log=log)
    if raw is None:
        log(f"{book.title}: no mokuro sidecar in its payload - skipping.")
        return None
    return parse_mokuro(raw, book.sync_id, book.title)


def _state_path(out_dir: Path, sync_id: str) -> Path:
    # Sync ids are already filename-safe (the apps derive them from slugified titles), but be
    # defensive: a stray separator would otherwise write outside out_dir.
    safe = "".join("_" if c in '/\\:*?"<>|' else c for c in sync_id)
    return out_dir / f"{safe}.json"


def load_saved(out_dir: Path, sync_id: str) -> dict | None:
    path = _state_path(out_dir, sync_id)
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except ValueError:
        return None


def is_complete(saved: dict | None, volume: Volume, model_id: str, prompt: str) -> bool:
    """True when a saved blob already covers this volume for the same model and prompt."""
    if not saved:
        return False
    if saved.get("model") != model_id or saved.get("promptId") != prompt_id(prompt):
        return False
    have = set((saved.get("entries") or {}).keys())
    return all(bubble.block_id in have for bubble in volume.bubbles)


def translate_volume(
    translator,
    volume: Volume,
    user_prompt: str,
    model_id: str,
    out_dir: Path,
    progress: Progress,
    log: Callable[[str], None] = print,
    should_stop: Callable[[], bool] = lambda: False,
    on_progress: Callable[[Progress], None] = lambda _: None,
) -> PretranslationsBlob:
    """Translates a volume page by page, checkpointing after each page."""
    out_dir.mkdir(parents=True, exist_ok=True)
    result = PretranslationsBlob(
        sync_id=volume.sync_id,
        title=volume.title,
        model=model_id,
        prompt=user_prompt,
    )

    # Resume: keep entries already produced for this same model + prompt.
    saved = load_saved(out_dir, volume.sync_id)
    if saved and saved.get("model") == model_id and saved.get("promptId") == prompt_id(user_prompt):
        for key, value in (saved.get("entries") or {}).items():
            result.entries[key] = Entry(
                text=value.get("text", ""),
                translation=value.get("translation", ""),
                explanation=value.get("explanation", ""),
            )
        if result.entries:
            log(f"  resuming with {len(result.entries)} bubble(s) already done")

    pages = bubbles_by_page(volume)
    progress.page_total = len(pages)
    progress.bubbles_total = len(volume.bubbles)
    progress.bubbles_done = len(result.entries)

    started_at = time.monotonic()
    progress.bubbles_this_run = 0
    progress.elapsed_seconds = 0.0

    ordered = sorted(pages.items())
    for page_number, (page_index, bubbles) in enumerate(ordered, start=1):
        if should_stop():
            log("  stopped by user")
            break
        progress.page_index = page_number
        on_progress(progress)

        todo = [b for b in bubbles if b.block_id not in result.entries]
        if not todo:
            continue

        # The model sees the whole current page plus the one before it, even when only a few
        # bubbles still need translating — that context is what disambiguates short lines.
        previous_page = ordered[page_number - 2][1] if page_number >= 2 else []
        translated = translator.translate_page(
            bubbles, user_prompt, previous_page=previous_page, targets=todo
        )
        produced = 0
        for bubble in todo:
            got = translated.get(bubble.block_id)
            if got is None:
                continue
            result.add(
                bubble.block_id,
                Entry(text=bubble.text, translation=got.translation, explanation=got.explanation),
            )
            produced += 1
        progress.bubbles_done = len(result.entries)
        progress.bubbles_this_run += produced
        progress.elapsed_seconds = time.monotonic() - started_at
        on_progress(progress)
        # Checkpoint every page so an interrupted run loses at most one page of GPU time.
        _state_path(out_dir, volume.sync_id).write_text(
            json.dumps(result.to_json(), ensure_ascii=False, indent=1), encoding="utf-8"
        )

    return result


def upload_volume(client: KvClient, result: PretranslationsBlob, log: Callable[[str], None] = print) -> None:
    key = blob_key(result.sync_id)
    body = result.to_bytes()
    client.put(key, body, content_type="application/json")
    log(f"  uploaded {key} ({len(body) / 1024:.0f} KB, {len(result.entries)} bubbles)")


def run(
    client: KvClient,
    translator,
    model_id: str,
    out_dir: Path,
    log: Callable[[str], None] = print,
    should_stop: Callable[[], bool] = lambda: False,
    on_progress: Callable[[Progress], None] = lambda _: None,
    only_sync_ids: list[str] | None = None,
    upload: bool = True,
    prompt_override: str | None = None,
) -> Progress:
    """Full pass: discover -> translate -> upload."""
    user_prompt = fetch_user_prompt(client, log=log, override=prompt_override)
    books = discover_manga(client, log=log)
    if only_sync_ids:
        # Explicit ORDER, not just a filter: the list is the queue, so the volumes you care about
        # are translated first and an interrupted run has already finished the ones that matter.
        by_id = {b.sync_id: b for b in books}
        ordered_books = []
        for sync_id in dict.fromkeys(only_sync_ids):
            book = by_id.get(sync_id)
            if book is not None:
                ordered_books.append(book)
        books = ordered_books

    progress = Progress(book_total=len(books))
    for index, book in enumerate(books, start=1):
        if should_stop():
            log("Stopped.")
            break
        progress.book_index = index
        progress.book_title = book.title
        progress.page_index = 0
        on_progress(progress)
        log(f"[{index}/{len(books)}] {book.title}")

        volume = load_volume(client, book, log=log)
        if volume is None or not volume.bubbles:
            log("  no OCR text - skipping")
            continue

        saved = load_saved(out_dir, volume.sync_id)
        if is_complete(saved, volume, model_id, user_prompt):
            log(f"  already done ({len(saved.get('entries') or {})} bubbles) - skipping")
            progress.finished_books.append(book.title)
            if upload:
                upload_volume(client, PretranslationsBlob.from_json(saved), log=log)
            continue

        log(f"  {len(volume.bubbles)} bubbles across {volume.page_count} pages")
        result = translate_volume(
            translator,
            volume,
            user_prompt,
            model_id,
            out_dir,
            progress,
            log=log,
            should_stop=should_stop,
            on_progress=on_progress,
        )
        if progress.bubbles_per_minute > 0:
            log(f"  {progress.bubbles_per_minute:.0f} bubbles/min this volume")
        # A volume interrupted by Stop is NOT finished: uploading it would publish a half-empty
        # blob, and counting it as finished would tell the user the book was done. The local
        # checkpoint is already on disk, so the next run resumes exactly where this one stopped.
        if should_stop():
            log("  stopped part-way - keeping the checkpoint, not uploading")
            break
        if upload and result.entries:
            upload_volume(client, result, log=log)
        progress.finished_books.append(book.title)
        on_progress(progress)

    return progress
