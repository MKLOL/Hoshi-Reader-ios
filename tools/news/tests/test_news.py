import copy
from contextlib import redirect_stderr, redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import xml.etree.ElementTree as ET
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from artifacts import (build, content_hash, json_bytes, make_sidecar, prepare,
                       read_json, sanitize, sha, validated_uploads, write)
from hoshi_news import main
from make_fixture import FIXTURES, make_fixture
from publisher import credentials, KvClient, publish
from segment import normalize, segment

server_path = Path(__file__).resolve().parents[2] / "sync-test-server" / "sync_test_server.py"
spec = importlib.util.spec_from_file_location("sync_test_server", server_path)
sync_server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync_server)


class FixtureTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.job = self.root / "job"
        make_fixture(self.job)
        self.plan = read_json(self.job / "plan.json")
        self.translations = read_json(self.job / "translations.json")


class NewsTests(FixtureTest):
    def test_epub_is_well_formed_single_spine_with_ncx_and_ruby(self):
        with zipfile.ZipFile(self.job / "article.epub") as archive:
            self.assertEqual("mimetype", archive.infolist()[0].filename)
            self.assertEqual(zipfile.ZIP_STORED, archive.infolist()[0].compress_type)
            self.assertEqual(b"application/epub+zip", archive.read("mimetype"))
            for name in archive.namelist():
                if name.endswith((".xml", ".xhtml", ".opf", ".ncx")):
                    ET.fromstring(archive.read(name))
            package = ET.fromstring(archive.read("OEBPS/content.opf"))
            refs = package.findall("{*}spine/{*}itemref")
            self.assertEqual(["article"], [ref.attrib["idref"] for ref in refs])
            self.assertEqual("ncx", package.find("{*}spine").attrib["toc"])
            article = ET.fromstring(archive.read("OEBPS/article.xhtml"))
            self.assertEqual("きょう", article.find(".//{*}rt").text)
            files = {name: archive.read(name) for name in archive.namelist()}
        manifest = read_json(self.job / "epub.manifest.json")
        self.assertEqual(content_hash(files), manifest["contentSha256"])
        self.assertEqual(sha((self.job / "article.epub").read_bytes()), manifest["sha256"])

    def test_build_is_deterministic_and_all_sentences_resolve(self):
        before = (self.job / "article.epub").read_bytes()
        build(self.job)
        self.assertEqual(before, (self.job / "article.epub").read_bytes())
        sidecar = read_json(self.job / "sentence_translations.json")
        self.assertEqual(["c0s0", "c0s7", "c0s13"], list(sidecar["entries"]))
        for sentence in self.plan["sentences"]:
            entry = sidecar["entries"][sentence["id"]]
            self.assertEqual(len(normalize(sentence["text"])), entry["len"])
            self.assertEqual(sentence["hash"], entry["hash"])
            self.assertTrue(entry["translation"])
            self.assertIn("| Romaji |", entry["explanation"])
            self.assertLess(entry["explanation"].index("Word by word"), entry["explanation"].index("Grammar"))

    def test_missing_particles_repetitions_and_changed_words_are_rejected(self):
        for mutation in (lambda words: words.pop(1), lambda words: words.append(words[0]),
                         lambda words: words.reverse(), lambda words: words[0].update(surface="明日")):
            edited = copy.deepcopy(self.translations)
            mutation(edited["entries"][1]["words"])
            with self.assertRaisesRegex(ValueError, "word table"):
                make_sidecar(self.plan, edited)

    def test_missing_duplicate_or_altered_sentences_and_readings_are_rejected(self):
        for mutation in (lambda t: t["entries"].pop(),
                         lambda t: t["entries"].append(t["entries"][0]),
                         lambda t: t["entries"][0].update(text="別の文"),
                         lambda t: t["entries"][0]["words"][0].update(reading=""),
                         lambda t: t.update(syncId="another-book")):
            edited = copy.deepcopy(self.translations)
            mutation(edited)
            with self.assertRaises(ValueError):
                make_sidecar(self.plan, edited)

    def test_book_and_translation_edits_cannot_upload_stale_artifacts(self):
        original = (self.job / "book/OEBPS/article.xhtml").read_bytes()
        write(self.job / "book/OEBPS/article.xhtml", original + b" ")
        with self.assertRaisesRegex(ValueError, "EPUB changed"):
            validated_uploads(self.job)
        write(self.job / "book/OEBPS/article.xhtml", original)
        self.translations["entries"][0]["translation"] = "The weather news"
        write(self.job / "translations.json", json_bytes(self.translations))
        with self.assertRaisesRegex(ValueError, "stale"):
            validated_uploads(self.job)
        build(self.job)
        validated_uploads(self.job)

    def test_prepare_never_erases_existing_work(self):
        original = (self.job / "translations.json").read_bytes()
        with self.assertRaises(FileExistsError):
            prepare(FIXTURES / "article.json", self.job)
        self.assertEqual(original, (self.job / "translations.json").read_bytes())

    def test_dry_run_never_reads_credentials_or_opens_network(self):
        output = io.StringIO()
        with patch("hoshi_news.credentials", side_effect=AssertionError("credentials accessed")), \
                patch("hoshi_news.KvClient", side_effect=AssertionError("network accessed")), redirect_stdout(output):
            self.assertEqual(0, main(["publish", "--job", str(self.job), "--dry-run", "--env-file", "/missing"]))
        result = json.loads(output.getvalue())
        self.assertEqual("dry-run", result["status"])
        self.assertEqual(4, len(result["requests"]))
        self.assertTrue(result["requests"][-1]["key"].endswith("/epub.manifest"))

    def test_prepare_and_dry_run_cli_errors_are_readable(self):
        job = self.root / "empty"
        output = io.StringIO()
        with redirect_stdout(output):
            self.assertEqual(0, main(["prepare", "--article", str(FIXTURES / "article.json"), "--out", str(job)]))
        with redirect_stderr(output):
            self.assertEqual(1, main(["build", "--job", str(job)]))
        self.assertIn("translation must be a nonempty string", output.getvalue())

    def test_sanitization_removes_active_content_and_preserves_readings(self):
        fragment = sanitize('<p onclick="bad()">2<ruby>日<rt>にち</rt></ruby><script>bad()</script><img src="secret"/></p>')
        tree = ET.fromstring(fragment)
        self.assertEqual({}, tree.attrib)
        self.assertEqual("２日", "".join(s["text"] for s in segment(fragment)))
        self.assertEqual("にち", tree.find("ruby/rt").text)
        self.assertEqual(["ruby"], [child.tag for child in tree])
        with self.assertRaises(ValueError):
            sanitize('<!DOCTYPE root [<!ENTITY a "expansion">]><p>&a;</p>')

    def test_duplicate_json_keys_are_not_silently_accepted(self):
        file = self.root / "bad.json"
        file.write_text('{"title":"a","title":"b"}')
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            read_json(file)

    def test_invalid_plain_text_xml_characters_fail_before_creating_a_job(self):
        article = read_json(FIXTURES / "article.json")
        del article["bodyXhtml"]
        article["paragraphs"] = ["本文\u0000です。"]
        file = self.root / "article.json"
        write(file, json_bytes(article))
        with self.assertRaisesRegex(ValueError, "Invalid XML"):
            prepare(file, self.root / "bad-job")
        self.assertFalse((self.root / "bad-job").exists())

    def test_env_file_is_data_not_shell_and_env_takes_precedence(self):
        env = self.root / "secret.env"
        env.write_text("HOSHI_KV_BASE_URL=https://sync.example/api\nHOSHI_KV_TOKEN='$(touch SHOULD_NOT_EXIST)'\n")
        with patch.dict("os.environ", {}, clear=True):
            self.assertEqual("$(touch SHOULD_NOT_EXIST)", credentials(env)[1])
        with patch.dict("os.environ", {"HOSHI_KV_TOKEN": "override"}, clear=True):
            self.assertEqual("override", credentials(env)[1])


class PublicationTests(FixtureTest):
    def setUp(self):
        super().setUp()
        self.store = sync_server.Store()
        handler = type("TestHandler", (sync_server.Handler,), {
            "store": self.store, "token": "fixture-secret", "max_body": 16 * 1024 * 1024,
            "log_message": lambda *args: None,
        })
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.client = KvClient(f"http://127.0.0.1:{self.server.server_port}", "fixture-secret")
        _, self.uploads = validated_uploads(self.job)

    def test_publish_round_trip_and_noop_retry_preserve_device_metadata(self):
        result = publish(self.client, self.uploads)
        self.assertEqual(4, len(result["uploaded"]))
        for key, _, body in self.uploads:
            self.assertEqual(body, self.client.get(key))
        metadata_key = self.uploads[2][0]
        metadata = json.loads(self.client.get(metadata_key))
        metadata["shelfName"] = "Already read"
        self.client.put(metadata_key, "application/json", json_bytes(metadata))
        result = publish(self.client, self.uploads)
        self.assertEqual([], result["uploaded"])
        self.assertEqual("Already read", json.loads(self.client.get(metadata_key))["shelfName"])

    def test_conflicts_and_tombstones_fail_before_any_write(self):
        for suffix, value in (("metadata", {"deletedAt": "2026-09-22T00:00:00Z"}),
                              ("epub.manifest", {"format": "mokuro"}),
                              ("sentences", {"syncId": "other"})):
            self.store.entries.clear()
            self.store.requests.clear()
            key = self.uploads[0][0].rsplit("/", 1)[0] + "/" + suffix
            self.store.put(key, json_bytes(value), "application/json")
            with self.assertRaises(ValueError):
                publish(self.client, self.uploads)
            self.assertEqual([], [r for r in self.store.requests if r["method"] == "PUT"])

    def test_interrupted_publish_resumes_without_reuploading_finished_keys(self):
        final_key = self.uploads[-1][0]
        self.store.faults.append(dict(pathPrefix="/v1/kv/" + final_key, status=503, method="PUT", count=3, body="temporary"))
        with self.assertRaisesRegex(ValueError, "503"):
            publish(self.client, self.uploads)
        self.assertIsNone(self.client.get(final_key))
        self.assertEqual(3, len(self.store.entries))
        result = publish(self.client, self.uploads)
        self.assertEqual([final_key], result["uploaded"])

    def test_new_translations_need_explicit_replace_and_matching_payload(self):
        publish(self.client, self.uploads)
        self.translations["entries"][0]["translation"] = "The weather news"
        write(self.job / "translations.json", json_bytes(self.translations))
        build(self.job)
        _, uploads = validated_uploads(self.job)
        with self.assertRaisesRegex(ValueError, "Different translations"):
            publish(self.client, uploads)
        self.assertEqual([uploads[1][0]], publish(self.client, uploads, replace_translations=True)["uploaded"])

    def test_auth_errors_do_not_expose_token_or_server_body(self):
        client = KvClient(self.client.base_url, "wrong-private-token")
        with self.assertRaises(ValueError) as raised:
            publish(client, self.uploads)
        self.assertIn("401", str(raised.exception))
        self.assertNotIn("wrong-private-token", str(raised.exception))

    def test_http_is_restricted_to_local_test_servers(self):
        for url in ("http://example.com", "https://secret@example.com", "https://example.com?token=secret"):
            with self.assertRaises(ValueError):
                KvClient(url, "secret")

    def test_redirects_are_not_followed(self):
        calls = []

        class Redirect(BaseHTTPRequestHandler):
            def do_GET(self):
                calls.append(self.path)
                self.send_response(302)
                self.send_header("Location", "/credential-sink")
                self.end_headers()

            def log_message(self, *_):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Redirect)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            with self.assertRaisesRegex(ValueError, "302"):
                KvClient(f"http://127.0.0.1:{server.server_port}", "secret").get("books/id/metadata")
            self.assertEqual(["/v1/kv/books/id/metadata"], calls)
        finally:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    unittest.main()
