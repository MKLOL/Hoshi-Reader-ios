#!/usr/bin/env python3
"""Prepare → agent fills translations.json → build → dry run / publish."""

import argparse
import json
from pathlib import Path
import sys

from artifacts import build, prepare, sha, validated_uploads
from publisher import credentials, KvClient, publish


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    preparation = commands.add_parser("prepare", help="Create the EPUB, sentence plan and translation template")
    preparation.add_argument("--article", required=True, type=Path)
    preparation.add_argument("--out", required=True, type=Path, help="New job directory; existing directories are never overwritten")
    building = commands.add_parser("build", help="Validate all translations and produce the upload bundle and readable preview")
    building.add_argument("--job", required=True, type=Path)
    publication = commands.add_parser("publish", help="Validate and show uploads; no network unless --upload is specified")
    publication.add_argument("--job", required=True, type=Path)
    mode = publication.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true", help="Validate locally without reading credentials or using the network (default)")
    mode.add_argument("--upload", action="store_true", help="Upload this article to the configured Hoshi server")
    publication.add_argument("--env-file", type=Path, help="Optional local secrets file; environment variables take precedence")
    publication.add_argument("--replace-translations", action="store_true", help="Replace existing translations only when the EPUB content matches")
    args = parser.parse_args(argv)
    try:
        if args.command == "prepare":
            plan = prepare(args.article, args.out)
            result = dict(status="prepared", syncId=plan["syncId"], sentences=len(plan["sentences"]),
                          job=str(args.out), next="Read prompt.md, then complete translations.json")
        elif args.command == "build":
            plan = build(args.job)
            result = dict(status="built", syncId=plan["syncId"], sentences=len(plan["sentences"]),
                          preview=str(args.job / "preview.md"), epub=str(args.job / "article.epub"))
        else:
            plan, uploads = validated_uploads(args.job)
            result = dict(status="dry-run", syncId=plan["syncId"], title=plan["title"],
                          sentences=len(plan["sentences"]), requests=[
                              dict(method="PUT", key=key, contentType=mime, bytes=len(body), sha256=sha(body))
                              for key, mime, body in uploads
                          ])
            if args.upload:
                base_url, token = credentials(args.env_file)
                result.update(publish(KvClient(base_url, token), uploads, args.replace_translations))
                result["status"] = "published"
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except (ValueError, OSError, KeyError, TypeError) as error:
        # Network code produces redacted diagnostics; no server body or credentials are printed.
        print(f"Error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
