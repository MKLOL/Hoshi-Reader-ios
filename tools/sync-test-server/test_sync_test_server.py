#!/usr/bin/env python3
"""Contract tests for sync_test_server.py — the server the platform integration tests trust.

Every behavior the Android and iOS clients rely on (`docs/HTTP_SYNC_KV.md`) is pinned here
against a live instance of the server, over real HTTP.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import subprocess
import sys
import unittest
import urllib.error
import urllib.request
from pathlib import Path

SERVER = Path(__file__).resolve().parent / "sync_test_server.py"
TOKEN = "contract-token"


class ServerProcess:
    def __init__(self, extra_args: list[str] | None = None) -> None:
        self.process = subprocess.Popen(
            [sys.executable, str(SERVER), "--port", "0", "--token", TOKEN, *(extra_args or [])],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        assert self.process.stdout is not None
        line = self.process.stdout.readline()
        if not line.startswith("SYNC_TEST_SERVER_READY port="):
            raise RuntimeError(f"server did not start: {line!r} {self.process.stderr.read()}")
        self.port = int(line.strip().split("=", 1)[1])
        self.base = f"http://127.0.0.1:{self.port}"

    def stop(self) -> None:
        self.process.terminate()
        self.process.wait(timeout=10)
        for stream in (self.process.stdout, self.process.stderr):
            if stream:
                stream.close()


def call(base: str, method: str, path: str, body: bytes | None = None, content_type: str | None = None,
         token: str | None = TOKEN) -> tuple[int, dict, bytes]:
    request = urllib.request.Request(base + path, data=body, method=method)
    if token is not None:
        request.add_header("Authorization", f"Bearer {token}")
    if content_type:
        request.add_header("Content-Type", content_type)
    try:
        with urllib.request.urlopen(request) as response:
            return response.status, dict(response.headers), response.read()
    except urllib.error.HTTPError as error:
        return error.code, dict(error.headers), error.read()


def call_json(base: str, method: str, path: str, payload: dict | None = None, token: str | None = TOKEN):
    body = json.dumps(payload).encode("utf-8") if payload is not None else None
    status, headers, raw = call(base, method, path, body, "application/json; charset=utf-8", token)
    return status, (json.loads(raw) if raw else None)


class SyncTestServerContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.server = ServerProcess()
        cls.base = cls.server.base

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.stop()

    def setUp(self) -> None:
        self.assertEqual(200, call_json(self.base, "POST", "/_test/reset")[0])

    # -- auth / validation -----------------------------------------------------------------

    def test_rejects_missing_and_wrong_tokens_with_401_json(self):
        for token in (None, "nope"):
            status, body = call_json(self.base, "GET", "/v1/kv", token=token)
            self.assertEqual(401, status)
            self.assertIn("error", body)
        self.assertEqual(200, call_json(self.base, "GET", "/_test/health", token=None)[0])

    def test_rejects_invalid_keys_with_400(self):
        for key in ("bad key", "a/../b", "x" * 65, "trailing/", "/leading", "ünïcode"):
            status, _, _ = call(self.base, "PUT", "/v1/kv/" + urllib.request.quote(key, safe="/"),
                                b"x", "text/plain")
            self.assertEqual(400, status, key)

    # -- put / get / delete ------------------------------------------------------------------

    def test_put_get_round_trip_preserves_bytes_content_type_and_stamps(self):
        body = b'{"chapterIndex":3}'
        status, meta = call_json(self.base, "PUT", "/v1/kv/books/yotsubato_01/bookmark")
        self.assertEqual(200, status)  # empty JSON body is still a valid put
        status, _, raw = call(self.base, "PUT", "/v1/kv/books/yotsubato_01/bookmark", body,
                              "application/json; charset=utf-8")
        self.assertEqual(200, status)
        meta = json.loads(raw)
        self.assertEqual("books/yotsubato_01/bookmark", meta["key"])
        self.assertEqual("sha256:" + hashlib.sha256(body).hexdigest(), meta["etag"])
        self.assertEqual(len(body), meta["size"])
        self.assertEqual("application/json; charset=utf-8", meta["contentType"])
        self.assertRegex(meta["lastModified"], r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$")

        status, headers, fetched = call(self.base, "GET", "/v1/kv/books/yotsubato_01/bookmark")
        self.assertEqual(200, status)
        self.assertEqual(body, fetched)
        self.assertEqual("application/json; charset=utf-8", headers["Content-Type"])
        self.assertEqual(meta["etag"], headers["ETag"])
        self.assertEqual(meta["lastModified"], headers["Last-Modified"])
        self.assertEqual(str(len(body)), headers["Content-Length"])

    def test_percent_encoded_keys_decode_to_the_same_key(self):
        status, _, _ = call(self.base, "PUT", "/v1/kv/books/zenitendou-01/epub.manifest", b"m", "text/plain")
        self.assertEqual(200, status)
        status, _, raw = call(self.base, "GET", "/v1/kv/books/zenitendou-01/epub%2Emanifest")
        self.assertEqual(200, status)
        self.assertEqual(b"m", raw)

    def test_get_and_delete_missing_key_are_404_and_delete_is_204(self):
        status, body = call_json(self.base, "GET", "/v1/kv/books/none/bookmark")
        self.assertEqual(404, status)
        self.assertIn("error", body)
        self.assertEqual(404, call(self.base, "DELETE", "/v1/kv/books/none/bookmark")[0])
        call(self.base, "PUT", "/v1/kv/books/some/bookmark", b"x", "text/plain")
        status, headers, raw = call(self.base, "DELETE", "/v1/kv/books/some/bookmark")
        self.assertEqual(204, status)
        self.assertEqual(b"", raw)
        self.assertIsNone(headers.get("Content-Type"), "a 204 carries no body and no Content-Type")
        self.assertEqual(404, call(self.base, "GET", "/v1/kv/books/some/bookmark")[0])

    def test_body_cap_returns_413(self):
        server = ServerProcess(["--max-body", "16"])
        try:
            status, _, _ = call(server.base, "PUT", "/v1/kv/big", b"x" * 17, "application/zip")
            self.assertEqual(413, status)
            status, _, _ = call(server.base, "PUT", "/v1/kv/small", b"x" * 16, "application/zip")
            self.assertEqual(200, status)
        finally:
            server.stop()

    # -- list ------------------------------------------------------------------------------

    def test_stamps_are_strictly_monotonic_and_list_filters_since_prefix_cursor_limit(self):
        stamps = []
        for i in range(5):
            status, _, raw = call(self.base, "PUT", f"/v1/kv/books/b{i}/bookmark", b"x", "text/plain")
            stamps.append(json.loads(raw)["lastModified"])
        call(self.base, "PUT", "/v1/kv/settings/ai", b"y", "text/plain")
        self.assertEqual(stamps, sorted(stamps))
        self.assertEqual(len(stamps), len(set(stamps)), "every write must get a distinct stamp")

        status, page = call_json(self.base, "GET", "/v1/kv?prefix=books/")
        self.assertEqual(200, status)
        self.assertEqual([f"books/b{i}/bookmark" for i in range(5)], [k["key"] for k in page["keys"]])
        self.assertFalse(page["truncated"])
        self.assertIsNone(page["nextCursor"])
        self.assertEqual({"key", "lastModified", "etag", "size", "contentType"}, set(page["keys"][0]))

        status, page = call_json(self.base, "GET", "/v1/kv?since=" + stamps[2])
        self.assertEqual([f"books/b3/bookmark", "books/b4/bookmark", "settings/ai"],
                         [k["key"] for k in page["keys"]], "since is exclusive: lastModified > since")

        status, page1 = call_json(self.base, "GET", "/v1/kv?prefix=books/&limit=2")
        self.assertTrue(page1["truncated"])
        self.assertEqual("books/b1/bookmark", page1["nextCursor"])
        status, page2 = call_json(self.base, "GET", f"/v1/kv?prefix=books/&limit=2&cursor={page1['nextCursor']}")
        self.assertEqual(["books/b2/bookmark", "books/b3/bookmark"], [k["key"] for k in page2["keys"]])
        status, page3 = call_json(self.base, "GET", f"/v1/kv?prefix=books/&limit=2&cursor={page2['nextCursor']}")
        self.assertEqual(["books/b4/bookmark"], [k["key"] for k in page3["keys"]])
        self.assertFalse(page3["truncated"])

        status, page = call_json(self.base, "GET", "/v1/kv?limit=99999")
        self.assertEqual(200, status, "limit above the max is clamped, not rejected")

    # -- multipart ---------------------------------------------------------------------------

    def test_multipart_upload_concatenates_parts_in_listed_order(self):
        status, started = call_json(self.base, "POST", "/v1/kv-multipart/start",
                                    {"key": "books/big/payload.zip", "contentType": "application/zip"})
        self.assertEqual(200, status)
        upload_id = started["uploadId"]
        parts = {1: b"AAAA", 2: b"BB", 3: b"CCCCCC"}
        for number, chunk in parts.items():
            status, _, raw = call(self.base, "PUT", f"/v1/kv-multipart/{upload_id}/{number}", chunk,
                                  "application/octet-stream")
            self.assertEqual(200, status)
            self.assertEqual(len(chunk), json.loads(raw)["size"])
        status, done = call_json(self.base, "POST", f"/v1/kv-multipart/{upload_id}/complete", {"parts": [1, 2, 3]})
        self.assertEqual(200, status)
        whole = b"AAAABBCCCCCC"
        self.assertEqual("books/big/payload.zip", done["key"])
        self.assertEqual(len(whole), done["size"])
        self.assertEqual("sha256:" + hashlib.sha256(whole).hexdigest(), done["etag"])
        status, headers, raw = call(self.base, "GET", "/v1/kv/books/big/payload.zip")
        self.assertEqual(whole, raw)
        self.assertEqual("application/zip", headers["Content-Type"])
        # The upload is gone once completed.
        self.assertEqual(404, call(self.base, "DELETE", f"/v1/kv-multipart/{upload_id}")[0])

    def test_multipart_cancel_and_missing_parts(self):
        _, started = call_json(self.base, "POST", "/v1/kv-multipart/start",
                               {"key": "books/big/payload.zip", "contentType": "application/zip"})
        upload_id = started["uploadId"]
        call(self.base, "PUT", f"/v1/kv-multipart/{upload_id}/1", b"A", "application/octet-stream")
        status, body = call_json(self.base, "POST", f"/v1/kv-multipart/{upload_id}/complete", {"parts": [1, 2]})
        self.assertEqual(400, status)
        self.assertEqual(204, call(self.base, "DELETE", f"/v1/kv-multipart/{upload_id}")[0])
        self.assertEqual(404, call(self.base, "GET", "/v1/kv/books/big/payload.zip")[0])
        status, _ = call_json(self.base, "POST", "/v1/kv-multipart/unknown/complete", {"parts": [1]})
        self.assertEqual(404, status)

    # -- test hooks ----------------------------------------------------------------------------

    def test_dump_load_reset_and_request_log(self):
        call(self.base, "PUT", "/v1/kv/books/a/bookmark", b"\x00\x01", "application/octet-stream")
        _, dump = call_json(self.base, "GET", "/_test/dump")
        self.assertEqual(1, len(dump["entries"]))
        self.assertEqual(b"\x00\x01", base64.b64decode(dump["entries"][0]["body"]))
        call_json(self.base, "POST", "/_test/reset")
        self.assertEqual([], call_json(self.base, "GET", "/v1/kv")[1]["keys"])
        _, loaded = call_json(self.base, "POST", "/_test/load", dump)
        self.assertEqual(1, loaded["loaded"])
        _, page = call_json(self.base, "GET", "/v1/kv")
        self.assertEqual(dump["entries"][0]["lastModified"], page["keys"][0]["lastModified"])
        self.assertEqual(dump["entries"][0]["etag"], page["keys"][0]["etag"])

        call_json(self.base, "POST", "/_test/requests/clear")
        call(self.base, "GET", "/v1/kv/books/a/bookmark")
        _, log = call_json(self.base, "GET", "/_test/requests")
        methods = [(r["method"], r["path"], r["status"]) for r in log["requests"]]
        self.assertIn(("GET", "/v1/kv/books/a/bookmark", 200), methods)

    def test_rejected_requests_never_poison_a_keep_alive_connection(self):
        import http.client
        conn = http.client.HTTPConnection("127.0.0.1", self.server.port, timeout=5)
        try:
            def request(method, path, body=None, token=TOKEN, content_type="application/octet-stream"):
                headers = {}
                if token is not None:
                    headers["Authorization"] = f"Bearer {token}"
                if body is not None:
                    headers["Content-Type"] = content_type
                conn.request(method, path, body=body, headers=headers)
                response = conn.getresponse()
                response.read()
                return response.status

            self.assertEqual(401, request("PUT", "/v1/kv/books/a/bookmark", b"x" * 4096, token="wrong"))
            self.assertEqual(200, request("GET", "/_test/health"),
                             "the unread body of a rejected PUT must not be parsed as the next request")
            self.assertEqual(400, request("PUT", "/v1/kv/bad%20key", b"y" * 1024))
            self.assertEqual(200, request("GET", "/_test/health"))
            self.assertEqual(404, request("POST", "/v1/kv-multipart/nope/complete", b'{"parts":[1]}',
                                          content_type="application/json"))
            self.assertEqual(200, request("GET", "/_test/health"))
        finally:
            conn.close()
        small = ServerProcess(["--max-body", "64"])
        try:
            conn = http.client.HTTPConnection("127.0.0.1", small.port, timeout=5)
            conn.request("PUT", "/v1/kv/books/a/payload.zip", body=b"z" * 200,
                         headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/zip"})
            response = conn.getresponse()
            response.read()
            self.assertEqual(413, response.status)
            conn.request("GET", "/_test/health", headers={"Authorization": f"Bearer {TOKEN}"})
            self.assertEqual(200, conn.getresponse().status,
                             "after a 413 the client carries on (reconnecting if told to)")
            conn.close()
        finally:
            small.stop()

    def test_head_returns_the_get_headers_without_a_body(self):
        import http.client
        call(self.base, "PUT", "/v1/kv/books/a/bookmark", b"12345", "application/json; charset=utf-8")
        conn = http.client.HTTPConnection("127.0.0.1", self.server.port, timeout=5)
        try:
            conn.request("HEAD", "/v1/kv/books/a/bookmark", headers={"Authorization": f"Bearer {TOKEN}"})
            response = conn.getresponse()
            self.assertEqual(200, response.status)
            self.assertEqual("5", response.getheader("Content-Length"))
            self.assertEqual("sha256:" + hashlib.sha256(b"12345").hexdigest(), response.getheader("ETag"))
            self.assertEqual(b"", response.read())
            conn.request("HEAD", "/v1/kv/books/none/bookmark", headers={"Authorization": f"Bearer {TOKEN}"})
            response = conn.getresponse()
            self.assertEqual(404, response.status)
            response.read()
        finally:
            conn.close()

    def test_fail_next_serves_the_armed_status_then_recovers_and_is_logged(self):
        call(self.base, "PUT", "/v1/kv/books/a/payload.zip", b"zip", "application/zip")
        status, _ = call_json(self.base, "POST", "/_test/fail_next",
                              {"method": "GET", "pathPrefix": "/v1/kv/books/a/payload.zip", "status": 503, "count": 2})
        self.assertEqual(200, status)
        call_json(self.base, "POST", "/_test/requests/clear")
        self.assertEqual(503, call(self.base, "GET", "/v1/kv/books/a/payload.zip")[0])
        self.assertEqual(404, call(self.base, "GET", "/v1/kv/books/a/bookmark")[0], "other keys are unaffected")
        self.assertEqual(503, call(self.base, "GET", "/v1/kv/books/a/payload.zip")[0])
        status, _, raw = call(self.base, "GET", "/v1/kv/books/a/payload.zip")
        self.assertEqual(200, status, "the fault is spent after `count` hits")
        self.assertEqual(b"zip", raw)
        self.assertEqual(200, call(self.base, "PUT", "/v1/kv/books/a/payload.zip", b"zip2", "application/zip")[0],
                         "a GET-only fault leaves PUT alone")
        _, log = call_json(self.base, "GET", "/_test/requests")
        statuses = [r["status"] for r in log["requests"]
                    if r["path"] == "/v1/kv/books/a/payload.zip" and r["method"] == "GET"]
        self.assertEqual([503, 503, 200], statuses)
        status, _ = call_json(self.base, "POST", "/_test/fail_next", {"pathPrefix": "/_test/dump", "status": 500})
        self.assertEqual(400, status, "faults only apply to API routes")

    def test_snapshot_stamps_without_fractions_do_not_break_later_writes(self):
        _, loaded = call_json(self.base, "POST", "/_test/load", {"entries": [
            {"key": "books/a/bookmark", "contentType": "text/plain", "lastModified": "2099-01-01T00:00:00Z",
             "body": base64.b64encode(b"x").decode()}
        ]})
        self.assertEqual(1, loaded["loaded"])
        status, _, raw = call(self.base, "PUT", "/v1/kv/books/b/bookmark", b"y", "text/plain")
        self.assertEqual(200, status)
        self.assertGreater(json.loads(raw)["lastModified"], "2099-01-01T00:00:00Z")

    def test_state_file_round_trips_across_restarts(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            state = os.path.join(tmp, "state.json")
            first = ServerProcess(["--state", state])
            call(first.base, "PUT", "/v1/kv/books/a/bookmark", b"persist", "text/plain")
            first.stop()
            second = ServerProcess(["--state", state])
            try:
                status, _, raw = call(second.base, "GET", "/v1/kv/books/a/bookmark")
                self.assertEqual(200, status)
                self.assertEqual(b"persist", raw)
            finally:
                second.stop()


if __name__ == "__main__":
    unittest.main()
