"""Pulls the OCR text out of a synced manga volume.

A book's `books/{syncId}/payload.zip` is a zip of the whole book directory — `mokuro.json` plus an
`images/` folder that is usually hundreds of megabytes. We only need the JSON, so the fetch tries
an HTTP range read of the zip's central directory first (via `remotezip`) and only falls back to
downloading the whole archive when the server does not support ranges.
"""

from __future__ import annotations

import json
import posixpath
import tempfile
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from .kv import KvClient, KvError

# The canonical sidecar name inside a Hoshi book directory (Core/BookStorage.swift FileNames.mokuro).
MOKURO_JSON = "mokuro.json"


@dataclass(frozen=True)
class Bubble:
    """One OCR text block, addressed the way the readers address it."""

    page: int
    block: int
    text: str

    @property
    def block_id(self) -> str:
        """Stable per-volume bubble address, e.g. `p12b3`. Matches the readers' `data-hoshi-block`."""
        return f"p{self.page}b{self.block}"


@dataclass(frozen=True)
class Volume:
    sync_id: str
    title: str
    bubbles: list[Bubble]

    @property
    def page_count(self) -> int:
        return (max((b.page for b in self.bubbles), default=-1)) + 1


def parse_mokuro(raw: bytes | str, sync_id: str, fallback_title: str) -> Volume:
    """Turns raw `mokuro.json` bytes into a Volume of addressable bubbles.

    Blocks keep their original index even when their text is empty, so a bubble's address never
    shifts because a neighbour failed OCR — the readers look up by that exact index.
    """
    try:
        doc = json.loads(raw)
    except ValueError as exc:
        raise KvError(f"{sync_id}: mokuro.json is not valid JSON.") from exc

    title = (doc.get("volume") or doc.get("title") or fallback_title or sync_id).strip()
    bubbles: list[Bubble] = []
    for page_index, page in enumerate(doc.get("pages") or []):
        for block_index, block in enumerate(page.get("blocks") or []):
            lines = block.get("lines") or []
            # mokuro splits a bubble into drawn lines; the readers join them with newlines before
            # handing the string to the model, so match that exactly.
            text = "\n".join(str(line) for line in lines).strip()
            if not text:
                continue
            bubbles.append(Bubble(page=page_index, block=block_index, text=text))
    return Volume(sync_id=sync_id, title=title or sync_id, bubbles=bubbles)


def _find_mokuro_member(names: list[str]) -> str | None:
    """Picks the mokuro sidecar out of a zip listing, tolerating either on-disk layout."""
    canonical = [n for n in names if posixpath.basename(n) == MOKURO_JSON]
    if canonical:
        # Shallowest wins if the archive nests the book directory.
        return min(canonical, key=lambda n: n.count("/"))
    loose = [n for n in names if n.lower().endswith(".mokuro")]
    if loose:
        return min(loose, key=lambda n: n.count("/"))
    return None


def fetch_mokuro_json(
    client: KvClient,
    sync_id: str,
    log: Callable[[str], None] = lambda _: None,
) -> bytes | None:
    """Fetches just `mokuro.json` from a volume's payload.zip. None if the book has no sidecar."""
    key = f"books/{sync_id}/payload.zip"
    url = client.value_url(key)

    # Fast path: read only the zip's central directory + the one member we need.
    try:
        from remotezip import RemoteZip

        # Pass the client's session so range requests reuse its connection pool. (remotezip
        # issues its own requests, so they bypass the KV rate gate — that is only 2-3 requests
        # per book, well inside the server's budget.)
        with RemoteZip(url, headers=client.auth_headers(), session=client.session) as archive:
            member = _find_mokuro_member(archive.namelist())
            if member is None:
                return None
            log(f"{sync_id}: range-reading {member}")
            return archive.read(member)
    except ImportError:
        log("remotezip not installed - falling back to full downloads (much slower).")
    except Exception as exc:  # noqa: BLE001 - any range failure is just a fallback trigger
        log(f"{sync_id}: range read unavailable ({type(exc).__name__}), downloading full payload.")

    # Fallback: stream the whole archive to a temp file, take the sidecar, discard the rest.
    with tempfile.TemporaryDirectory() as tmp:
        zip_path = Path(tmp) / "payload.zip"
        response = client._request(  # noqa: SLF001 - internal transport reuse is deliberate
            "GET", f"/v1/kv/{_encode(key)}", headers=client.auth_headers(), stream=True
        )
        with response:
            if response.status_code == 404:
                return None
            client._ensure_ok(response, f"Downloading {key}")  # noqa: SLF001
            with open(zip_path, "wb") as handle:
                for chunk in response.iter_content(chunk_size=1 << 20):
                    handle.write(chunk)
        with zipfile.ZipFile(zip_path) as archive:
            member = _find_mokuro_member(archive.namelist())
            if member is None:
                return None
            return archive.read(member)


def _encode(key: str) -> str:
    from .kv import encode_key

    return encode_key(key)


def load_local_mokuro(path: Path, sync_id: str, fallback_title: str) -> Volume:
    """Reads a volume from a local `.mokuro`/`mokuro.json` file or a zip/cbz — used by tests."""
    if path.suffix.lower() in {".zip", ".cbz"}:
        with zipfile.ZipFile(path) as archive:
            member = _find_mokuro_member(archive.namelist())
            if member is None:
                raise KvError(f"{path} has no mokuro sidecar.")
            return parse_mokuro(archive.read(member), sync_id, fallback_title)
    return parse_mokuro(path.read_bytes(), sync_id, fallback_title)


def bubbles_by_page(volume: Volume) -> dict[int, list[Bubble]]:
    """Groups bubbles per page so the model can translate a page with its full context."""
    pages: dict[int, list[Bubble]] = {}
    for bubble in volume.bubbles:
        pages.setdefault(bubble.page, []).append(bubble)
    return pages

