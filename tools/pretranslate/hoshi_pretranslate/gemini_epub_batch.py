"""Resumable EPUB translation through Google's file-backed Gemini Batch API.

This module deliberately reuses Hoshi's tested EPUB extractor and checkpoint importer. It does not
upload to Hoshi sync: partial translations stay local until the ordinary EPUB verifier can certify
the complete book.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import regex

from . import epub_pipeline
from .epub import EpubBook, EpubError, Sentence, load_epub, normalize, verify
from .epub_blob import prompt_id


MODEL = "gemini-3.6-flash"
SYNC_ID = "zenitendou-02"
TRIAL_FRACTION = 0.10
TARGETS_PER_REQUEST = 5
CONTEXT_BEFORE = 4
CONTEXT_AFTER = 1
THINKING_LEVEL = "medium"
MAX_OUTPUT_TOKENS = 8192
TERMINAL_STATES = {
    "JOB_STATE_SUCCEEDED",
    "JOB_STATE_FAILED",
    "JOB_STATE_CANCELLED",
    "JOB_STATE_EXPIRED",
}

TOOL_DIR = Path(__file__).resolve().parents[1]
DEFAULT_EPUB = Path.home() / "Downloads" / "ふしぎ駄菓子屋銭天堂２.epub"
DEFAULT_PROMPT = TOOL_DIR / "GEMINI_EPUB_PROMPT.md"
DEFAULT_WORK_DIR = TOOL_DIR / "work" / "zenitendou-02-gemini"

_WORD_BULLET = regex.compile(r"^- (.+)【([^】]+)】 \(\*[^*]+\*\) — .+$")
_BAD_READING = regex.compile(
    r"[0-9A-Za-z０-９Ａ-Ｚａ-ｚ\p{Radical}\p{Unified_Ideograph}]"
)


class BatchWorkflowError(RuntimeError):
    """A safe, user-actionable stop in the local or remote workflow."""


@dataclass(frozen=True)
class Chunk:
    key: str
    spine: int
    heading: str
    context_before: tuple[Sentence, ...]
    targets: tuple[Sentence, ...]
    context_after: tuple[Sentence, ...]

    def index_json(self) -> dict[str, Any]:
        return {
            "key": self.key,
            "spine": self.spine,
            "heading": self.heading,
            "targetIds": [sentence.id for sentence in self.targets],
        }


def _utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _sha256_bytes(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _atomic_bytes(path: Path, raw: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_bytes(raw)
    temporary.replace(path)


def _atomic_json(path: Path, value: Any) -> None:
    raw = json.dumps(value, ensure_ascii=False, indent=1).encode("utf-8") + b"\n"
    _atomic_bytes(path, raw)


def _load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise BatchWorkflowError(f"Cannot read valid JSON from {path}: {exc}") from exc


def _load_prompt(path: Path) -> str:
    try:
        prompt = path.read_text(encoding="utf-8").strip()
    except OSError as exc:
        raise BatchWorkflowError(f"Cannot read prompt {path}: {exc}") from exc
    if not prompt:
        raise BatchWorkflowError(f"Prompt is empty: {path}")
    return prompt


def _load_book(path: Path, sync_id: str) -> EpubBook:
    path = path.expanduser().resolve()
    if not path.is_file():
        raise BatchWorkflowError(f"EPUB not found: {path}")
    if path.stat().st_size == 0:
        raise BatchWorkflowError(
            f"EPUB is empty: {path}. Finish downloading/copying the real book first."
        )
    try:
        book = load_epub(path, sync_id=sync_id, fallback_title=sync_id)
    except (EpubError, OSError) as exc:
        raise BatchWorkflowError(f"Cannot parse EPUB {path}: {exc}") from exc
    problems = verify(book)
    if problems:
        detail = "\n".join(f"  {problem}" for problem in problems[:20])
        raise BatchWorkflowError(
            f"EPUB addressing failed with {len(problems)} problem(s):\n{detail}"
        )
    if not book.sentences:
        raise BatchWorkflowError("EPUB produced no translatable sentences.")
    return book


def _validate_explanation(sentence: Sentence, explanation: str) -> list[str]:
    errors: list[str] = []
    if not explanation.startswith("**Words**"):
        errors.append("explanation must start with **Words**")
    words_section, grammar_heading, _ = explanation.partition("**Grammar**")
    if not grammar_heading:
        errors.append("explanation is missing **Grammar**")
    bullets = [line for line in words_section.splitlines() if line.startswith("- ")]
    if not bullets:
        errors.append("word breakdown has no bullets")
    normalized_source = normalize(sentence.text)
    for line in bullets:
        match = _WORD_BULLET.fullmatch(line)
        if not match:
            errors.append(f"bad word bullet: {line}")
            continue
        surface, reading = match.groups()
        if _BAD_READING.search(reading):
            errors.append(f"reading is not kana-only: {reading}")
        normalized_surface = normalize(surface)
        if not normalized_surface:
            errors.append(f"word bullet is punctuation-only: {surface}")
        elif normalized_surface not in normalized_source:
            errors.append(f"surface form is not in the target: {surface}")
    return errors


def validate_entries(
    entries: dict[str, Any], expected_ids: list[str], sentence_by_id: dict[str, Sentence]
) -> dict[str, dict[str, str]]:
    """Validate one model response without accepting partial or misaddressed output."""
    if set(entries) != set(expected_ids) or len(entries) != len(expected_ids):
        missing = sorted(set(expected_ids) - set(entries))
        extra = sorted(set(entries) - set(expected_ids))
        raise BatchWorkflowError(f"wrong result IDs; missing={missing}, extra={extra}")

    result: dict[str, dict[str, str]] = {}
    failures: list[str] = []
    for sentence_id in expected_ids:
        value = entries.get(sentence_id)
        if not isinstance(value, dict):
            failures.append(f"{sentence_id}: result is not an object")
            continue
        if set(value) != {"translation", "explanation"}:
            failures.append(f"{sentence_id}: expected only translation and explanation")
            continue
        translation = value.get("translation")
        explanation = value.get("explanation")
        if not isinstance(translation, str) or not translation.strip():
            failures.append(f"{sentence_id}: empty translation")
            continue
        if not isinstance(explanation, str) or not explanation.strip():
            failures.append(f"{sentence_id}: empty explanation")
            continue
        for error in _validate_explanation(sentence_by_id[sentence_id], explanation.strip()):
            failures.append(f"{sentence_id}: {error}")
        result[sentence_id] = {
            "translation": translation.strip(),
            "explanation": explanation.strip(),
        }
    if failures:
        raise BatchWorkflowError("; ".join(failures[:20]))
    return result


def _payload_entries(payload: Any) -> dict[str, Any]:
    if not isinstance(payload, dict):
        raise BatchWorkflowError("model JSON is not an object")
    translations = payload.get("translations")
    if isinstance(translations, list):
        entries: dict[str, Any] = {}
        for item in translations:
            if not isinstance(item, dict) or not isinstance(item.get("id"), str):
                raise BatchWorkflowError("translations must contain objects with string IDs")
            sentence_id = item["id"]
            if sentence_id in entries:
                raise BatchWorkflowError(f"duplicate result ID: {sentence_id}")
            entries[sentence_id] = {
                "translation": item.get("translation"),
                "explanation": item.get("explanation"),
            }
        return entries
    # Tolerate the original canonical `{id: {...}}` shape if the model follows the prose example
    # more strongly than the response schema. The saved `done/` artifact is this shape either way.
    return payload


def _parse_model_json(text: str) -> Any:
    text = text.strip()
    if text.startswith("```"):
        lines = text.splitlines()
        if lines and lines[0].startswith("```"):
            lines = lines[1:]
        if lines and lines[-1].strip() == "```":
            lines = lines[:-1]
        text = "\n".join(lines).strip()
    try:
        return json.loads(text)
    except ValueError as exc:
        raise BatchWorkflowError(f"model returned malformed JSON: {exc}") from exc


def _done_entries(done_dir: Path, sentence_by_id: dict[str, Sentence]) -> dict[str, dict[str, str]]:
    merged: dict[str, dict[str, str]] = {}
    if not done_dir.exists():
        return merged
    for path in sorted(done_dir.glob("*.json")):
        document = _load_json(path)
        if not isinstance(document, dict):
            raise BatchWorkflowError(f"Stored result is not an object: {path}")
        expected = list(document)
        unknown = sorted(set(expected) - set(sentence_by_id))
        if unknown:
            raise BatchWorkflowError(f"Stored result has IDs from another EPUB: {path}: {unknown[:5]}")
        checked = validate_entries(document, expected, sentence_by_id)
        for sentence_id, value in checked.items():
            previous = merged.get(sentence_id)
            if previous is not None and previous != value:
                raise BatchWorkflowError(
                    f"Conflicting saved translations for {sentence_id}; inspect {done_dir}"
                )
            merged[sentence_id] = value
    return merged


def build_chunks(
    book: EpubBook,
    done_ids: set[str],
    target_count: int,
    targets_per_request: int,
    context_before: int,
    context_after: int,
) -> list[Chunk]:
    """Build small, chapter-local requests from the unfinished part of the selected prefix."""
    selected_ids = {sentence.id for sentence in book.sentences[:target_count]}
    chunks: list[Chunk] = []
    for chapter in book.chapters:
        sentences = chapter.sentences
        wanted_positions = [
            index
            for index, sentence in enumerate(sentences)
            if sentence.id in selected_ids and sentence.id not in done_ids
        ]
        runs: list[list[int]] = []
        for position in wanted_positions:
            if not runs or position != runs[-1][-1] + 1:
                runs.append([])
            runs[-1].append(position)
        for run in runs:
            for offset in range(0, len(run), targets_per_request):
                positions = run[offset : offset + targets_per_request]
                first, last = positions[0], positions[-1]
                targets = tuple(sentences[position] for position in positions)
                key = f"c{chapter.spine:03d}-s{targets[0].start}-n{len(targets)}"
                chunks.append(
                    Chunk(
                        key=key,
                        spine=chapter.spine,
                        heading=chapter.heading,
                        context_before=tuple(sentences[max(0, first - context_before) : first]),
                        targets=targets,
                        context_after=tuple(sentences[last + 1 : last + 1 + context_after]),
                    )
                )
    return chunks


def _sentence_lines(label: str, sentences: tuple[Sentence, ...]) -> list[str]:
    lines = [label]
    if not sentences:
        lines.append("(none)")
    else:
        lines.extend(f"[{sentence.id}] {sentence.text}" for sentence in sentences)
    return lines


def render_chunk_prompt(book: EpubBook, chunk: Chunk) -> str:
    sections = [
        f"BOOK: {book.title}",
        f"CHAPTER/SPINE: {chunk.spine}" + (f" — {chunk.heading}" if chunk.heading else ""),
        "",
        *_sentence_lines("CONTEXT BEFORE (reference only):", chunk.context_before),
        "",
        *_sentence_lines("TARGETS (translate every one, and only these):", chunk.targets),
        "",
        *_sentence_lines("CONTEXT AFTER (reference only):", chunk.context_after),
        "",
        "Return exactly these TARGET IDs in TARGET order: "
        + ", ".join(sentence.id for sentence in chunk.targets),
    ]
    return "\n".join(sections)


def _response_schema(target_count: int) -> dict[str, Any]:
    return {
        "type": "object",
        "properties": {
            "translations": {
                "type": "array",
                "minItems": target_count,
                "maxItems": target_count,
                "items": {
                    "type": "object",
                    "properties": {
                        "id": {"type": "string"},
                        "translation": {"type": "string"},
                        "explanation": {"type": "string"},
                    },
                    "required": ["id", "translation", "explanation"],
                },
            }
        },
        "required": ["translations"],
    }


def request_for_chunk(
    book: EpubBook, chunk: Chunk, prompt: str, thinking_level: str
) -> dict[str, Any]:
    return {
        "key": chunk.key,
        "request": {
            "systemInstruction": {"parts": [{"text": prompt}]},
            "contents": [
                {
                    "role": "user",
                    "parts": [{"text": render_chunk_prompt(book, chunk)}],
                }
            ],
            "generationConfig": {
                "responseMimeType": "application/json",
                "responseJsonSchema": _response_schema(len(chunk.targets)),
                "maxOutputTokens": MAX_OUTPUT_TOKENS,
                "thinkingConfig": {"thinkingLevel": thinking_level},
            },
        },
    }


def _ensure_book_state(
    work_dir: Path,
    epub_path: Path,
    book: EpubBook,
    model: str,
    prompt: str,
) -> dict[str, Any]:
    epub_path = epub_path.expanduser().resolve()
    state = {
        "version": 1,
        "syncId": book.sync_id,
        "title": book.title,
        "sourcePath": str(epub_path),
        "sourceSha256": _sha256_file(epub_path),
        "sourceSizeBytes": epub_path.stat().st_size,
        "spineCount": book.spine_count,
        "totalSentences": len(book.sentences),
        "model": model,
        "promptId": prompt_id(prompt),
        "promptSha256": _sha256_bytes(prompt.encode("utf-8")),
    }
    path = work_dir / "book.json"
    if path.exists():
        existing = _load_json(path)
        identity_keys = (
            "syncId",
            "sourceSha256",
            "spineCount",
            "totalSentences",
            "model",
            "promptSha256",
        )
        mismatches = [key for key in identity_keys if existing.get(key) != state.get(key)]
        if mismatches:
            raise BatchWorkflowError(
                f"{work_dir} belongs to a different source/model/prompt ({', '.join(mismatches)}). "
                "Choose a new --work-dir so completed work is never invalidated."
            )
        state = existing
    else:
        _atomic_json(path, state)
        _atomic_bytes(work_dir / "prompt.md", prompt.encode("utf-8") + b"\n")
    return state


def prepare_plan(args: argparse.Namespace) -> tuple[EpubBook, str, dict[str, Any], Path | None]:
    epub_path = args.epub.expanduser().resolve()
    work_dir = args.work_dir.expanduser().resolve()
    prompt = _load_prompt(args.prompt)
    book = _load_book(epub_path, args.sync_id)
    sentence_by_id = {sentence.id: sentence for sentence in book.sentences}
    done = _done_entries(work_dir / "done", sentence_by_id)

    target_count = min(len(book.sentences), max(1, math.ceil(len(book.sentences) * args.fraction)))
    target_ids = {sentence.id for sentence in book.sentences[:target_count]}
    completed_within_target = len(target_ids & set(done))
    chunks = build_chunks(
        book,
        set(done),
        target_count,
        args.targets_per_request,
        args.context_before,
        args.context_after,
    )
    state = _ensure_book_state(work_dir, epub_path, book, args.model, prompt)

    records = [request_for_chunk(book, chunk, prompt, args.thinking_level) for chunk in chunks]
    request_raw = b"".join(
        json.dumps(record, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n"
        for record in records
    )
    request_sha = _sha256_bytes(request_raw)
    request_path: Path | None = None
    if records:
        request_path = work_dir / "requests" / f"batch-{request_sha[:16]}.jsonl"
        if request_path.exists() and request_path.read_bytes() != request_raw:
            raise BatchWorkflowError(f"Refusing to overwrite changed request file: {request_path}")
        if not request_path.exists():
            _atomic_bytes(request_path, request_raw)

    plan = {
        "version": 1,
        "createdAt": _utc_now(),
        "syncId": args.sync_id,
        "title": book.title,
        "sourceSha256": state["sourceSha256"],
        "model": args.model,
        "promptId": state["promptId"],
        "fraction": args.fraction,
        "targetCount": target_count,
        "completedWithinTarget": completed_within_target,
        "pendingCount": sum(len(chunk.targets) for chunk in chunks),
        "targetsPerRequest": args.targets_per_request,
        "contextBefore": args.context_before,
        "contextAfter": args.context_after,
        "thinkingLevel": args.thinking_level,
        "requestSha256": request_sha,
        "requestFile": str(request_path) if request_path else None,
        "chunks": [chunk.index_json() for chunk in chunks],
    }
    plan_path = work_dir / "plans" / f"batch-{request_sha[:16]}.json"
    if not plan_path.exists():
        _atomic_json(plan_path, plan)
    else:
        # Preserve the original creation time while returning the durable plan.
        plan = _load_json(plan_path)

    print(
        f"{book.title}: {len(book.sentences)} total; trial selects {target_count} "
        f"({target_count / len(book.sentences):.2%}); {completed_within_target} already done; "
        f"{plan['pendingCount']} pending in {len(chunks)} Batch API request(s)."
    )
    if request_path:
        print(f"Prepared {request_path} ({request_path.stat().st_size / 1024:.1f} KB)")
    return book, prompt, plan, request_path


def _client():
    api_key = (os.environ.get("GEMINI_API_KEY") or os.environ.get("GOOGLE_API_KEY") or "").strip()
    if not api_key:
        raise BatchWorkflowError(
            "Set GEMINI_API_KEY in the environment. The key is intentionally not accepted as a "
            "command-line argument or stored on disk."
        )
    try:
        from google import genai
        from google.genai import types
    except ImportError as exc:
        raise BatchWorkflowError(
            "google-genai is not installed. Run: python -m pip install -r requirements.txt"
        ) from exc
    return genai.Client(api_key=api_key), types


def _jsonable(value: Any) -> Any:
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    if isinstance(value, dict):
        return {str(key): _jsonable(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_jsonable(item) for item in value]
    if hasattr(value, "model_dump"):
        return _jsonable(value.model_dump(exclude_none=True, mode="json"))
    return str(value)


def _state_name(job: Any) -> str:
    state = getattr(job, "state", None)
    name = getattr(state, "name", None)
    if name:
        return name
    value = str(state or "")
    return value.rsplit(".", 1)[-1]


def _job_path(work_dir: Path, request_sha: str) -> Path:
    return work_dir / "jobs" / f"batch-{request_sha[:16]}.json"


def _update_job_record(path: Path, record: dict[str, Any], job: Any) -> dict[str, Any]:
    record["state"] = _state_name(job)
    record["checkedAt"] = _utc_now()
    record["error"] = _jsonable(getattr(job, "error", None))
    stats = getattr(job, "batch_stats", None)
    if stats is not None:
        record["batchStats"] = _jsonable(stats)
    destination = getattr(job, "dest", None)
    result_file = getattr(destination, "file_name", None) if destination is not None else None
    if result_file:
        record["resultFileName"] = result_file
    _atomic_json(path, record)
    return record


def submit(args: argparse.Namespace) -> int:
    _book, _prompt, plan, request_path = prepare_plan(args)
    if not request_path or not plan["pendingCount"]:
        print("Nothing to submit for the selected fraction.")
        return 0
    work_dir = args.work_dir.expanduser().resolve()
    job_path = _job_path(work_dir, plan["requestSha256"])
    display_name = f"hoshi-{args.sync_id}-{plan['requestSha256'][:12]}"
    client, types = _client()

    record = _load_json(job_path) if job_path.exists() else {
        "version": 1,
        "createdAt": _utc_now(),
        "displayName": display_name,
        "model": args.model,
        "requestSha256": plan["requestSha256"],
        "requestFile": str(request_path),
        "planFile": str(args.work_dir.expanduser().resolve() / "plans" / job_path.name),
        "collected": False,
    }
    if record.get("batchJobName"):
        print(f"Already submitted as {record['batchJobName']}; not creating a duplicate job.")
        return 0

    uploaded_name = record.get("inputFileName")
    if not uploaded_name:
        uploaded = client.files.upload(
            file=request_path,
            config=types.UploadFileConfig(display_name=display_name, mime_type="jsonl"),
        )
        uploaded_name = uploaded.name
        record["inputFileName"] = uploaded_name
        record["phase"] = "uploaded"
        _atomic_json(job_path, record)

    # Batch creation is not idempotent. Recover a matching remote job before creating one so a
    # crash after the API accepted it cannot double the bill on the next invocation.
    matching = [
        job for job in client.batches.list(config={"page_size": 100})
        if getattr(job, "display_name", None) == display_name
    ]
    if matching:
        job = matching[0]
        print(f"Recovered existing remote job {job.name}.")
    else:
        job = client.batches.create(
            model=args.model,
            src=uploaded_name,
            config={"display_name": display_name},
        )
        print(f"Submitted {job.name}.")
    record["batchJobName"] = job.name
    record["phase"] = "submitted"
    _update_job_record(job_path, record, job)
    print("Run the status command later, or wait to poll and collect automatically.")
    return 0


def _latest_job(work_dir: Path) -> tuple[Path, dict[str, Any]]:
    paths = sorted((work_dir / "jobs").glob("batch-*.json"), key=lambda path: path.stat().st_mtime)
    if not paths:
        raise BatchWorkflowError(f"No submitted Batch API job exists under {work_dir}")
    # Prefer the newest uncollected job; otherwise report the newest historical one.
    for path in reversed(paths):
        record = _load_json(path)
        if not record.get("collected"):
            return path, record
    path = paths[-1]
    return path, _load_json(path)


def check_status(args: argparse.Namespace) -> tuple[Path, dict[str, Any], Any]:
    work_dir = args.work_dir.expanduser().resolve()
    path, record = _latest_job(work_dir)
    name = record.get("batchJobName")
    if not name:
        raise BatchWorkflowError(f"Submission was not completed; rerun submit: {path}")
    client, _types = _client()
    job = client.batches.get(name=name)
    record = _update_job_record(path, record, job)
    print(f"{name}: {record['state']}")
    if record.get("batchStats"):
        print(json.dumps(record["batchStats"], ensure_ascii=False, separators=(",", ":")))
    return path, record, job


def _response_text(response: dict[str, Any]) -> str:
    candidates = response.get("candidates") or []
    if not candidates:
        raise BatchWorkflowError("response has no candidates")
    parts = ((candidates[0].get("content") or {}).get("parts") or [])
    text = "".join(part.get("text") or "" for part in parts if isinstance(part, dict))
    if not text.strip():
        raise BatchWorkflowError("response candidate has no text")
    return text


def _usage(response: dict[str, Any]) -> dict[str, int]:
    source = response.get("usageMetadata") or response.get("usage_metadata") or {}
    fields = {
        "promptTokens": ("promptTokenCount", "prompt_token_count"),
        "outputTokens": ("candidatesTokenCount", "candidates_token_count"),
        "thinkingTokens": ("thoughtsTokenCount", "thoughts_token_count"),
        "totalTokens": ("totalTokenCount", "total_token_count"),
    }
    result: dict[str, int] = {}
    for destination, alternatives in fields.items():
        result[destination] = int(next((source.get(key) for key in alternatives if source.get(key) is not None), 0))
    return result


def process_result_bytes(
    raw: bytes,
    plan: dict[str, Any],
    book: EpubBook,
    done_dir: Path,
) -> tuple[int, list[str], dict[str, int]]:
    """Persist every independently valid response; failed chunks remain eligible for retry."""
    by_key: dict[str, dict[str, Any]] = {}
    failures: list[str] = []
    for line_number, line in enumerate(raw.decode("utf-8").splitlines(), start=1):
        if not line.strip():
            continue
        try:
            document = json.loads(line)
        except ValueError as exc:
            failures.append(f"line {line_number}: malformed response JSONL ({exc})")
            continue
        key = document.get("key") or (document.get("metadata") or {}).get("key")
        if not isinstance(key, str):
            failures.append(f"line {line_number}: response has no request key")
            continue
        if key in by_key:
            failures.append(f"duplicate response key: {key}")
            continue
        by_key[key] = document

    sentence_by_id = {sentence.id: sentence for sentence in book.sentences}
    saved = 0
    usage = {"promptTokens": 0, "outputTokens": 0, "thinkingTokens": 0, "totalTokens": 0}
    for chunk in plan.get("chunks") or []:
        key = chunk["key"]
        expected_ids = chunk["targetIds"]
        document = by_key.get(key)
        if not document:
            failures.append(f"{key}: missing response")
            continue
        if document.get("error"):
            failures.append(f"{key}: API error {_jsonable(document['error'])}")
            continue
        response = document.get("response")
        if not isinstance(response, dict):
            failures.append(f"{key}: response object is missing")
            continue
        for field, value in _usage(response).items():
            usage[field] += value
        try:
            payload = _parse_model_json(_response_text(response))
            entries = validate_entries(_payload_entries(payload), expected_ids, sentence_by_id)
        except BatchWorkflowError as exc:
            failures.append(f"{key}: {exc}")
            continue
        _atomic_json(done_dir / f"{key}.json", entries)
        saved += len(entries)
    return saved, failures, usage


def collect(args: argparse.Namespace, checked: tuple[Path, dict[str, Any], Any] | None = None) -> int:
    job_path, record, job = checked or check_status(args)
    if record["state"] != "JOB_STATE_SUCCEEDED":
        if record["state"] in TERMINAL_STATES:
            raise BatchWorkflowError(
                f"Batch ended as {record['state']}: {record.get('error') or 'no detail'}"
            )
        print("Batch is not finished yet; nothing was collected.")
        return 3

    result_file = record.get("resultFileName")
    if not result_file:
        raise BatchWorkflowError("Succeeded Batch job has no result file.")
    client, _types = _client()
    raw = client.files.download(file=result_file)
    work_dir = args.work_dir.expanduser().resolve()
    raw_path = work_dir / "raw" / f"batch-{record['requestSha256'][:16]}.jsonl"
    _atomic_bytes(raw_path, raw)

    plan = _load_json(Path(record["planFile"]))
    state = _load_json(work_dir / "book.json")
    epub_path = Path(state["sourcePath"])
    if _sha256_file(epub_path) != state["sourceSha256"]:
        raise BatchWorkflowError("Source EPUB changed since submission; raw results were saved but not merged.")
    book = _load_book(epub_path, state["syncId"])
    prompt = _load_prompt(work_dir / "prompt.md")
    saved, failures, usage = process_result_bytes(raw, plan, book, work_dir / "done")

    blob = epub_pipeline.import_translations(
        book,
        work_dir / "done",
        work_dir / "checkpoint",
        model=record["model"],
        prompt=prompt,
    )
    record["collected"] = True
    record["collectedAt"] = _utc_now()
    record["savedSentences"] = saved
    record["failedChunks"] = failures
    record["usage"] = usage
    _atomic_json(job_path, record)

    print(f"Saved raw results to {raw_path}")
    print(f"Accepted {saved} sentence(s); local checkpoint now has {len(blob.entries)}/{len(book.sentences)}.")
    print(
        "Usage: "
        f"input={usage['promptTokens']}, output={usage['outputTokens']}, "
        f"thinking={usage['thinkingTokens']}, total={usage['totalTokens']} tokens."
    )
    if failures:
        print(f"{len(failures)} chunk(s)/response(s) need retry:")
        for failure in failures[:20]:
            print(f"  {failure}")
        return 1
    return 0


def wait_and_collect(args: argparse.Namespace) -> int:
    while True:
        checked = check_status(args)
        state = checked[1]["state"]
        if state in TERMINAL_STATES:
            return collect(args, checked=checked)
        print(f"Waiting {args.poll_seconds} seconds...")
        time.sleep(args.poll_seconds)


def _fraction(value: str) -> float:
    parsed = float(value)
    if not 0 < parsed <= 1:
        raise argparse.ArgumentTypeError("fraction must be greater than 0 and at most 1")
    return parsed


def _positive_int(value: str) -> int:
    parsed = int(value)
    if parsed < 1:
        raise argparse.ArgumentTypeError("value must be at least 1")
    return parsed


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Prepare, submit, monitor, and collect a resumable Gemini EPUB Batch job."
    )
    parser.add_argument("command", choices=("prepare", "submit", "status", "collect", "wait", "run"))
    parser.add_argument("--epub", type=Path, default=DEFAULT_EPUB)
    parser.add_argument("--work-dir", type=Path, default=DEFAULT_WORK_DIR)
    parser.add_argument("--prompt", type=Path, default=DEFAULT_PROMPT)
    parser.add_argument("--sync-id", default=SYNC_ID)
    parser.add_argument("--model", default=MODEL)
    parser.add_argument("--fraction", type=_fraction, default=TRIAL_FRACTION)
    parser.add_argument("--targets-per-request", type=_positive_int, default=TARGETS_PER_REQUEST)
    parser.add_argument("--context-before", type=int, choices=range(0, 21), default=CONTEXT_BEFORE)
    parser.add_argument("--context-after", type=int, choices=range(0, 11), default=CONTEXT_AFTER)
    parser.add_argument(
        "--thinking-level",
        choices=("minimal", "low", "medium", "high"),
        default=THINKING_LEVEL,
    )
    parser.add_argument("--poll-seconds", type=_positive_int, default=60)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.command == "prepare":
            prepare_plan(args)
            return 0
        if args.command == "submit":
            return submit(args)
        if args.command == "status":
            check_status(args)
            return 0
        if args.command == "collect":
            return collect(args)
        if args.command == "wait":
            return wait_and_collect(args)
        if args.command == "run":
            result = submit(args)
            return result if result else wait_and_collect(args)
    except BatchWorkflowError as exc:
        print(f"Error: {exc}")
        return 2
    return 2
