# Behavior test for the cross-platform payload content hash (`HttpSyncPayloadCodec.contentSha`).
#
# Android asserts the SAME golden vectors in
# app/src/test/java/moe/antimony/hoshi/features/sync/http/HttpSyncPayloadTest.kt against its
# Kotlin implementation. This repo has no Swift test target, so this test compiles the real
# Swift function out of Features/HttpSync/HttpSyncPayload.swift with `swiftc` and runs it
# against identical fixtures — including through a symlinked parent (every iOS app container
# lives under the `/var` -> `/private/var` symlink) and with a trailing-slash directory URL.
# Those are the two conditions under which builds through 0.11.3 hashed garbage relative paths
# and published manifests no device could ever verify.
#
# Regenerating a vector: change the fixture on BOTH platforms, or neither. Every synced book's
# manifest is compared against this derivation on every device.

import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PAYLOAD_SOURCE = ROOT / "Features/HttpSync/HttpSyncPayload.swift"
STORAGE_SOURCE = ROOT / "Core/BookStorage.swift"

# (name, {relative path: bytes}, expected hash). Mirrors HttpSyncPayloadTest.kt.
GOLDEN_VECTORS = [
    (
        "sidecars-are-excluded",
        {
            "a.txt": b"alpha",
            "dir/b.bin": bytes([0, 1, 2]),
            "bookmark.json": b"ignored",
            "bookinfo.json": b"ignored derived data",
        },
        "sha256:dc5ddd76880180e6f4f6d7d57bdae426df8910c9ec8c2ae30a978b1034438dc7",
    ),
    (
        "nfd-filename-hashes-as-nfc",
        {"café.txt": b"x"},
        "sha256:f844ecac6b5f73cd1bf8308089892b5668972d0d2f63141082804681ffea00ae",
    ),
    (
        "excluded-dir-generated-cover-and-cache",
        {
            "a.txt": b"alpha",
            "dir/b.bin": bytes([0, 1, 2]),
            "dir/sub/c.txt": b"gamma",
            "café.txt": b"x",
            "bookmark.json": b"ignored",
            ".generated_cover.jpg": b"ignored",
            ".payload.content.sha256.cache": b"sha256:" + b"0" * 64,
            "Sasayaki/audio.m4b": b"ignored",
        },
        "sha256:d87d77783cc9317975bcb60eec51c6bbba63f1457ee004aa95fd56e90fd07131",
    ),
]


def _extract_braced(source: str, signature: str) -> str:
    match = re.search(signature, source)
    if not match:
        raise AssertionError(f"signature not found: {signature}")
    open_index = source.index("{", match.end())
    depth = 0
    for index in range(open_index, len(source)):
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[match.start():index + 1]
    raise AssertionError("unbalanced braces")


def _extract_bracketed(source: str, prefix: str) -> str:
    match = re.search(prefix + r"\s*=\s*\[", source)
    if not match:
        raise AssertionError(f"declaration not found: {prefix}")
    close_index = source.index("]", match.end())
    return source[match.start():close_index + 1].replace("nonisolated ", "")


def build_harness_source() -> str:
    payload = PAYLOAD_SOURCE.read_text(encoding="utf-8")
    storage = STORAGE_SOURCE.read_text(encoding="utf-8")
    generated_cover = re.search(r'static let generatedCover = ("[^"]+")', storage).group(1)
    constants = "\n".join(
        f'let {name} = {value}'
        for name, value in re.findall(r'let (httpSyncPayload\w+Filename) = ("[^"]+")', payload)
    )
    excluded_files = _extract_bracketed(payload, r"let httpSyncPayloadExcludedFiles: Set<String>")
    excluded_dirs = _extract_bracketed(payload, r"let httpSyncPayloadExcludedDirs: Set<String>")
    content_sha = _extract_braced(
        payload,
        r"static func contentSha\(bookRoot: URL, excludingRootFiles: Set<String> = \[\]\) throws -> String",
    )
    return f"""
import Foundation
import CryptoKit

struct HttpSyncError: Error {{
    let message: String
    init(_ message: String) {{ self.message = message }}
}}
enum FileNames {{ static let generatedCover = {generated_cover} }}
{constants}
{excluded_files}
{excluded_dirs}

enum Harness {{
{content_sha}
}}

let arguments = CommandLine.arguments
let raw = URL(fileURLWithPath: arguments[1])
// "dir" mirrors the app's staging/book roots: `appendingPathComponent(_, isDirectory: true)`.
let root = arguments[2] == "dir"
    ? raw.deletingLastPathComponent().appendingPathComponent(raw.lastPathComponent, isDirectory: true)
    : URL(fileURLWithPath: arguments[1], isDirectory: false)
print(try Harness.contentSha(bookRoot: root))
"""


def write_fixture(root: Path, files: dict) -> None:
    for relative, data in files.items():
        target = root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)


@unittest.skipUnless(shutil.which("swiftc"), "swiftc is required to compile the Swift hash")
class PayloadContentHashTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workdir = Path(tempfile.mkdtemp(prefix="hoshi-content-hash-"))
        source = cls.workdir / "harness.swift"
        source.write_text(build_harness_source(), encoding="utf-8")
        cls.binary = cls.workdir / "harness"
        subprocess.run(
            ["swiftc", "-O", "-o", str(cls.binary), str(source)],
            check=True,
            capture_output=True,
            text=True,
        )

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.workdir, ignore_errors=True)

    def hash_of(self, path: Path, mode: str) -> str:
        result = subprocess.run(
            [str(self.binary), str(path), mode], check=True, capture_output=True, text=True
        )
        return result.stdout.strip().splitlines()[-1]

    def test_golden_vectors_survive_symlinks_and_directory_urls(self):
        for name, files, expected in GOLDEN_VECTORS:
            with self.subTest(vector=name):
                # `tempfile` on macOS already lives under the `/var` -> `/private/var` symlink,
                # exactly like an iOS app container; `realpath` gives the plain form.
                symlinked_parent = Path(tempfile.mkdtemp(prefix="vector-", dir=self.workdir))
                fixture = symlinked_parent / ".hoshi-sync-update-0123-4567"
                fixture.mkdir()
                write_fixture(fixture, files)
                plain = Path(os.path.realpath(fixture))
                link = symlinked_parent / "linked-book"
                link.symlink_to(fixture, target_is_directory=True)
                for label, path in (("plain", plain), ("via-symlink", link), ("as-given", fixture)):
                    for mode in ("file", "dir"):
                        with self.subTest(path=label, url=mode):
                            self.assertEqual(expected, self.hash_of(path, mode))


if __name__ == "__main__":
    unittest.main()
