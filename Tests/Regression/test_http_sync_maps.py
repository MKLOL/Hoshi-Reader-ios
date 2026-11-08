import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


class HttpSyncMapRegressionTests(unittest.TestCase):
    def source(self, relative: str) -> str:
        return (ROOT / relative).read_text()

    def test_uses_existing_kv_maps_without_custom_backend_endpoint(self):
        sources = "\n".join(
            self.source(path)
            for path in (
                "Features/HttpSync/HttpSyncBatchExchange.swift",
                "Features/HttpSync/HttpSyncKv.swift",
                "Features/HttpSync/HttpSyncManager.swift",
            )
        )
        self.assertNotIn("/v2/exchange", sources)
        self.assertIn('httpSyncBooksMapKey = "sync/maps/books.json"', sources)
        self.assertIn('httpSyncBookmarksMapPrefix = "sync/maps/bookmarks/"', sources)
        self.assertIn("bookmarkMapKey(deviceId())", sources)
        self.assertIn("transport.list(prefix: nil", sources)

    def test_bookmarks_batch_on_five_second_timer_and_flush_on_close(self):
        manager = self.source("Features/HttpSync/HttpSyncManager.swift")
        reader = self.source("Features/Reader/ReaderView/ReaderViewModel.swift")
        manga = self.source("Features/MangaReader/MangaReaderView.swift")
        self.assertIn("Task.sleep(for: .seconds(5))", manager)
        self.assertIn("while !Task.isCancelled", manager)
        self.assertIn("onPageTurnPersisted(book: book)", reader)
        self.assertIn("flushBookmarkSync()", manga)
        self.assertIn("await HttpSyncManager.shared.flushBookmarkSync()", reader)
        self.assertIn("await HttpSyncManager.shared.flushBookmarkSync()", manga)

    def test_map_bootstrap_pulls_current_legacy_bookmark_before_reading(self):
        manager = self.source("Features/HttpSync/HttpSyncManager.swift")
        exchange = self.source("Features/HttpSync/HttpSyncBatchExchange.swift")
        loader = self.source("Features/Reader/ReaderView/ReaderViewModel.swift")
        self.assertIn("changes?.needsBootstrap == true", manager)
        self.assertIn("syncLegacyBookmark(book: book", manager)
        self.assertIn("NotificationCenter.default.post", exchange)
        reserve = loader.index("HttpSyncActiveBooks.open(reservedSyncId)")
        gate = loader.index("syncBookmarksBeforeReading(book: book)", reserve)
        parse = loader.index("BookStorage.loadEpub(root)", gate)
        self.assertLess(reserve, gate)
        self.assertLess(gate, parse)

    def test_upgrade_hashes_existing_payload_before_any_replacement(self):
        reconciler = self.source("Features/HttpSync/HttpSyncReconciler.swift")
        adopt = reconciler.index("ensurePayloadContentSha(bookRoot: root)")
        replace = reconciler.index("payloadCodec.installReplacement")
        self.assertLess(adopt, replace)
        self.assertIn("HttpSyncActiveBooks.contains(syncId)", reconciler)

    def test_bookmark_writes_are_race_free_per_install_shards(self):
        exchange = self.source("Features/HttpSync/HttpSyncBatchExchange.swift")
        self.assertIn("Each client only overwrites its", exchange)
        self.assertNotIn("key: httpSyncBookmarksMapKey,", exchange)
        self.assertIn("mergeShards", exchange)
        self.assertNotIn("key: pending.key", exchange)

    def test_map_listing_is_paginated_and_installation_id_is_not_in_books_backup(self):
        exchange = self.source("Features/HttpSync/HttpSyncBatchExchange.swift")
        self.assertIn("limit: 2_000", exchange)
        self.assertIn("page.nextCursor", exchange)
        self.assertIn("UIDevice.current.identifierForVendor", exchange)
        self.assertNotIn("deviceIdFilename", exchange)

    def test_payload_hash_is_verified_from_downloaded_content(self):
        payload = self.source("Features/HttpSync/HttpSyncPayload.swift")
        reconciler = self.source("Features/HttpSync/HttpSyncReconciler.swift")
        # The zip sha256 is the integrity check; the content hash is derived from the verified,
        # unpacked bytes and a manifest that disagrees is repaired, never treated as corruption
        # (the 0.11.3 hash bug made every manifest disagree and every download fail).
        self.assertIn("try Self.contentSha(bookRoot: targetDir)", payload)
        self.assertIn("if manifest.contentSha256 != contentSha {", payload)
        self.assertNotIn("declared != contentSha", payload)
        self.assertIn("publishVerifiedContentSha", payload)
        self.assertIn("hasPayloadContentDirty(bookRoot: root)", reconciler)
        # A cached local hash that disagrees with the server is re-derived from disk before any
        # replacement download.
        self.assertIn("refreshPayloadContentSha(bookRoot: root)", reconciler)
        # The relative path comes from the enumerator, never from character counts of `path()`.
        self.assertIn(".producesRelativePathURLs", payload)
        self.assertNotIn("bookRoot.path(percentEncoded: false).count + 1", payload)

    def test_active_epub_and_manga_readers_reload_remote_bookmarks(self):
        epub = self.source("Features/Reader/ReaderView/ReaderView.swift")
        manga = self.source("Features/MangaReader/MangaReaderView.swift")
        self.assertIn("httpSyncBookmarkApplied", epub)
        self.assertIn("httpSyncBookmarkApplied", manga)
        self.assertIn("reservedSyncId = syncId(for: book)", self.source(
            "Features/Reader/ReaderView/ReaderViewModel.swift"
        ))

    def test_full_reconcile_does_not_block_the_five_second_map_lane(self):
        manager = self.source("Features/HttpSync/HttpSyncManager.swift")
        start = manager.index("private func performMapExchange() async")
        end = manager.index("func onShelfPlacementChanged", start)
        exchange = manager[start:end]
        self.assertIn("beginReconcile(preflight: changes, expectedConfig: config)", exchange)
        self.assertNotIn("await reconcileTask.value", exchange)

    def test_publish_acknowledges_only_the_preflight_etags(self):
        exchange = self.source("Features/HttpSync/HttpSyncBatchExchange.swift")
        start = exchange.index("private func publishMapsLocked(")
        end = exchange.index("func observeLegacyEtags", start)
        publish = exchange[start:end]
        self.assertIn("legacyEtags: acknowledgedLegacyEtags", publish)
        self.assertNotIn("listAllMetadata", publish)
        self.assertIn("observedLegacyEtags: legacyKeyEtags", exchange)
        manager = self.source("Features/HttpSync/HttpSyncManager.swift")
        transport = self.source("Features/HttpSync/HttpSyncKv.swift")
        self.assertIn("expectedLegacyEtags", manager)
        self.assertIn("HttpSyncWriteTrackingTransport", transport)

    def test_interrupted_payload_replacement_is_recovered_on_startup(self):
        payload = self.source("Features/HttpSync/HttpSyncPayload.swift")
        exchange = self.source("Features/HttpSync/HttpSyncBatchExchange.swift")
        self.assertIn(".payload.replacement.target", payload)
        self.assertIn("recoverInterruptedReplacements", payload)
        self.assertIn("recoverInterruptedReplacements(booksDirectory: books)", exchange)
        self.assertIn("recoverInterruptedReplacements(booksDirectory: books)", self.source(
            "App/HoshiReader.swift"
        ))

    def test_replacement_book_info_is_part_of_staged_generation(self):
        reconciler = self.source("Features/HttpSync/HttpSyncReconciler.swift")
        save = reconciler.index("BookStorage.save(replacementBookInfo, inside: staging")
        install = reconciler.index("payloadCodec.installReplacement", save)
        self.assertLess(save, install)


if __name__ == "__main__":
    unittest.main()
