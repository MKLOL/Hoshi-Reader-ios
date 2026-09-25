"""Bounded, resumable writes to the existing Hoshi KV API. No model calls."""

import json
from http.client import HTTPException
import os
from pathlib import Path
import shlex
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import build_opener, HTTPRedirectHandler, Request

from artifacts import MAX_BYTES, require, sha


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # Bearer credentials must never follow a redirect to another host/path.
        return None


def credentials(env_file=None):
    values = {}
    if env_file:
        for line in Path(env_file).read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("export "):
                line = line[7:].strip()
            key, separator, value = line.partition("=")
            require(separator and key.strip() in {"HOSHI_KV_BASE_URL", "HOSHI_KV_TOKEN"},
                    "Env file must contain only HOSHI_KV_BASE_URL and HOSHI_KV_TOKEN assignments")
            parts = shlex.split(value, comments=True)
            require(len(parts) == 1, "Env values must be nonempty (quote values containing spaces)")
            values[key.strip()] = parts[0]
    for key in ("HOSHI_KV_BASE_URL", "HOSHI_KV_TOKEN"):
        if key in os.environ:
            values[key] = os.environ[key]
        require(bool(values.get(key, "").strip()), f"Set {key} in the environment or --env-file")
    return values["HOSHI_KV_BASE_URL"], values["HOSHI_KV_TOKEN"]


class KvClient:
    def __init__(self, base_url, token):
        url = urlsplit(base_url)
        require(url.hostname and not url.username and not url.password and not url.query and not url.fragment
                and not any(c.isspace() for c in base_url), "Invalid sync server URL")
        require(url.scheme == "https" or (url.scheme == "http" and url.hostname in {"127.0.0.1", "localhost", "::1"}),
                "Sync requires HTTPS; HTTP is allowed only for a loopback test server")
        require(bool(token.strip()) and token.isascii() and not any(c.isspace() for c in token), "Invalid bearer token")
        self.base_url = base_url.rstrip("/")
        self.token = token
        self.opener = build_opener(NoRedirect())

    def request(self, method, key, body=None, content_type=None):
        for attempt in range(3):
            request = Request(self.base_url + "/v1/kv/" + key, data=body, method=method,
                              headers={"Authorization": "Bearer " + self.token})
            if content_type:
                request.add_header("Content-Type", content_type)
            try:
                with self.opener.open(request, timeout=30) as response:
                    data = response.read(MAX_BYTES + 1)
                    require(len(data) <= MAX_BYTES, "Server response exceeds the article size limit")
                    return data
            except HTTPError as error:
                error.close()
                if method == "GET" and error.code == 404:
                    return None
                if error.code not in {429, 500, 502, 503, 504} or attempt == 2:
                    raise ValueError(f"Sync {method} failed with HTTP {error.code}; credentials and response body omitted") from None
            except (URLError, TimeoutError, OSError, HTTPException):
                if attempt == 2:
                    raise ValueError(f"Sync {method} failed after 3 attempts; rerun the same job to resume") from None
            time.sleep(0.2 * (attempt + 1))

    def get(self, key):
        return self.request("GET", key)

    def put(self, key, content_type, body):
        response = decode(self.request("PUT", key, body, content_type), "upload receipt")
        require(response.get("etag") == sha(body), "Server upload receipt has an unexpected hash")
        require(self.get(key) == body, "Uploaded bytes failed read-back verification; rerun this job")


def decode(body, label):
    try:
        result = json.loads(body)
    except (ValueError, TypeError):
        raise ValueError(f"Remote {label} is malformed; refusing to overwrite it") from None
    require(isinstance(result, dict), f"Remote {label} must be an object")
    return result


def publish(client, uploads, replace_translations=False):
    # Finish all conflict checks before the first write, including retries of a partial job.
    remote = {key: client.get(key) for key, _, _ in uploads}
    by_suffix = {key.rsplit("/", 1)[1]: (key, mime, body) for key, mime, body in uploads}
    zip_key, _, zip_body = by_suffix["epub.zip"]
    manifest_key, _, manifest_body = by_suffix["epub.manifest"]
    metadata_key, _, metadata_body = by_suffix["metadata"]
    sentences_key, _, sentences_body = by_suffix["sentences"]
    desired_manifest = decode(manifest_body, "local manifest")
    matching_payload = False
    if remote[metadata_key] is not None:
        metadata = decode(remote[metadata_key], "metadata")
        require(not metadata.get("deletedAt"), "This article was deleted on a device; refusing to resurrect it")
        require(metadata.get("contentType") == "epub", "Article id collides with another content type")
        if remote[manifest_key] is None:
            require(metadata.get("title") == decode(metadata_body, "local metadata")["title"],
                    "Article id already has unrelated metadata")
    if remote[manifest_key] is not None:
        manifest = decode(remote[manifest_key], "manifest")
        require(manifest.get("format") == "epub", "Article id collides with another payload type")
        require(remote[zip_key] is not None and sha(remote[zip_key]) == manifest.get("sha256")
                and len(remote[zip_key]) == manifest.get("sizeBytes"), "Remote EPUB is incomplete or corrupt; no writes made")
        matching_payload = (manifest.get("sha256") == desired_manifest["sha256"] or
                            manifest.get("contentSha256") == desired_manifest["contentSha256"])
        require(matching_payload, "This URL already has different EPUB content; reuse its original job")
    elif remote[zip_key] is not None:
        require(remote[zip_key] == zip_body, "This article id has a different unfinished EPUB upload")
    if remote[sentences_key] is not None:
        existing = decode(remote[sentences_key], "translations")
        require(existing.get("syncId") == decode(sentences_body, "local translations")["syncId"],
                "Remote translations belong to a different book")
        require(existing == decode(sentences_body, "local translations") or replace_translations,
                "Different translations already exist; review them before using --replace-translations")

    written, skipped = [], []
    for key, mime, body in uploads:
        # Preserve device changes to shelf/title and a differently compressed but identical EPUB.
        preserve = ((key in {zip_key, manifest_key} and matching_payload) or
                    (key == metadata_key and remote[key] is not None))
        if preserve or remote[key] == body:
            skipped.append(key)
            continue
        current = client.get(key)
        if current == body:
            skipped.append(key)
            continue
        require(current == remote[key], "Server changed during publication; stop and rerun this job")
        # The generic KV API has no CAS/transaction. This check narrows, but cannot eliminate,
        # concurrent-writer races. Only one publisher should work on an article at a time.
        client.put(key, mime, body)
        written.append(key)
    return {"uploaded": written, "unchanged": skipped}
