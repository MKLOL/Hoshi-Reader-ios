"""Headless entry point, for running the whole library overnight from a terminal."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from . import config as configmod
from . import models as modelsmod
from . import pipeline
from .kv import KvClient, KvError


def export_bubbles(client, target: Path, only: list[str] | None, out_dir: Path) -> int:
    """Dumps untranslated bubbles, grouped by page with the previous page as context.

    The seam that lets ANY translator do the work — including a human or an assistant — and hand
    the result back. Already-finished bubbles are skipped, so this composes with a partial run.
    """
    import json

    from . import pipeline

    books = pipeline.discover_manga(client)
    if only:
        wanted = list(dict.fromkeys(only))
        by_id = {b.sync_id: b for b in books}
        books = [by_id[s] for s in wanted if s in by_id]

    payload = []
    for book in books:
        volume = pipeline.load_volume(client, book)
        if volume is None or not volume.bubbles:
            continue
        saved = pipeline.load_saved(out_dir, volume.sync_id) or {}
        done = set((saved.get("entries") or {}).keys())
        pages = sorted(pipeline.bubbles_by_page(volume).items())
        page_entries = []
        for index, (_page_index, bubbles) in enumerate(pages):
            todo = [b for b in bubbles if b.block_id not in done]
            if not todo:
                continue
            previous = pages[index - 1][1] if index >= 1 else []
            page_entries.append({
                "context_previous_page": [
                    {"id": b.block_id, "jp": b.text} for b in previous
                ],
                "context_this_page": [{"id": b.block_id, "jp": b.text} for b in bubbles],
                "translate": [{"id": b.block_id, "jp": b.text} for b in todo],
            })
        if page_entries:
            payload.append({
                "syncId": volume.sync_id,
                "title": volume.title,
                "remaining": sum(len(p["translate"]) for p in page_entries),
                "pages": page_entries,
            })

    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(payload, ensure_ascii=False, indent=1), encoding="utf-8")
    total = sum(b["remaining"] for b in payload)
    print(f"Wrote {total} untranslated bubbles across {len(payload)} book(s) to {target}")
    return 0


def import_translations(
    client, source: Path, out_dir: Path, upload: bool, prompt_override: str | None
) -> int:
    """Merges `{syncId: {blockId: {translation, explanation}}}` back into the checkpoints."""
    import json

    from . import pipeline
    from .blob import Entry, PretranslationsBlob

    doc = json.loads(source.read_text(encoding="utf-8"))
    user_prompt = pipeline.fetch_user_prompt(client, override=prompt_override)
    books = {b.sync_id: b for b in pipeline.discover_manga(client)}

    for sync_id, entries in doc.items():
        book = books.get(sync_id)
        if book is None:
            print(f"  skipping unknown book {sync_id}")
            continue
        volume = pipeline.load_volume(client, book)
        if volume is None:
            continue
        # Index by address so the imported text is the OCR text, not whatever came back — the
        # readers verify the bubble hash against it.
        by_id = {b.block_id: b for b in volume.bubbles}

        saved = pipeline.load_saved(out_dir, sync_id) or {}
        result = PretranslationsBlob(
            sync_id=sync_id, title=volume.title,
            model=saved.get("model") or "claude", prompt=user_prompt,
            prompt_id_override=saved.get("promptId"),
        )
        for key, value in (saved.get("entries") or {}).items():
            result.entries[key] = Entry(
                text=value.get("text", ""), translation=value.get("translation", ""),
                explanation=value.get("explanation", ""),
            )
        added = 0
        for block_id, value in entries.items():
            bubble = by_id.get(block_id)
            if bubble is None:
                continue
            result.add(block_id, Entry(
                text=bubble.text,
                translation=str(value.get("translation", "")).strip(),
                explanation=str(value.get("explanation", "")).strip(),
            ))
            added += 1

        out_dir.mkdir(parents=True, exist_ok=True)
        (out_dir / f"{sync_id}.json").write_text(
            json.dumps(result.to_json(), ensure_ascii=False, indent=1), encoding="utf-8"
        )
        print(f"  {volume.title}: +{added} -> {len(result.entries)} total")
        if upload:
            pipeline.upload_volume(client, result)
    return 0


def _epub_client(args, required: bool):
    """A KV client whenever a token exists — not only when the step strictly needs the server.

    Building one opportunistically matters for the PROMPT: without a client `fetch_user_prompt`
    falls back to the built-in default, and its hash is what lands in the checkpoint's `promptId`.
    A local `--epub … --no-upload` merge would therefore stamp the blob with the hash of a prompt
    the user never used, breaking the invalidation contract before the book was even uploaded.
    """
    if not args.token:
        if required:
            print("No sync token. Pass --token or set one in the GUI.", file=sys.stderr)
        return None
    try:
        return KvClient(args.url, args.token)
    except KvError as exc:
        print(str(exc), file=sys.stderr)
        return None


def run_epub(args) -> int:
    """The novel path: extract -> export -> (translate elsewhere) -> import -> verify -> upload.

    Kept separate from the manga path rather than folded into it: the units, the addressing and the
    context window are all different, and `pipeline.run`'s per-page loop does not apply. The
    server, the checkpoint format, the prompt source and the resume rules ARE shared.
    """
    from . import epub_pipeline as ep
    from .epub_blob import SentencesBlob

    out_dir = Path(args.out)
    local_path = Path(args.epub) if args.epub else None

    if args.list_epubs:
        client = _epub_client(args, required=True)
        if client is None:
            return 2
        for book in ep.discover_epubs(client):
            print(f"{book.sync_id}\t{book.title}")
        return 0

    sync_id = (args.books or [None])[0]
    if not sync_id:
        print("Which book? Pass --book {syncId} (see --list-epubs).", file=sys.stderr)
        return 2

    # A local .epub needs no server for the book itself; a client is still built when a token is
    # available so the prompt comes from the app rather than the fallback.
    needs_server = local_path is None or args.upload_only or (
        args.import_translations and not args.no_upload
    )
    client = _epub_client(args, required=needs_server)
    if needs_server and client is None:
        return 2

    book = ep.load_book(sync_id, client=client, local_path=local_path, fallback_title=sync_id)
    if book is None:
        return 2

    problems = ep.verify(book)
    if problems:
        # Addressing is the one thing that must be perfect: a wrong offset puts a button on the
        # wrong sentence. Refuse to go further rather than translate against a broken map.
        print(f"{len(problems)} addressing problem(s) in {book.title}:", file=sys.stderr)
        for problem in problems[:10]:
            print(f"  {problem}", file=sys.stderr)
        return 1

    print(f"{book.title}  —  {len(book.sentences)} sentences, "
          f"{sum(c.char_count for c in book.chapters)} chars, {book.spine_count} spine items")
    if not book.sentences:
        # Never proceed from here: an empty book verifies clean (no sentences, no problems) and
        # would PUT `{"entries":{}}` over a good blob on the server.
        print("No sentences were extracted — refusing to continue.", file=sys.stderr)
        return 1

    if args.extract_only:
        for chapter in book.chapters:
            if chapter.sentences:
                print(f"  c{chapter.spine:<3} {len(chapter.sentences):>4} sentences  "
                      f"{chapter.char_count:>6} chars  {chapter.heading[:40]}")
        return 0

    prompt = ep.fetch_user_prompt(client, override=args.prompt)
    model = args.model_name

    if args.export_sentences:
        ep.export_sentences(book, out_dir, Path(args.export_sentences))
        return 0

    if args.import_translations:
        try:
            blob = ep.import_translations(
                book, Path(args.import_translations), out_dir, model=model, prompt=prompt,
                allow_reset=args.new_run,
            )
        except ep.CheckpointMismatch as exc:
            print(str(exc), file=sys.stderr)
            return 2
    else:
        saved = ep.load_saved(out_dir, sync_id)
        if not saved:
            print("Nothing translated yet — start with --export-sentences.", file=sys.stderr)
            return 2
        blob = SentencesBlob.from_json(saved)
        if saved.get("promptId") != ep.prompt_id(prompt) or saved.get("model") != model:
            print(f"  note: this checkpoint was made with model {saved.get('model')!r} / prompt "
                  f"{saved.get('promptId')!r}; uploading it as-is.")

    problems = ep.verify_checkpoint(book, blob)
    if args.verify or problems:
        if problems:
            print(f"{len(problems)} problem(s):")
            for problem in problems[:20]:
                print(f"  {problem}")
        else:
            print("Verified: every sentence resolves, hashes match, nothing empty.")
        if args.verify:
            return 1 if problems else 0

    if problems:
        print("Not uploading an incomplete or inconsistent book.", file=sys.stderr)
        return 1
    if args.no_upload:
        print(f"Checkpoint written to {ep.state_path(out_dir, sync_id)} (not uploaded).")
        return 0
    if client is None:
        client = _epub_client(args, required=True)
        if client is None:
            return 2
    ep.upload_book(client, blob)
    return 0


def main(argv: list[str] | None = None) -> int:
    config = configmod.load()
    parser = argparse.ArgumentParser(prog="hoshi-pretranslate", description=__doc__)
    parser.add_argument("--url", default=config.base_url, help="sync server mount point")
    parser.add_argument("--token", default=config.token, help="sync bearer token")
    parser.add_argument("--model", default=config.model_id, help="catalog model id")
    parser.add_argument("--models-dir", default=config.models_dir)
    parser.add_argument("--out", default=config.output_dir, help="where per-book results are written")
    parser.add_argument("--ctx", type=int, default=config.n_ctx, help="context window")
    parser.add_argument(
        "--mode",
        default=config.mode,
        choices=["focused", "page"],
        help="focused: one request per bubble with page + previous page as context (best). "
        "page: one request per page (faster).",
    )
    parser.add_argument("--book", action="append", dest="books", help="only this syncId (repeatable)")
    parser.add_argument("--no-upload", action="store_true", help="translate but do not push to the server")
    parser.add_argument("--prompt", default=config.prompt_override or None,
                        help="prompt to translate with (default: the one synced from the app)")
    parser.add_argument("--prompt-file", help="read the prompt from a file")
    parser.add_argument("--engine", default=config.engine, choices=["local", "cloud"],
                        help="local GPU (llama.cpp) or a hosted API")
    parser.add_argument("--cloud-provider", default=config.cloud_provider)
    parser.add_argument("--cloud-model", default=config.cloud_model)
    parser.add_argument("--cloud-key", default=config.cloud_key)
    parser.add_argument("--concurrency", type=int, default=config.cloud_concurrency)
    parser.add_argument("--list", action="store_true", help="list manga on the server and exit")
    parser.add_argument("--export-bubbles", metavar="FILE",
                        help="write every UNTRANSLATED bubble (with page context) to FILE and exit; "
                             "translate it with anything, then feed it back with --import-translations")
    parser.add_argument("--import-translations", metavar="FILE",
                        help="merge a translated export back in, then upload one blob per book")
    parser.add_argument("--download-model", action="store_true", help="fetch the model and exit")
    parser.add_argument("--list-models", action="store_true", help="show the model catalog and exit")

    # ---- Novels (EPUB). See tools/pretranslate/EPUB.md ----
    epub_group = parser.add_argument_group("novels (EPUB)")
    epub_group.add_argument("--novel", action="store_true",
                            help="EPUB mode: the unit is a sentence in a chapter, not a bubble")
    epub_group.add_argument("--epub", metavar="FILE",
                            help="read the book from this local .epub instead of the server "
                                 "(implies --novel)")
    epub_group.add_argument("--list-epubs", action="store_true",
                            help="list EPUBs on the server and exit (implies --novel)")
    epub_group.add_argument("--extract-only", action="store_true",
                            help="parse and report sentences per chapter; write nothing")
    epub_group.add_argument("--export-sentences", metavar="DIR",
                            help="write untranslated sentences, one file per chapter, to DIR")
    epub_group.add_argument("--verify", action="store_true",
                            help="check the checkpoint against the book and exit")
    epub_group.add_argument("--upload-only", action="store_true",
                            help="upload the existing checkpoint without translating")
    epub_group.add_argument("--new-run", action="store_true",
                            help="discard a checkpoint made with a different model/prompt instead "
                                 "of refusing (EPUB mode)")
    epub_group.add_argument("--model-name", default="codex",
                            help="what produced the translations, recorded in the blob and shown "
                                 "in the popup (EPUB mode)")
    args = parser.parse_args(argv)

    # Resolve --prompt-file BEFORE dispatching: novel mode reads `args.prompt`, and the old
    # ordering left it unread there, silently keying the run to the wrong prompt.
    if args.prompt_file:
        args.prompt = Path(args.prompt_file).read_text(encoding="utf-8")

    if args.novel or args.epub or args.list_epubs:
        return run_epub(args)

    if args.list_models:
        for model in modelsmod.CATALOG:
            print(f"{model.id:26s} {model.label()}")
            print(f"{'':26s} {model.note}")
        return 0

    model = modelsmod.by_id(args.model)
    if model is None:
        print(f"Unknown model id {args.model!r}. Use --list-models.", file=sys.stderr)
        return 2

    if args.download_model:
        modelsmod.download(model, Path(args.models_dir))
        return 0

    if not args.token:
        print("No sync token. Pass --token or set one in the GUI.", file=sys.stderr)
        return 2

    try:
        client = KvClient(args.url, args.token)
    except KvError as exc:
        print(str(exc), file=sys.stderr)
        return 2

    prompt_override = args.prompt  # --prompt-file already folded in above

    if args.list:
        for book in pipeline.discover_manga(client):
            print(f"{book.sync_id}\t{book.title}")
        return 0

    if args.export_bubbles:
        return export_bubbles(client, Path(args.export_bubbles), args.books, Path(args.out))
    if args.import_translations:
        return import_translations(
            client, Path(args.import_translations), Path(args.out),
            upload=not args.no_upload, prompt_override=prompt_override,
        )

    models_dir = Path(args.models_dir)
    if not modelsmod.is_downloaded(model, models_dir):
        print(f"{model.display_name} is not downloaded. Fetching it now ...")
        modelsmod.download(model, models_dir)

    from .llm import LocalTranslator
    from .runtime import LlamaServer, install, is_installed

    # app_dir(), not models_dir.parent: a custom --models-dir would otherwise look for the
    # runtime next to the models and re-download 535 MB into an unrelated directory.
    runtime_base = configmod.app_dir()
    if not is_installed(runtime_base):
        install(runtime_base)

    with LlamaServer(
        runtime_base, modelsmod.local_path(model, models_dir), n_ctx=args.ctx
    ) as server:
        translator = LocalTranslator(server.base_url, mode=args.mode)
        try:
            pipeline.run(
                client,
                translator,
                model_id=model.id,
                out_dir=Path(args.out),
                only_sync_ids=args.books,
                upload=not args.no_upload,
            )
        finally:
            translator.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
