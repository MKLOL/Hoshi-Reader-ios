#!/usr/bin/env python3
"""Hoshi sync test server — a faithful, dependency-free implementation of the KV API.

Implements every route the Android and iOS clients use, exactly as documented in
`docs/HTTP_SYNC_KV.md`, so integration tests on both platforms drive the REAL sync engines
and the REAL HTTP clients against a REAL server instead of an in-memory fake:

    PUT    /v1/kv/{key}                       upsert opaque bytes (Content-Type preserved)
    GET    /v1/kv/{key}                       bytes + Content-Type / Last-Modified / ETag
    DELETE /v1/kv/{key}                       204 (404 when absent — a no-op for clients)
    GET    /v1/kv?prefix&since&cursor&limit   key metadata, lastModified > since, key > cursor
    POST   /v1/kv-multipart/start             {key, contentType} -> {uploadId}
    PUT    /v1/kv-multipart/{uploadId}/{n}    one raw part, 1-based
    POST   /v1/kv-multipart/{uploadId}/complete   {parts:[...]} -> concatenated upsert
    DELETE /v1/kv-multipart/{uploadId}        cancel

Server-side stamps match production: `etag` is `sha256:<hex>` of the stored body, and
`lastModified` is RFC 3339 UTC with millisecond precision and a trailing `Z`. Stamps are
strictly monotonic across writes so `since` filtering is deterministic in tests.

Test-only routes (never part of the production API) let a test observe or shape state from
outside the client under test:

    GET    /_test/health                       {"ok": true}
    POST   /_test/reset                        drop every key, upload and the request log
    GET    /_test/dump                         JSON snapshot of every key (bodies base64)
    POST   /_test/load                         replace the store with a snapshot
    GET    /_test/requests                     the request log since the last clear
    POST   /_test/requests/clear               clear the request log

Run:  sync_test_server.py --port 0 --token secret [--state snapshot.json]
Prints `SYNC_TEST_SERVER_READY port=<n>` on stdout once it is listening.
"""

from __future__ import annotations

import argparse
import base64
import datetime as _dt
import hashlib
import json
import os
import re
import signal
import sys
import threading
import uuid
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlsplit

KEY_SEGMENT = r"[A-Za-z0-9_\-.]{1,64}"
KEY_RE = re.compile(rf"^{KEY_SEGMENT}(/{KEY_SEGMENT})*$")
MAX_KEY_BYTES = 512
DEFAULT_MAX_BODY = 200 * 1024 * 1024
DEFAULT_LIST_LIMIT = 500
MAX_LIST_LIMIT = 2000
JSON_CONTENT_TYPE = "application/json; charset=utf-8"


def sha256_etag(body: bytes) -> str:
    return "sha256:" + hashlib.sha256(body).hexdigest()


class Store:
    """Thread-safe in-memory KV store with monotonic RFC 3339 stamps."""

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.entries: dict[str, dict] = {}
        self.uploads: dict[str, dict] = {}
        self.requests: list[dict] = []
        self._last_stamp = ""

    # -- stamps -------------------------------------------------------------------------

    def _next_stamp(self) -> str:
        now = _dt.datetime.now(_dt.timezone.utc)
        stamp = now.strftime("%Y-%m-%dT%H:%M:%S.") + f"{now.microsecond // 1000:03d}Z"
        if stamp <= self._last_stamp:
            previous = _dt.datetime.strptime(self._last_stamp, "%Y-%m-%dT%H:%M:%S.%fZ")
            bumped = previous + _dt.timedelta(milliseconds=1)
            stamp = bumped.strftime("%Y-%m-%dT%H:%M:%S.") + f"{bumped.microsecond // 1000:03d}Z"
        self._last_stamp = stamp
        return stamp

    # -- kv ------------------------------------------------------------------------------

    def put(self, key: str, body: bytes, content_type: str) -> dict:
        with self.lock:
            entry = {
                "key": key,
                "body": body,
                "contentType": content_type,
                "lastModified": self._next_stamp(),
                "etag": sha256_etag(body),
                "size": len(body),
            }
            self.entries[key] = entry
            return self._meta(entry)

    def get(self, key: str) -> dict | None:
        with self.lock:
            return self.entries.get(key)

    def delete(self, key: str) -> bool:
        with self.lock:
            return self.entries.pop(key, None) is not None

    def list(self, prefix: str, since: str | None, cursor: str | None, limit: int) -> dict:
        with self.lock:
            keys = sorted(k for k in self.entries if k.startswith(prefix))
            rows = []
            for key in keys:
                entry = self.entries[key]
                if since and not entry["lastModified"] > since:
                    continue
                if cursor and not key > cursor:
                    continue
                rows.append(self._meta(entry))
                if len(rows) > limit:
                    break
            truncated = len(rows) > limit
            rows = rows[:limit]
            return {
                "keys": rows,
                "truncated": truncated,
                "nextCursor": rows[-1]["key"] if truncated and rows else None,
            }

    @staticmethod
    def _meta(entry: dict) -> dict:
        return {
            "key": entry["key"],
            "lastModified": entry["lastModified"],
            "etag": entry["etag"],
            "size": entry["size"],
            "contentType": entry["contentType"],
        }

    # -- multipart -----------------------------------------------------------------------

    def start_upload(self, key: str, content_type: str) -> str:
        with self.lock:
            upload_id = uuid.uuid4().hex
            self.uploads[upload_id] = {"key": key, "contentType": content_type, "parts": {}}
            return upload_id

    def put_part(self, upload_id: str, part_number: int, body: bytes) -> dict | None:
        with self.lock:
            upload = self.uploads.get(upload_id)
            if upload is None:
                return None
            upload["parts"][part_number] = body
            return {
                "uploadId": upload_id,
                "partNumber": part_number,
                "size": len(body),
                "etag": sha256_etag(body),
            }

    def complete_upload(self, upload_id: str, parts: list[int]) -> tuple[str | None, dict | None]:
        with self.lock:
            upload = self.uploads.get(upload_id)
            if upload is None:
                return "unknown upload", None
            missing = [n for n in parts if n not in upload["parts"]]
            if missing:
                return f"missing parts {missing}", None
            body = b"".join(upload["parts"][n] for n in parts)
            del self.uploads[upload_id]
        return None, self.put(upload["key"], body, upload["contentType"])

    def cancel_upload(self, upload_id: str) -> bool:
        with self.lock:
            return self.uploads.pop(upload_id, None) is not None

    # -- test hooks ----------------------------------------------------------------------

    def reset(self) -> None:
        with self.lock:
            self.entries.clear()
            self.uploads.clear()
            self.requests.clear()

    def dump(self) -> dict:
        with self.lock:
            return {
                "version": 1,
                "entries": [
                    {
                        "key": e["key"],
                        "contentType": e["contentType"],
                        "lastModified": e["lastModified"],
                        "etag": e["etag"],
                        "size": e["size"],
                        "body": base64.b64encode(e["body"]).decode("ascii"),
                    }
                    for e in sorted(self.entries.values(), key=lambda e: e["key"])
                ],
            }

    def load(self, snapshot: dict) -> int:
        with self.lock:
            self.entries.clear()
            self.uploads.clear()
            for raw in snapshot.get("entries", []):
                body = base64.b64decode(raw["body"])
                stamp = raw.get("lastModified") or self._next_stamp()
                if stamp > self._last_stamp:
                    self._last_stamp = stamp
                self.entries[raw["key"]] = {
                    "key": raw["key"],
                    "body": body,
                    "contentType": raw.get("contentType", "application/octet-stream"),
                    "lastModified": stamp,
                    "etag": sha256_etag(body),
                    "size": len(body),
                }
            return len(self.entries)

    def record(self, method: str, path: str, status: int, size: int) -> None:
        with self.lock:
            self.requests.append({"method": method, "path": path, "status": status, "size": size})

    def request_log(self) -> list[dict]:
        with self.lock:
            return list(self.requests)

    def clear_requests(self) -> None:
        with self.lock:
            self.requests.clear()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "HoshiSyncTestServer/1.0"
    store: Store
    token: str
    max_body: int

    # -- plumbing --------------------------------------------------------------------------

    def log_message(self, format: str, *args) -> None:  # noqa: A002 - BaseHTTPRequestHandler API
        if os.environ.get("SYNC_TEST_SERVER_VERBOSE"):
            sys.stderr.write("%s - %s\n" % (self.address_string(), format % args))

    def _send(self, status: int, body: bytes = b"", content_type: str = JSON_CONTENT_TYPE,
              headers: dict | None = None) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        if body and self.command != "HEAD":
            self.wfile.write(body)
        if not self.path.startswith("/_test/"):
            self.store.record(self.command, self.path, status, len(body))

    def _send_json(self, status: int, payload: dict) -> None:
        self._send(status, json.dumps(payload).encode("utf-8"))

    def _error(self, status: int, message: str) -> None:
        self._send_json(status, {"error": message})

    def _read_body(self) -> bytes | None:
        length_header = self.headers.get("Content-Length")
        if length_header is None:
            self._error(HTTPStatus.LENGTH_REQUIRED, "Content-Length is required")
            return None
        try:
            length = int(length_header)
        except ValueError:
            self._error(HTTPStatus.BAD_REQUEST, "invalid Content-Length")
            return None
        if length > self.max_body:
            self._error(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, f"body exceeds {self.max_body} bytes")
            return None
        return self.rfile.read(length)

    def _read_json(self) -> dict | None:
        body = self._read_body()
        if body is None:
            return None
        try:
            parsed = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self._error(HTTPStatus.BAD_REQUEST, "malformed JSON body")
            return None
        if not isinstance(parsed, dict):
            self._error(HTTPStatus.BAD_REQUEST, "JSON body must be an object")
            return None
        return parsed

    def _authorized(self) -> bool:
        if self.headers.get("Authorization") == f"Bearer {self.token}":
            return True
        self._error(HTTPStatus.UNAUTHORIZED, "invalid bearer token")
        return False

    @staticmethod
    def _valid_key(key: str) -> bool:
        if not KEY_RE.fullmatch(key) or len(key.encode("utf-8")) > MAX_KEY_BYTES:
            return False
        # The grammar allows dots inside a segment; a segment that is *only* dots is a
        # traversal token, never a name.
        return all(segment.strip(".") for segment in key.split("/"))

    # -- routing ---------------------------------------------------------------------------

    def _route(self) -> tuple[str, dict]:
        parts = urlsplit(self.path)
        return unquote(parts.path), parse_qs(parts.query, keep_blank_values=True)

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        path, query = self._route()
        if path == "/_test/health":
            return self._send_json(HTTPStatus.OK, {"ok": True})
        if not self._authorized():
            return
        if path == "/_test/dump":
            return self._send_json(HTTPStatus.OK, self.store.dump())
        if path == "/_test/requests":
            return self._send_json(HTTPStatus.OK, {"requests": self.store.request_log()})
        if path == "/v1/kv":
            return self._list(query)
        if path.startswith("/v1/kv/"):
            return self._get(path[len("/v1/kv/"):])
        self._error(HTTPStatus.NOT_FOUND, "no such route")

    def do_PUT(self) -> None:  # noqa: N802
        path, _ = self._route()
        if not self._authorized():
            return
        if path.startswith("/v1/kv/"):
            return self._put(path[len("/v1/kv/"):])
        match = re.fullmatch(r"/v1/kv-multipart/([A-Za-z0-9_\-]+)/(\d+)", path)
        if match:
            return self._put_part(match.group(1), int(match.group(2)))
        self._error(HTTPStatus.NOT_FOUND, "no such route")

    def do_POST(self) -> None:  # noqa: N802
        path, _ = self._route()
        if not self._authorized():
            return
        if path == "/_test/reset":
            self.store.reset()
            return self._send_json(HTTPStatus.OK, {"ok": True})
        if path == "/_test/load":
            snapshot = self._read_json()
            if snapshot is None:
                return
            return self._send_json(HTTPStatus.OK, {"loaded": self.store.load(snapshot)})
        if path == "/_test/requests/clear":
            self.store.clear_requests()
            return self._send_json(HTTPStatus.OK, {"ok": True})
        if path == "/v1/kv-multipart/start":
            return self._start_upload()
        match = re.fullmatch(r"/v1/kv-multipart/([A-Za-z0-9_\-]+)/complete", path)
        if match:
            return self._complete_upload(match.group(1))
        self._error(HTTPStatus.NOT_FOUND, "no such route")

    def do_DELETE(self) -> None:  # noqa: N802
        path, _ = self._route()
        if not self._authorized():
            return
        if path.startswith("/v1/kv/"):
            key = path[len("/v1/kv/"):]
            if not self._valid_key(key):
                return self._error(HTTPStatus.BAD_REQUEST, "invalid key")
            if self.store.delete(key):
                return self._send(HTTPStatus.NO_CONTENT)
            return self._error(HTTPStatus.NOT_FOUND, "no such key")
        match = re.fullmatch(r"/v1/kv-multipart/([A-Za-z0-9_\-]+)", path)
        if match:
            if self.store.cancel_upload(match.group(1)):
                return self._send(HTTPStatus.NO_CONTENT)
            return self._error(HTTPStatus.NOT_FOUND, "no such upload")
        self._error(HTTPStatus.NOT_FOUND, "no such route")

    # -- kv handlers -----------------------------------------------------------------------

    def _put(self, key: str) -> None:
        if not self._valid_key(key):
            return self._error(HTTPStatus.BAD_REQUEST, "invalid key")
        body = self._read_body()
        if body is None:
            return
        content_type = self.headers.get("Content-Type") or "application/octet-stream"
        self._send_json(HTTPStatus.OK, self.store.put(key, body, content_type))

    def _get(self, key: str) -> None:
        if not self._valid_key(key):
            return self._error(HTTPStatus.BAD_REQUEST, "invalid key")
        entry = self.store.get(key)
        if entry is None:
            return self._error(HTTPStatus.NOT_FOUND, "no such key")
        self._send(
            HTTPStatus.OK,
            entry["body"],
            content_type=entry["contentType"],
            headers={"Last-Modified": entry["lastModified"], "ETag": entry["etag"]},
        )

    def _list(self, query: dict) -> None:
        prefix = query.get("prefix", [""])[0]
        since = query.get("since", [None])[0] or None
        cursor = query.get("cursor", [None])[0] or None
        raw_limit = query.get("limit", [None])[0]
        try:
            limit = int(raw_limit) if raw_limit else DEFAULT_LIST_LIMIT
        except ValueError:
            return self._error(HTTPStatus.BAD_REQUEST, "invalid limit")
        limit = max(1, min(limit, MAX_LIST_LIMIT))
        self._send_json(HTTPStatus.OK, self.store.list(prefix, since, cursor, limit))

    # -- multipart handlers ------------------------------------------------------------------

    def _start_upload(self) -> None:
        request = self._read_json()
        if request is None:
            return
        key = request.get("key")
        if not isinstance(key, str) or not self._valid_key(key):
            return self._error(HTTPStatus.BAD_REQUEST, "invalid key")
        content_type = request.get("contentType") or "application/octet-stream"
        upload_id = self.store.start_upload(key, content_type)
        self._send_json(HTTPStatus.OK, {"uploadId": upload_id})

    def _put_part(self, upload_id: str, part_number: int) -> None:
        if part_number < 1:
            return self._error(HTTPStatus.BAD_REQUEST, "partNumber is 1-based")
        body = self._read_body()
        if body is None:
            return
        result = self.store.put_part(upload_id, part_number, body)
        if result is None:
            return self._error(HTTPStatus.NOT_FOUND, "no such upload")
        self._send_json(HTTPStatus.OK, result)

    def _complete_upload(self, upload_id: str) -> None:
        request = self._read_json()
        if request is None:
            return
        parts = request.get("parts")
        if not isinstance(parts, list) or not parts or not all(isinstance(p, int) and p >= 1 for p in parts):
            return self._error(HTTPStatus.BAD_REQUEST, "parts must be a non-empty list of 1-based part numbers")
        error, meta = self.store.complete_upload(upload_id, parts)
        if error == "unknown upload":
            return self._error(HTTPStatus.NOT_FOUND, "no such upload")
        if error:
            return self._error(HTTPStatus.BAD_REQUEST, error)
        assert meta is not None
        self._send_json(HTTPStatus.OK, meta)


def serve(host: str, port: int, token: str, max_body: int, state_path: str | None) -> None:
    store = Store()
    if state_path and os.path.exists(state_path):
        with open(state_path, "r", encoding="utf-8") as handle:
            count = store.load(json.load(handle))
        print(f"loaded {count} keys from {state_path}", file=sys.stderr, flush=True)

    handler = type("BoundHandler", (Handler,), {"store": store, "token": token, "max_body": max_body})
    server = ThreadingHTTPServer((host, port), handler)
    server.daemon_threads = True

    def shutdown(*_args) -> None:
        if state_path:
            with open(state_path, "w", encoding="utf-8") as handle:
                json.dump(store.dump(), handle, indent=1)
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    print(f"SYNC_TEST_SERVER_READY port={server.server_address[1]}", flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=0, help="0 picks a free port (printed on stdout)")
    parser.add_argument("--token", default=os.environ.get("SYNC_TEST_SERVER_TOKEN", "test-token"))
    parser.add_argument("--max-body", type=int, default=DEFAULT_MAX_BODY, help="per-PUT byte cap (413 above)")
    parser.add_argument("--state", default=None, help="JSON snapshot loaded at start and written on exit")
    args = parser.parse_args(argv)
    serve(args.host, args.port, args.token, args.max_body, args.state)


if __name__ == "__main__":
    main()
