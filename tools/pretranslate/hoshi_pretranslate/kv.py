"""Client for the Hoshi v2 sync KV store (`/v1/kv...`).

Wire-compatible with the iOS `HttpSyncKvClient` (Features/HttpSync/HttpSyncKv.swift) and the
Android `HttpSyncKv.kt`: same key escaping, same query encoding, same bearer header, and the same
process-wide request pacing. The server sits behind a 500 request/minute global limit, so every
request goes through a 150 ms gate exactly like the apps do.
"""

from __future__ import annotations

import json
import threading
import time
import urllib.parse
from dataclasses import dataclass
from typing import Iterator

import requests

# Unreserved characters per the v2 key grammar. Matches the Swift `urlEncode` allow-list
# (alphanumerics + "_-.~") and Java's URLEncoder closely enough for these keys.
_SAFE = "_-.~"

# The apps use 150 ms, keeping them under ~400 req/min with headroom for a browser request.
_MIN_REQUEST_INTERVAL = 0.150


class KvError(RuntimeError):
    """Any failure talking to the sync server."""


def encode_key(key: str) -> str:
    """Percent-encodes each path segment but keeps the `/` separators literal."""
    return "/".join(urllib.parse.quote(part, safe=_SAFE) for part in key.split("/"))


@dataclass(frozen=True)
class KeyMeta:
    key: str
    last_modified: str = ""
    etag: str | None = None
    size: int | None = None
    content_type: str | None = None


class _RequestGate:
    """Process-wide pacer. Reserves its slot before sleeping so concurrent callers stagger."""

    def __init__(self, min_interval: float) -> None:
        self._min_interval = min_interval
        self._lock = threading.Lock()
        self._next_at = 0.0

    def wait(self) -> None:
        with self._lock:
            now = time.monotonic()
            scheduled = max(now, self._next_at)
            self._next_at = scheduled + self._min_interval
            delay = scheduled - now
        if delay > 0:
            time.sleep(delay)

    def impose_cooldown(self, seconds: float) -> None:
        with self._lock:
            deadline = time.monotonic() + seconds
            self._next_at = max(self._next_at, deadline)


_GATE = _RequestGate(_MIN_REQUEST_INTERVAL)


class KvClient:
    """Minimal KV transport: the list/get/put subset this tool needs."""

    MAX_RATE_LIMIT_RETRIES = 5

    def __init__(self, base_url: str, token: str, session: requests.Session | None = None) -> None:
        base = base_url.strip().rstrip("/")
        if not base:
            raise KvError("Sync server URL is empty.")
        # Parse the host rather than substring-matching: "http://mylocalhost.evil.com" contains
        # "localhost" and would otherwise get the bearer token in cleartext.
        host = urllib.parse.urlparse(base).hostname or ""
        if not base.startswith("https://") and host not in ("localhost", "127.0.0.1", "::1"):
            # The apps refuse cleartext for the same reason: the bearer token would go over the wire.
            raise KvError(f"Refusing to send a bearer token over cleartext: {base}")
        self.base_url = base
        self.token = token.strip()
        if not self.token:
            raise KvError("Sync token is empty.")
        self.session = session or requests.Session()

    # -- internals -------------------------------------------------------------------------

    def _headers(self, content_type: str | None = None) -> dict[str, str]:
        headers = {"Authorization": f"Bearer {self.token}", "Accept": "application/json"}
        if content_type:
            headers["Content-Type"] = content_type
        return headers

    def _request(self, method: str, path: str, **kwargs) -> requests.Response:
        url = self.base_url + path
        last_error: Exception | None = None
        for attempt in range(self.MAX_RATE_LIMIT_RETRIES + 1):
            _GATE.wait()
            try:
                response = self.session.request(method, url, timeout=(30, 600), **kwargs)
            except requests.RequestException as exc:  # network-level failure
                last_error = exc
                if attempt == self.MAX_RATE_LIMIT_RETRIES:
                    raise KvError(f"{method} {path} failed: {exc}") from exc
                time.sleep(2**attempt)
                continue

            if response.status_code == 429 and attempt < self.MAX_RATE_LIMIT_RETRIES:
                retry_after = response.headers.get("Retry-After")
                try:
                    cooldown = float(retry_after) if retry_after else 2.0 * (2**attempt)
                except ValueError:
                    cooldown = 2.0 * (2**attempt)
                _GATE.impose_cooldown(cooldown)
                continue
            return response
        raise KvError(f"{method} {path} failed after retries: {last_error}")

    @staticmethod
    def _ensure_ok(response: requests.Response, what: str) -> None:
        if 200 <= response.status_code < 300:
            return
        body = (response.text or "")[:400]
        if response.status_code in (401, 403):
            raise KvError(
                f"{what}: server rejected the token ({response.status_code}). "
                "Re-copy the sync token from the app's Settings -> Sync."
            )
        raise KvError(f"{what}: HTTP {response.status_code} {body}")

    # -- operations ------------------------------------------------------------------------

    def list(
        self,
        prefix: str | None = None,
        since: str | None = None,
        cursor: str | None = None,
        limit: int | None = None,
    ) -> tuple[list[KeyMeta], bool, str | None]:
        parts = []
        if prefix is not None:
            parts.append("prefix=" + urllib.parse.quote(prefix, safe=_SAFE))
        if since is not None:
            parts.append("since=" + urllib.parse.quote(since, safe=_SAFE))
        if cursor is not None:
            parts.append("cursor=" + urllib.parse.quote(cursor, safe=_SAFE))
        if limit is not None:
            parts.append(f"limit={limit}")
        query = ("?" + "&".join(parts)) if parts else ""

        response = self._request("GET", f"/v1/kv{query}", headers=self._headers())
        self._ensure_ok(response, "Listing keys")
        try:
            payload = response.json()
        except ValueError as exc:
            raise KvError("Sync server returned malformed JSON for the key listing.") from exc
        keys = [
            KeyMeta(
                key=item.get("key", ""),
                last_modified=item.get("lastModified") or "",
                etag=item.get("etag"),
                size=item.get("size"),
                content_type=item.get("contentType"),
            )
            for item in (payload.get("keys") or [])
        ]
        return keys, bool(payload.get("truncated")), payload.get("nextCursor")

    def list_all(self, prefix: str | None = None, limit: int | None = None) -> Iterator[KeyMeta]:
        """Walks every page of a listing, mirroring the apps' auto-pagination loop."""
        cursor: str | None = None
        while True:
            keys, truncated, next_cursor = self.list(prefix=prefix, cursor=cursor, limit=limit)
            yield from keys
            if not truncated or not next_cursor:
                return
            cursor = next_cursor

    def get(self, key: str) -> bytes | None:
        """Returns the value bytes, or None when the key does not exist (404)."""
        response = self._request("GET", f"/v1/kv/{encode_key(key)}", headers=self._headers())
        if response.status_code == 404:
            return None
        self._ensure_ok(response, f"Fetching {key}")
        return response.content

    def get_json(self, key: str) -> dict | None:
        raw = self.get(key)
        if raw is None:
            return None
        try:
            return json.loads(raw)
        except ValueError as exc:
            raise KvError(f"Key {key} did not contain valid JSON.") from exc

    def put(self, key: str, body: bytes, content_type: str = "application/json") -> KeyMeta:
        response = self._request(
            "PUT",
            f"/v1/kv/{encode_key(key)}",
            headers=self._headers(content_type),
            data=body,
        )
        self._ensure_ok(response, f"Uploading {key}")
        try:
            payload = response.json()
        except ValueError:
            payload = {}
        return KeyMeta(
            key=payload.get("key", key),
            last_modified=payload.get("lastModified") or "",
            etag=payload.get("etag"),
            size=payload.get("size"),
            content_type=payload.get("contentType"),
        )

    def value_url(self, key: str) -> str:
        """Absolute URL of a value, for range-reading a payload.zip without downloading it."""
        return f"{self.base_url}/v1/kv/{encode_key(key)}"

    def auth_headers(self) -> dict[str, str]:
        return {"Authorization": f"Bearer {self.token}"}
