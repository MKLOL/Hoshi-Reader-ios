import SwiftUI
import XCTest
@testable import Hoshi_Reader

/// The production iOS sync stack — `HttpSyncManager`, `HttpSyncReconciler`, the payload codec
/// and `HttpSyncKvClient` — against the real test server over real HTTP, seeded with the corpus
/// the Android client published (`Tests/Fixtures/sync-corpus.json`).
///
/// Run through `Tests/Regression/test_sync_integration.py`, which boots the server and passes
/// `HOSHI_KV_BASE_URL`, `HOSHI_KV_TOKEN` and `HOSHI_SYNC_CORPUS` to the test runner. Every test
/// starts from a wiped local library and a server reset to the corpus, i.e. a brand-new install.
// `nonisolated`: XCTestCase's inherited initializers are nonisolated, so the class cannot be
// main-actor isolated under the project's MainActor default. Every scenario and helper is
// explicitly @MainActor instead, matching HttpSyncManager and BookStorage.
nonisolated final class SyncIntegrationTests: XCTestCase {
    // Mirrors SyncCorpus.kt in the Android repo.
    private static let mangaSyncId = "integration_manga"
    private static let novelSyncId = "integration_novel"
    private static let mangaTitle = "Integration Manga"
    private static let bubbleText = "こんにちは"

    private var baseURL = ""
    private var token = ""
    private var corpus = Data()

    /// Brand-new install against a server reset to the Android-published corpus.
    @MainActor
    private func prepare() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HOSHI_KV_BASE_URL"], let tok = env["HOSHI_KV_TOKEN"], let corpusPath = env["HOSHI_SYNC_CORPUS"] else {
            throw XCTSkip("HOSHI_KV_BASE_URL / HOSHI_KV_TOKEN / HOSHI_SYNC_CORPUS not set — run Tests/Regression/test_sync_integration.py")
        }
        baseURL = url
        token = tok
        corpus = try Data(contentsOf: URL(fileURLWithPath: corpusPath))
        // The host app's five-second foreground poll would add its own listings to the requests
        // these scenarios count; each scenario drives every sync itself.
        await MainActor.run { HttpSyncManager.shared.suspendPolling() }
        try await resetServerToCorpus()
        try wipeLocalInstall()
    }

    // MARK: - Scenarios

    @MainActor
    func testFreshInstallSyncsEverythingAndroidPublished() async throws {
        try await prepare()
        // Android's hashes, read from the fixture BEFORE syncing: the import path corrects a
        // manifest it disagrees with, so a manifest fetched afterwards would only echo this
        // client's own derivation.
        let androidManga = try fixtureManifest(SyncKeys.payloadManifest(Self.mangaSyncId))
        let androidNovel = try fixtureManifest(SyncKeys.epubManifest(Self.novelSyncId))
        try await clearServerRequests()
        await syncNow(downloadManga: false)
        XCTAssertEqual(Set(try BookStorage.loadAllBooks().compactMap(\.syncId)), [Self.novelSyncId])
        XCTAssertNotNil(HttpSyncCloudBooks.shared.record(syncId: Self.mangaSyncId), "remote manga is listed before downloading")
        let initialRequests = try await serverRequests()
        XCTAssertFalse(initialRequests.contains { $0.method == "GET" && $0.path.hasSuffix("/payload.zip") }, "listing never fetches the manga archive")
        XCTAssertTrue(HttpSyncCloudBooks.shared.requestDownload(syncId: Self.mangaSyncId))
        await syncNow()

        let manifestWrites = try await serverRequests().filter { $0.method == "PUT" && $0.path.hasSuffix(".manifest") }
        XCTAssertEqual(manifestWrites.count, 0, "the first sync must accept Android's manifests as-is: \(manifestWrites)")

        let books = try BookStorage.loadAllBooks()
        XCTAssertEqual(Set(books.compactMap(\.syncId)), [Self.mangaSyncId, Self.novelSyncId])

        let manga = try book(Self.mangaSyncId)
        XCTAssertEqual(manga.metadata.resolvedContentType, .mokuro)
        XCTAssertEqual(ContentType.detect(bookDir: manga.root), .mokuro)
        for page in ["images/0001.jpg", "images/0002.jpg", "images/0003.jpg", FileNames.mokuro] {
            XCTAssertTrue(exists(manga.root, page), "\(page) missing after import")
        }
        XCTAssertEqual(BookStorage.loadBookmark(root: manga.root)?.chapterIndex, 2, "Android's bookmark applied")
        XCTAssertEqual(AiChatHistoryStore.shared.load(folder: manga.root.lastPathComponent).entries.map(\.response), ["Hello"])
        XCTAssertTrue(exists(manga.root, FileNames.pretranslations), "offline bubble translations landed")
        XCTAssertNotNil(manga.metadata.cover, "shelf cover resolved")
        try await assertContentHashMatchesAndroid(root: manga.root, android: androidManga, manifestKey: SyncKeys.payloadManifest(Self.mangaSyncId))

        let novel = try book(Self.novelSyncId)
        XCTAssertEqual(ContentType.detect(bookDir: novel.root), .epub)
        XCTAssertNoThrow(try BookStorage.loadEpub(novel.root), "downloaded EPUB parses")
        XCTAssertEqual(BookStorage.loadBookmark(root: novel.root)?.chapterIndex, 1)
        XCTAssertTrue(exists(novel.root, FileNames.sentenceTranslations), "sentence translations landed")
        XCTAssertGreaterThan(BookStorage.loadBookInfo(root: novel.root)?.characterCount ?? 0, 0, "progress derivable before first open")
        XCTAssertNotNil(novel.metadata.cover)
        try await assertContentHashMatchesAndroid(root: novel.root, android: androidNovel, manifestKey: SyncKeys.epubManifest(Self.novelSyncId))
    }

    @MainActor
    func testResyncTransfersNothingAndLeavesTheServerAlone() async throws {
        try await prepare()
        await syncNow()
        let before = try await etags()
        try await clearServerRequests()

        await syncNow()
        await syncNow()

        let requests = try await serverRequests()
        XCTAssertEqual(requests.filter { $0.method == "GET" && ($0.path.hasSuffix(".zip")) }.count, 0, "no payload re-downloads: \(requests)")
        XCTAssertEqual(requests.filter { $0.method == "PUT" && ($0.path.hasSuffix(".zip") || $0.path.hasSuffix(".manifest")) }.count, 0, "no payload/manifest writes: \(requests)")
        XCTAssertEqual(requests.filter { $0.path == "/v1/kv-multipart/start" }.count, 0)
        let after = try await etags()
        for key in before.keys where key.hasSuffix(".zip") || key.hasSuffix(".manifest") || key.hasSuffix("/metadata") {
            XCTAssertEqual(before[key], after[key], "\(key) rewritten by an unchanged resync")
        }
    }

    /// Android encodes a bookmark differently, so the same position has another ETag on the
    /// server, and that ETag can win the tie-break against this device's copy. The position must
    /// still count as applied: re-applying it rewrote the bookmark and announced a move on every
    /// five-second poll.
    @MainActor
    func testUnrelatedRemoteMetadataForcesAFullPassWithoutReloadingTheShelf() async throws {
        try await prepare()
        await syncNow()
        let transport = HttpSyncKvClient(baseURL: baseURL, bearerToken: token)
        _ = try await transport.put(key: "tests/unrelated-metadata", contentType: "application/json", body: Data("{}".utf8))
        var reloads = 0
        let observer = NotificationCenter.default.addObserver(forName: .hoshiLibraryChanged, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { reloads += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        await syncNow()
        XCTAssertEqual(reloads, 0, "unchanged full reconciliation does not rebuild the shelf")
    }

    @MainActor
    func testAndroidEncodedBookmarkIsAppliedOnceNotOnEveryPoll() async throws {
        try await prepare()
        await syncNow()
        let transport = HttpSyncKvClient(baseURL: baseURL, bearerToken: token)
        _ = try await HttpSyncBatchState.shared.syncMaps(transport: transport)
        let roots = try [Self.mangaSyncId, Self.novelSyncId].map { try book($0).root.appendingPathComponent(FileNames.bookmark) }
        func written() throws -> [Date?] { try roots.map { try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate } }
        let before = try written()
        var announced: [String] = []
        let observer = NotificationCenter.default.addObserver(forName: .httpSyncBookmarkApplied, object: nil, queue: nil) { note in
            let id = note.userInfo?["syncId"] as? String ?? "?"
            MainActor.assumeIsolated { announced.append(id) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        try await clearServerRequests()
        for _ in 0..<3 { _ = try await HttpSyncBatchState.shared.syncMaps(transport: transport) }

        XCTAssertEqual(announced, [], "an unchanged position was announced as moved")
        XCTAssertEqual(try written(), before, "an unchanged position was rewritten")
        let requests = try await serverRequests()
        XCTAssertEqual(requests.filter { $0.method != "GET" }.map(\.path), [], "an unchanged position was uploaded")
        XCTAssertEqual(BookStorage.loadBookmark(root: try book(Self.mangaSyncId).root)?.chapterIndex, 2, "still at Android's page")
    }

    @MainActor
    func testBookmarkTurnedOnThisDeviceSurvivesAFreshInstall() async throws {
        try await prepare()
        await syncNow()
        let manga = try book(Self.mangaSyncId)
        let before = try await etags()

        // The reader's page-turn path: persist, queue, flush (the reader-close fast path).
        try BookStorage.save(
            Bookmark(chapterIndex: 7, progress: 0, characterCount: 70, lastModified: Date()),
            inside: manga.root, as: FileNames.bookmark
        )
        HttpSyncManager.shared.onPageTurnPersisted(book: manga.metadata)
        await HttpSyncManager.shared.flushBookmarkSync()
        let afterTurn = try await etags()
        XCTAssertNotEqual(before, afterTurn, "the page turn reached the server")

        // A brand-new install (wiped library, wiped sync state) gets the position back.
        try wipeLocalInstall()
        await syncNow()
        XCTAssertEqual(BookStorage.loadBookmark(root: try book(Self.mangaSyncId).root)?.chapterIndex, 7)
    }

    @MainActor
    func testCorruptManifestContentHashIsRepairedAndNeverBlocksTheImport() async throws {
        try await prepare()
        // The 0.11.3 incident, from the receiving side.
        let key = SyncKeys.payloadManifest(Self.mangaSyncId)
        let client = HttpSyncKvClient(baseURL: baseURL, bearerToken: token)
        let good = try await manifest(key)
        let poisoned = HttpSyncPayloadManifest(
            sha256: good.sha256, sizeBytes: good.sizeBytes, originalName: good.originalName,
            format: good.format, contentSha256: "sha256:" + String(repeating: "0", count: 64)
        )
        _ = try await client.put(key: key, contentType: "application/json; charset=utf-8", body: try JSONEncoder().encode(poisoned))

        await syncNow()

        XCTAssertEqual(Set(try BookStorage.loadAllBooks().compactMap(\.syncId)), [Self.mangaSyncId, Self.novelSyncId], "the import still succeeds")
        let repaired = try await manifest(key)
        XCTAssertEqual(repaired.contentSha256, good.contentSha256, "the manifest is corrected on the server")
        XCTAssertEqual(repaired.sha256, good.sha256, "the archive itself is untouched")
        XCTAssertEqual(HttpSyncPayloadCodec().cachedPayloadSha(bookRoot: try book(Self.mangaSyncId).root), good.contentSha256)
    }

    @MainActor
    func testDeletedOnAnotherDeviceDisappearsHere() async throws {
        try await prepare()
        await syncNow()
        XCTAssertNotNil(try? book(Self.mangaSyncId))

        // Another device's tombstone, in the exact shape the Android client publishes.
        let client = HttpSyncKvClient(baseURL: baseURL, bearerToken: token)
        let metadataKey = SyncKeys.metadata(Self.mangaSyncId)
        guard let fetched = try await client.get(key: metadataKey) else { return XCTFail("metadata missing") }
        var blob = try JSONDecoder().decode(HttpSyncMetadataBlob.self, from: fetched.body)
        blob.deletedAt = rfc3339Now()
        blob.rev = (blob.rev ?? 0) + 1
        _ = try await client.put(key: metadataKey, contentType: "application/json; charset=utf-8", body: try JSONEncoder().encode(blob))

        await syncNow()
        XCTAssertNil(try BookStorage.loadAllBooks().first { $0.syncId == Self.mangaSyncId }, "tombstone applied")
        XCTAssertNotNil(try? book(Self.novelSyncId), "the other book is untouched")
    }

    // MARK: - Local install

    @MainActor
    func testCorruptStatisticsDoNotBlockBookmarkOrSettingsSync() async throws {
        try await prepare()
        await syncNow()
        let manga = try book(Self.mangaSyncId), novel = try book(Self.novelSyncId)
        var row = Statistics.empty(title: "Fixture", day: "2026-09-25", device: .current)
        row.add(seconds: 60, count: 10, stamp: 1)
        try ReadingStatisticsStore.save([row], root: manga.root, scheduleSync: false)
        try ReadingStatisticsStore.save([row], root: novel.root, scheduleSync: false)
        let client = HttpSyncKvClient(baseURL: baseURL, bearerToken: token)
        _ = try await client.put(key: "books/\(Self.mangaSyncId)/statistics", contentType: "application/json", body: Data("{".utf8))
        try BookStorage.save(Bookmark(chapterIndex: 1, progress: 0.9, characterCount: 1234, lastModified: Date()), inside: novel.root, as: FileNames.bookmark)
        let settings = StatisticsSettingsSyncProbe()
        // Use the app's coordinator so automatic bookmark work joins this same reconcile.
        let manager = HttpSyncManager.shared
        let previousSettings = manager.aiSettings
        manager.aiSettings = settings
        defer { manager.aiSettings = previousSettings }
        try await clearServerRequests()
        await manager.syncNow()
        XCTAssertTrue(manager.lastErrors.contains { $0.contains(Self.mangaSyncId) })
        XCTAssertGreaterThan(settings.reads, 0, "translation settings still reach their independent sync phase")
        let requests = try await serverRequests()
        XCTAssertTrue(requests.contains { $0.method == "PUT" && $0.path.contains(httpSyncBookmarksMapPrefix) }, "the changed bookmark still uploads")
        XCTAssertTrue(requests.contains { $0.method == "PUT" && $0.path.hasSuffix("books/\(Self.novelSyncId)/statistics") }, "the other book's statistics still upload")
        XCTAssertFalse(requests.contains { $0.method == "PUT" && $0.path.hasSuffix(httpSyncBooksMapKey) }, "a failed statistics exchange must not acknowledge convergence")
    }

    @MainActor
    func testUnchangedBookMapRecoversMissingReadingAndMangaHistoryWithoutPayloadDownloads() async throws {
        try await prepare()
        let client = HttpSyncKvClient(baseURL: baseURL, bearerToken: token)
        let readingKey = "books/\(Self.mangaSyncId)/statistics"
        let textKey = "books/\(Self.mangaSyncId)/manga_statistics"
        var reading = Statistics.empty(title: Self.mangaTitle, day: "2026-10-01", device: ReadingDevice(id: "phone", name: "Phone"))
        reading.add(seconds: 900, count: 3, stamp: 1)
        reading.readingTimeByHour = ["2026-10-01T01:00": 900]
        let text = MangaTextStatistic(dateKey: "2026-10-01", charactersRead: 120, lastModified: 1, deviceId: "phone", deviceName: "Phone")
        _ = try await client.put(key: readingKey, contentType: "application/json", body: JSONEncoder().encode(ReadingStatisticsBlob(syncId: Self.mangaSyncId, entries: [reading])))
        _ = try await client.put(key: textKey, contentType: "application/json", body: JSONEncoder().encode(MangaStatisticsBlob(syncId: Self.mangaSyncId, entries: [text])))
        await syncNow()
        await syncNow()
        let manga = try book(Self.mangaSyncId)
        XCTAssertEqual(ReadingStatisticsStore.reading(root: manga.root), [reading])
        XCTAssertEqual(ReadingStatisticsStore.text(root: manga.root), [text])

        // Keep the installed book, migration marker and acknowledged map cache. Test both a
        // lost history file and the broken-tablet case where its per-book sync state is gone too.
        for loseSyncState in [false, true] {
            for name in [FileNames.statistics, FileNames.mangaStatistics] {
                try FileManager.default.removeItem(at: manga.root.appendingPathComponent(name))
            }
            if loseSyncState {
                try FileManager.default.removeItem(at: manga.root.appendingPathComponent(HttpReadingStatisticsSync.stateFile))
            }
            try await clearServerRequests()
            await syncNow()
            XCTAssertEqual(ReadingStatisticsStore.reading(root: manga.root), [reading])
            XCTAssertEqual(ReadingStatisticsStore.text(root: manga.root), [text])
            let history = ReadingDay.days(reading: [reading], resetHour: 3)
            let now = ReadingDay.parse("2026-10-01")!.addingTimeInterval(3600)
            XCTAssertEqual(StatisticsMath.streak(history, goalMinutes: 10, now: now, resetHour: 3).current, 1)
            let requests = try await serverRequests().filter { $0.path.hasPrefix("/v1/") }
            XCTAssertEqual(requests.count, 3, "one metadata check and the two missing histories: \(requests)")
            XCTAssertEqual(requests.filter { $0.method == "GET" && ($0.path.hasSuffix(readingKey) || $0.path.hasSuffix(textKey)) }.count, 2)
            XCTAssertFalse(requests.contains { $0.path.hasSuffix(".zip") || $0.path.hasSuffix(".manifest") })

            try await clearServerRequests()
            await syncNow()
            let unchanged = try await serverRequests().filter { $0.path.hasPrefix("/v1/") }
            XCTAssertEqual(unchanged.count, 1, "converged histories add no per-book requests: \(unchanged)")
            XCTAssertEqual(unchanged.first?.method, "GET")
            XCTAssertFalse(unchanged.contains { $0.path.hasPrefix("/v1/kv/") })
        }
    }


    @MainActor func testValidMapsIgnoreCorruptObsoleteLegacyBookmarksDuringMetadataSync() async throws {
        try await prepare(); await syncNow()
        let client = HttpSyncKvClient(baseURL: baseURL, bearerToken: token)
        let key = SyncKeys.bookmark(Self.novelSyncId)
        _ = try await client.put(key: key, contentType: "application/json", body: Data("broken obsolete bookmark".utf8))
        let metadataKey = SyncKeys.metadata(Self.novelSyncId)
        let fetched = try await client.get(key: metadataKey)!
        var metadata = try JSONDecoder().decode(HttpSyncMetadataBlob.self, from: fetched.body)
        metadata.shelfName = "Metadata change"; metadata.shelfUpdatedAt = "2099-01-01T00:00:00Z"
        _ = try await client.put(key: metadataKey, contentType: "application/json", body: JSONEncoder().encode(metadata))
        try await clearServerRequests(); await syncNow()
        XCTAssertTrue(HttpSyncManager.shared.lastErrors.isEmpty, "\(HttpSyncManager.shared.lastErrors)")
        let requests = try await serverRequests()
        XCTAssertFalse(requests.contains { $0.path.hasSuffix(key) && $0.method == "GET" }, "maps replace per-book bookmark exchange after bootstrap")
    }


    @MainActor func testAndroidUsageKeysSyncWithoutPayloadReconcile() async throws {
        try await prepare(); await syncNow()
        let client = HttpSyncKvClient(baseURL: baseURL, bearerToken: token)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/usage/android-day.ndjson.gz")
        let key = HttpUsageLane.prefix + "android/2026-10-04" + HttpUsageLane.suffix
        _ = try await client.put(key: key, contentType: "application/gzip", body: Data(contentsOf: fixture))
        try await clearServerRequests(); await syncNow()
        XCTAssertTrue(HttpSyncManager.shared.lastErrors.isEmpty, "\(HttpSyncManager.shared.lastErrors)")
        let snapshot = await UsageLog.shared.read(now: Date(timeIntervalSince1970: 1791043200))
        XCTAssertEqual(snapshot.events.filter { $0.at == 1791043200000 && $0.term == "猫" }.count, 1)
        let requests = try await serverRequests()
        XCTAssertTrue(requests.contains { $0.method == "GET" && $0.path.hasSuffix(key) })
        XCTAssertFalse(requests.contains { $0.path.hasSuffix(".zip") || $0.path.hasSuffix("/metadata") })
        try await clearServerRequests(); await syncNow()
        let unchanged = try await serverRequests()
        XCTAssertFalse(unchanged.contains { $0.path.hasSuffix(key) })
    }

    @MainActor func testUnreadableReadingDataCannotBlockATappedCloudManga() async throws {
        try await prepare()
        let client = HttpSyncKvClient(baseURL: baseURL, bearerToken: token)
        let chats = try await client.list(prefix: "books/\(Self.mangaSyncId)/chat/", since: nil, cursor: nil, limit: nil)
        let chatKey = try XCTUnwrap(chats.keys.first?.key)
        let fetched = try await client.get(key: chatKey)
        let original = try XCTUnwrap(fetched).body
        _ = try await client.put(key: chatKey, contentType: "application/json", body: Data("broken chat".utf8))
        await syncNow(downloadManga: false)
        let catalogue = HttpSyncCloudBooks.shared
        XCTAssertTrue(catalogue.requestDownload(syncId: Self.mangaSyncId))
        await HttpSyncManager.shared.syncNow()

        // As on Android, only the archive itself can fail a download; its chat is reported.
        XCTAssertTrue(HttpSyncManager.shared.lastErrors.contains { $0.contains(chatKey) }, "\(HttpSyncManager.shared.lastErrors)")
        XCTAssertNil(catalogue.record(syncId: Self.mangaSyncId), "the installed manga leaves the catalogue")
        XCTAssertFalse(catalogue.hiddenInstalledSyncIds.contains(Self.mangaSyncId))
        let manga = try book(Self.mangaSyncId)
        XCTAssertTrue(exists(manga.root, FileNames.mokuro))

        // The repaired chat then reaches the installed copy.
        _ = try await client.put(key: chatKey, contentType: "application/json", body: original)
        await syncNow()
        XCTAssertEqual(AiChatHistoryStore.shared.load(folder: manga.root.lastPathComponent).entries.map(\.response), ["Hello"])
    }

    @MainActor func testAnInstalledMangaLeftWaitingIsShownByTheNextOrdinarySync() async throws {
        try await prepare()
        await syncNow()
        let catalogue = HttpSyncCloudBooks.shared
        XCTAssertNil(catalogue.record(syncId: Self.mangaSyncId))
        // A pass stopped during "Finishing sync…" leaves the installed manga waiting without a request.
        catalogue.recordListed(syncId: Self.mangaSyncId, manifest: try fixtureManifest(SyncKeys.payloadManifest(Self.mangaSyncId)), shelfName: nil)
        catalogue.markAwaitingBookmarkMap(syncId: Self.mangaSyncId)
        XCTAssertTrue(catalogue.hiddenInstalledSyncIds.contains(Self.mangaSyncId))
        XCTAssertFalse(catalogue.hasRequestedDownloads)

        try await clearServerRequests()
        await HttpSyncManager.shared.syncNow()
        XCTAssertEqual(HttpSyncManager.shared.lastErrors, [])
        XCTAssertNil(catalogue.record(syncId: Self.mangaSyncId))
        XCTAssertFalse(catalogue.hiddenInstalledSyncIds.contains(Self.mangaSyncId))
        let requests = try await serverRequests()
        XCTAssertFalse(requests.contains { $0.path.hasSuffix(".zip") }, "showing it transfers no archive")
    }

    /// Two tapped manga, as on a device: one sync works through the queue in tap order, each
    /// manga moving onto the shelf as soon as its own download finishes while the next still
    /// waits, without listing the library again per manga. Neither is ever missing from both Not
    /// downloaded and the shelf; the shelf model reloads only when the app announces a library
    /// change, exactly as `BookshelfView` does.
    @MainActor func testOneSyncDownloadsTappedMangaInTapOrderShowingEachAsItFinishes() async throws {
        try await prepare()
        let second = "integration_manga_two"
        try await publishCopyOfFixtureManga(as: second, title: "Integration Manga Two")
        try await publishCopyOfFixtureManga(as: "integration_manga_three", title: "Integration Manga Three")
        await syncNow(downloadManga: false)
        let catalogue = HttpSyncCloudBooks.shared
        // Tapped in reverse sync-ID order: the queue must follow the taps, not the listing.
        let ids = [second, Self.mangaSyncId]
        for id in ids { XCTAssertEqual(catalogue.downloadState(syncId: id), .available, id) }
        // What one sync costs the rest of the library: a single tapped manga.
        let novelMetadata = "/v1/kv/books/\(Self.novelSyncId)/metadata"
        XCTAssertTrue(catalogue.requestDownload(syncId: "integration_manga_three"))
        try await clearServerRequests()
        await HttpSyncManager.shared.syncNow()
        XCTAssertNil(catalogue.record(syncId: "integration_manga_three"), "a single tap downloads and shows its manga")
        let oneSyncReads = try await serverRequests().filter { $0.method == "GET" && $0.path == novelMetadata }.count
        XCTAssertGreaterThan(oneSyncReads, 0)

        let shelf = BookshelfViewModel()
        shelf.loadBooks()
        func shelved(_ id: String) -> Bool { shelf.books.contains { $0.syncId == id } }
        var timeline: [[String: String]] = []
        func snapshot() -> [String: String] {
            Dictionary(uniqueKeysWithValues: ids.map { id in (id, shelved(id) ? "shelf" : "\(catalogue.downloadState(syncId: id))") })
        }
        let observer = NotificationCenter.default.addObserver(forName: .hoshiLibraryChanged, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { shelf.loadBooks(); timeline.append(snapshot()) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        var missing: [String] = [], samples = 0
        let sampler = Task { @MainActor in
            while !Task.isCancelled {
                samples += 1
                for id in ids where catalogue.record(syncId: id) == nil && !shelved(id) { missing.append(id) }
                try? await Task.sleep(for: .milliseconds(2))
            }
        }

        for id in ids {
            XCTAssertTrue(catalogue.requestDownload(syncId: id))
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(ids.allSatisfy { catalogue.downloadState(syncId: $0) == .queued }, "both show progress at once")
        try await clearServerRequests()
        await HttpSyncManager.shared.syncNow()
        sampler.cancel()

        XCTAssertTrue(ids.allSatisfy(shelved), "one sync downloads the whole queue: \(timeline)")
        XCTAssertTrue(ids.allSatisfy { catalogue.record(syncId: $0) == nil })
        XCTAssertEqual(missing, [], "a manga vanished between Not downloaded and the shelf")
        XCTAssertGreaterThan(samples, 3)
        let firstShown = try XCTUnwrap(timeline.first { $0.values.contains("shelf") }, "\(timeline)")
        XCTAssertEqual(firstShown, [second: "shelf", Self.mangaSyncId: "queued"], "the first tap appears while the next waits: \(timeline)")
        let queueReads = try await serverRequests().filter { $0.method == "GET" && $0.path == novelMetadata }.count
        XCTAssertEqual(queueReads, oneSyncReads, "a queue of two costs the library one sync, not one per manga")
        XCTAssertEqual(HttpSyncManager.shared.lastErrors, [])
        XCTAssertEqual(BookStorage.loadBookmark(root: try book(Self.mangaSyncId).root)?.chapterIndex, 2, "opens at Android's page")
        XCTAssertEqual(try book(second).metadata.title, "Integration Manga Two")
    }

    /// The five-second foreground poll runs while someone scrolls the shelf. With a large, already
    /// synchronized library it must never hold the main thread long enough to drop a frame; a
    /// main-actor heartbeat measures the longest uninterrupted main-thread work across several
    /// real polls, including the first. A poll that finds nothing new must not rewrite any file.
    @MainActor func testForegroundPollNeverStallsTheMainThreadWithALargeLibrary() async throws {
        try await prepare()
        await syncNow()
        let manga = try book(Self.mangaSyncId)
        let books = try BookStorage.getBooksDirectory()
        // Weeks of reading on this device and another per book, as a real library has.
        let device = ReadingDevice.current, days = DateFormatter()
        days.locale = Locale(identifier: "en_US_POSIX"); days.dateFormat = "yyyy-MM-dd"
        for index in 0..<80 {
            let id = "large_library_\(index)", title = "Large Library \(index)"
            let folder = books.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.copyItem(at: manga.root, to: folder)
            let metadata = BookMetadata(id: UUID(), title: title, cover: nil, folder: id, lastAccess: Date(),
                                        contentType: .mokuro, importedAt: manga.metadata.importedAt, syncId: id)
            try BookStorage.save(metadata, inside: folder, as: FileNames.metadata)
            let history = (0..<30).map { day in
                Statistics(title: title, dateKey: days.string(from: Date().addingTimeInterval(Double(-day - index % 7) * 86_400)),
                           charactersRead: 900 + day, readingTime: 600, minReadingSpeed: 0, altMinReadingSpeed: 0, lastReadingSpeed: 0,
                           maxReadingSpeed: 0, lastStatisticModified: 1_700_000_000_000 + day,
                           deviceId: day % 3 == 0 ? "other-device" : device.id, deviceName: day % 3 == 0 ? "Other" : device.name,
                           mangaPageSeconds: [12: 3, 20: 2])
            }
            try BookStorage.save(history, inside: folder, as: FileNames.statistics)
        }
        // Publish the library, then confirm a pass finds nothing left to do: the steady state.
        await syncNow(downloadManga: false)
        await syncNow(downloadManga: false)
        // Three devices with three years of monthly shards exercise the listing work done on
        // EVERY poll, even when none of the shard bodies changed. Accept them before measuring
        // idle polls so this also distinguishes listing cost from first-time HTTP downloads.
        let remote = HttpSyncKvClient(baseURL: baseURL, bearerToken: token)
        for deviceIndex in 0..<3 {
            for index in 0..<36 {
                let month = String(format: "%04d-%02d", 2023 + index / 12, 1 + index % 12)
                let shard = HttpStatisticsShard(deviceId: "scroll-device-\(deviceIndex)", month: month, books: [:])
                _ = try await remote.put(key: "\(HttpStatisticsLane.prefix)\(shard.deviceId)/\(month).json",
                    contentType: "application/json", body: JSONEncoder().encode(shard))
            }
        }
        // Every statistics pass also walks the usage logs. Three other devices each publish a
        // month of day files and a year of compacted months, and this device has a month of
        // its own days: late in a month, that is what a reader with a few devices really has.
        let usageLog = UsageLog.shared
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        func usageLines(_ instants: [Date]) -> Data {
            Data(instants.map { #"{"at":\#(Int64($0.timeIntervalSince1970 * 1000)),"utcOffset":"Z","type":"page-turned"}"# + "\n" }.joined().utf8)
        }
        let usageInstants = (1...30).map { Date().addingTimeInterval(Double(-$0) * 86_400) }
        let usageDays = usageInstants.map { ReadingDay.key($0, calendar: utc) }
        let usagePeers = (0..<3).map { "usage-device-\($0)" }
        try FileManager.default.createDirectory(at: usageLog.directory, withIntermediateDirectories: true)
        // The host's own log is left as it was: a day it already has is neither replaced nor removed.
        var seededDays: [URL] = []
        defer {
            for file in seededDays { try? FileManager.default.removeItem(at: file) }
            for peer in usagePeers { try? FileManager.default.removeItem(at: usageLog.directory.appendingPathComponent("devices").appendingPathComponent(peer)) }
        }
        for (day, instant) in zip(usageDays, usageInstants) {
            let file = usageLog.directory.appendingPathComponent(day + ".ndjson")
            guard !FileManager.default.fileExists(atPath: file.path) else { continue }
            try usageLines([instant]).write(to: file)
            seededDays.append(file)
        }
        var usageMonthDays: [String] = []
        for peer in usagePeers {
            for (day, instant) in zip(usageDays, usageInstants) {
                _ = try await remote.put(key: HttpUsageLane.prefix + peer + "/" + day + HttpUsageLane.suffix,
                    contentType: "application/gzip", body: UsageGzip.compress(usageLines([instant])))
            }
            for month in 1...12 {
                let instants = try (1...28).map { try XCTUnwrap(utc.date(from: DateComponents(year: 2024, month: month, day: $0, hour: 12))) }
                usageMonthDays = instants.map { ReadingDay.key($0, calendar: utc) }
                _ = try await remote.put(key: HttpUsageLane.prefix + peer + "/" + String(format: "2024-%02d", month) + HttpUsageLane.suffix,
                    contentType: "application/gzip", body: UsageGzip.compress(usageLines(instants)))
            }
        }
        await HttpStatisticsLane.shared.refresh(flush: false)
        XCTAssertNil(HttpStatisticsLane.shared.problem)
        for peer in usagePeers {
            XCTAssertTrue(usageLog.hasDeviceDays(usageDays + usageMonthDays, device: peer), "the usage lane must have received \(peer)'s days and months")
        }
        // The shelf draws and makes covers for the 80 books the first pass imported; that one-time
        // work after an import is not what this test measures.
        let settling = await mainThreadStalls { try? await Task.sleep(for: .seconds(3)) }

        let support = try BookStorage.getAppDirectory()
        func modificationTimes() -> [String: Date] {
            var times: [String: Date] = [:]
            let files = FileManager.default.enumerator(at: support, includingPropertiesForKeys: [.contentModificationDateKey])
            while let file = files?.nextObject() as? URL {
                times[file.path] = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            }
            return times
        }
        func ms(_ nanoseconds: UInt64) -> String { String(format: "%.2f ms", Double(nanoseconds) / 1e6) }

        try await clearServerRequests()
        let first = await mainThreadStalls { HttpSyncManager.shared.resumePolling(); try? await Task.sleep(for: .seconds(3)) }
        try await clearServerRequests()
        let filesBefore = modificationTimes()
        let steady = await mainThreadStalls { try? await Task.sleep(for: .seconds(11)) }
        HttpSyncManager.shared.suspendPolling()
        let filesAfter = modificationTimes()
        let requests = try await serverRequests()
        // The statistics pass runs every 30 s while reading and once a minute from the poll.
        let statistics = await mainThreadStalls { await HttpStatisticsLane.shared.refresh(flush: false) }
        // While reading, the reader's saves change one book's history; only that book is read again.
        let reading = books.appendingPathComponent("large_library_7").appendingPathComponent(FileNames.statistics)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: reading.path)
        let readingPass = await mainThreadStalls { await HttpStatisticsLane.shared.refresh(flush: false) }

        let listings = requests.filter { $0.method == "GET" && $0.path.hasPrefix("/v1/kv?") }.count
        print("after importing 80 books: longest main-thread work \(ms(settling.cpu))")
        print("foreground poll: longest main-thread work \(ms(first.cpu)) on the first poll, \(ms(steady.cpu)) over \(listings) more polls, \(ms(statistics.cpu)) in a statistics pass, \(ms(readingPass.cpu)) in one after a book's reading was saved; longest heartbeat gaps \(Int(first.wall * 1000)), \(Int(steady.wall * 1000)), \(Int(statistics.wall * 1000)), \(Int(readingPass.wall * 1000)) ms")
        XCTAssertGreaterThanOrEqual(listings, 2, "the poll ran repeatedly")
        XCTAssertEqual(requests.filter { $0.method != "GET" }.map { "\($0.method) \($0.path)" }, [], "a poll that found nothing new uploaded")
        let rewritten = filesAfter.filter { path, date in filesBefore[path] != date }.keys.map { $0.replacingOccurrences(of: support.path, with: "") }.sorted()
        XCTAssertEqual(rewritten, [], "a poll that found nothing new rewrote files")
        // A frame is 8.3 ms at 120 Hz; a poll must leave nearly all of it to scrolling.
        for (name, stall) in [("the first poll", first), ("a later poll", steady), ("a statistics pass", statistics), ("a statistics pass while reading", readingPass)] {
            XCTAssertLessThan(stall.cpu, 4_000_000, "\(name) ran \(ms(stall.cpu)) on the main thread without a break")
            // Blocking waits (synchronous IPC or IO) use no CPU but still hold the main thread.
            XCTAssertLessThan(stall.wall, 0.1, "\(name) held the main thread for \(Int(stall.wall * 1000)) ms")
        }

        // Render the production shelf and actually animate its UIKit scroll view while the real
        // five-second timer runs. An idle heartbeat alone cannot catch redraw or layout stalls.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let config = UserConfig()
        config.enableSync = false // TTU is unrelated to the configured HTTP transport under test.
        let host = UIHostingController(rootView: AnyView(BookshelfView(pendingImportURL: .constant(nil),
            pendingRemoteImportURL: .constant(nil), pendingLookup: .constant(nil),
            pendingTab: .constant(nil), pendingNewsURL: .constant(nil)).environment(config)))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            HttpSyncManager.shared.suspendPolling()
            host.rootView = AnyView(EmptyView())
            window.isHidden = true
            previousWindow?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .seconds(3))
        try await clearServerRequests()
        HttpSyncManager.shared.resumePolling()
        let shelfFrames = try await animateActualScroll(in: host.view, seconds: 16)
        HttpSyncManager.shared.suspendPolling()
        let scrollingRequests = try await serverRequests()
        let scrollingPolls = scrollingRequests.filter { $0.method == "GET" && $0.path.hasPrefix("/v1/kv?") }.count
        XCTAssertGreaterThanOrEqual(scrollingPolls, 3, "real polls must overlap rendered shelf scrolling")
        XCTAssertFalse(scrollingRequests.contains { $0.method != "GET" }, "idle scrolling polls must not upload")
        print("rendered shelf scrolling: \(scrollingPolls) real polls, \(shelfFrames.frames) display callbacks, \(Int(shelfFrames.distance)) points travelled, longest display gap \(Int(shelfFrames.gap * 1000)) ms")

        // A peer may publish a substantial causal journal between polls. Exercise the changed
        // position lane through that same real timer while the production shelf keeps moving.
        let positionTime = Date().timeIntervalSinceReferenceDate + 60
        let seen = Dictionary(uniqueKeysWithValues: (0..<128).map { ("peer-\($0)", Int64(1)) })
        let events = (1...512).map { sequence in
            ReadingPositionEvent(id: "scroll-event-\(sequence)", deviceId: "scroll-position", deviceName: "Scroll peer",
                originId: "scroll-origin", sequence: Int64(sequence), sessionId: "scroll-session", action: "pageTurn",
                from: nil, position: ReadingPosition(chapterIndex: 1, progress: 0.5, characterCount: sequence),
                occurredAt: positionTime + Double(sequence) / 1000, compatibilityAt: positionTime + Double(sequence) / 1000,
                basedOn: sequence == 1 ? nil : "scroll-event-\(sequence - 1)", seen: seen, missingTimestamp: false, bookId: "large_library_7")
        }
        let journal = ReadingPositionJournal(bookId: "large_library_7", deviceId: "scroll-position", events: events, heads: [try XCTUnwrap(events.last)])
        let positionBody = try JSONEncoder().encode(journal)
        XCTAssertLessThan(positionBody.count, 2 * 1024 * 1024)
        let positionKey = ReadingPositionProtocol.prefix + "large_library_7/scroll-position.json"
        _ = try await remote.put(key: positionKey, contentType: "application/json", body: positionBody)
        try await clearServerRequests()
        HttpSyncManager.shared.resumePolling()
        let positionFrames = try await animateActualScroll(in: host.view, seconds: 12)
        HttpSyncManager.shared.suspendPolling()
        let positionRequests = try await serverRequests()
        XCTAssertTrue(positionRequests.contains { $0.method == "GET" && $0.path.hasSuffix(positionKey) }, "the foreground poll must fetch the changed position")
        XCTAssertEqual(BookStorage.loadBookmark(root: books.appendingPathComponent("large_library_7"))?.chapterIndex, 1)
        XCTAssertEqual(ReadingPositionRepository.shared.snapshot(bookId: "large_library_7").heads["scroll-origin"]?.id, "scroll-event-512")
        print("rendered shelf scrolling during \(positionBody.count)-byte position import: \(positionFrames.frames) display callbacks, longest display gap \(Int(positionFrames.gap * 1000)) ms")

        // A changed month is a different workload: decode/merge 2,400 remote rows across all
        // 80 books while the visible Statistics screen is scrolling and receives save notices.
        host.rootView = AnyView(NavigationStack { StatisticsOverviewView().environment(config) })
        try await Task.sleep(for: .seconds(4))
        let statisticsReadyDeadline = ProcessInfo.processInfo.systemUptime + 20
        while (actualScrollView(in: host.view)?.contentSize.height ?? 0) < 2500,
              ProcessInfo.processInfo.systemUptime < statisticsReadyDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThan(try XCTUnwrap(actualScrollView(in: host.view)).contentSize.height, 2500,
            "the Statistics screen must finish loading the large library before measuring")
        try await Task.sleep(for: .seconds(1))
        var changedBooks: [String: HttpStatisticsShardBook] = [:]
        for index in 0..<80 {
            let id = "large_library_\(index)", title = "Large Library \(index)"
            let rows = (1...30).map { day in
                var row = Statistics.empty(title: title, day: String(format: "2026-10-%02d", day),
                    device: ReadingDevice(id: "scroll-remote", name: "Scrolling remote"))
                row.readingTime = 123; row.charactersRead = 900; row.lastStatisticModified = 1_799_000_000_000 + day
                return row
            }
            changedBooks[id] = HttpStatisticsShardBook(title: title, contentType: "mokuro", reading: rows)
        }
        let changed = HttpStatisticsShard(deviceId: "scroll-remote", month: "2026-10", books: changedBooks)
        var incomingCompleted = false
        let incoming = Task { @MainActor in
            _ = try await remote.put(key: "\(HttpStatisticsLane.prefix)scroll-remote/2026-10.json",
                contentType: "application/json", body: JSONEncoder().encode(changed))
            await HttpStatisticsLane.shared.refresh(flush: false)
            incomingCompleted = true
        }
        let statisticsFrames = try await animateActualScroll(in: host.view, seconds: 12, until: { incomingCompleted })
        XCTAssertTrue(incomingCompleted, "the changed month must finish during the scrolling measurement")
        try await incoming.value
        for index in 0..<80 {
            let root = books.appendingPathComponent("large_library_\(index)")
            XCTAssertEqual(ReadingStatisticsStore.reading(root: root).filter { $0.deviceId == "scroll-remote" }.count, 30,
                "the changed month must really be applied while scrolling")
        }
        XCTAssertNil(HttpStatisticsLane.shared.problem)
        print("rendered Statistics scrolling during complete 2,400-row import: \(Int(statisticsFrames.seconds)) seconds, \(statisticsFrames.frames) display callbacks, \(Int(statisticsFrames.distance)) points travelled, longest display gap \(Int(statisticsFrames.gap * 1000)) ms")
        host.rootView = AnyView(EmptyView())

        // Exercise the reader's real synchronous turn path against the same 80-book map and
        // 30-day history, including statistics, the position journal and the durable outbox.
        let readingBook = try book("large_library_7")
        let reader = MangaReaderViewModel(metadata: readingBook.metadata)
        let controller = MangaWebViewController()
        HttpSyncActiveBooks.open("large_library_7")
        defer {
            reader.suspendStatistics()
            reader.usage?.close()
            reader.cancelPreload()
            HttpSyncActiveBooks.close("large_library_7")
        }
        await reader.load(controller: controller, userConfig: config)
        XCTAssertTrue(reader.isReady, reader.errorMessage ?? "manga did not load")
        XCTAssertGreaterThan(reader.pageCount, 1)
        reader.goToPage(0)
        if reader.statistics?.isTracking != true { reader.toggleStatisticsTracking() }
        let statisticsOrigin = reader.statisticsOrigin
        let ownStatistics = expectation(forNotification: .readingStatisticsChanged, object: nil) { note in
            note.object as? URL == readingBook.root && note.userInfo?["origin"] as? UUID == statisticsOrigin
        }
        ownStatistics.expectedFulfillmentCount = 2 // OCR counts and reading-time rows.
        let startCPU = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let startWall = ProcessInfo.processInfo.systemUptime
        reader.navigate(.forward)
        let turnCPU = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - startCPU
        let turnWall = ProcessInfo.processInfo.systemUptime - startWall
        let turnWallMilliseconds = String(format: "%.2f", turnWall * 1000)
        print("manga page turn with 80 books: \(ms(turnCPU)) main-thread CPU, \(turnWallMilliseconds) ms wall")
        XCTAssertLessThan(turnCPU, 8_000_000, "a page turn ran \(ms(turnCPU)) on the main thread")
        XCTAssertLessThan(turnWall, 0.1, "a page turn blocked the main thread for \(turnWall) seconds")
        XCTAssertEqual(reader.pageIndex, 1)
        XCTAssertEqual(BookStorage.loadBookmark(root: readingBook.root)?.chapterIndex, 1, "the turn is durable before rendering or awaiting sync")
        await fulfillment(of: [ownStatistics], timeout: 1)
        reader.flushPendingBookmark()
        reader.suspendStatistics()
        reader.usage?.close()
        await HttpSyncManager.shared.flushBookmarkSync()
        // A fresh repository has no decoded cache: restore from the committed journal bytes.
        let durable = ReadingPositionRepository(directory: ReadingPositionRepository.shared.directory,
            device: ReadingPositionRepository.shared.device)
        XCTAssertEqual(durable.open(bookId: "large_library_7", root: readingBook.root).initialBookmark?.chapterIndex, 1)
        XCTAssertEqual(BookStorage.loadBookmark(root: readingBook.root)?.chapterIndex, 1, "close and sync cannot roll back the last page")
    }

    @MainActor private func actualScrollView(in parent: UIView) -> UIScrollView? {
        if let scroll = parent as? UIScrollView, scroll.bounds.height > 0,
           scroll.contentSize.height > scroll.bounds.height + 100 { return scroll }
        for child in parent.subviews { if let found = actualScrollView(in: child) { return found } }
        return nil
    }

    @MainActor private func animateActualScroll(in view: UIView, seconds: TimeInterval, until completed: (@MainActor () -> Bool)? = nil) async throws -> (frames: Int, distance: CGFloat, gap: TimeInterval, seconds: TimeInterval) {
        view.layoutIfNeeded()
        let scroll = try XCTUnwrap(actualScrollView(in: view), "the real screen must have scrollable content")
        let probe = RenderedScrollProbe(scroll: scroll)
        let display = CADisplayLink(target: probe, selector: #selector(RenderedScrollProbe.frame(_:)))
        display.add(to: .main, forMode: .common)
        defer { display.invalidate(); scroll.setContentOffset(scroll.contentOffset, animated: false) }
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + seconds, maximum = started + max(seconds, 60)
        var down = true
        while (ProcessInfo.processInfo.systemUptime < deadline || completed?() == false),
              ProcessInfo.processInfo.systemUptime < maximum {
            let top = -scroll.adjustedContentInset.top
            let bottom = max(top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            // Repeated native animations produce real content movement and layout, with the
            // common-mode display link sampling the screen throughout each five-second poll.
            scroll.setContentOffset(CGPoint(x: 0, y: down ? min(bottom, top + 1600) : top), animated: true)
            down.toggle()
            try await Task.sleep(for: .milliseconds(650))
        }
        XCTAssertGreaterThan(probe.frames, Int(seconds * 20), "display callbacks must run throughout the measurement")
        XCTAssertGreaterThan(probe.distance, 3000, "the production scroll view must actually move")
        XCTAssertLessThan(probe.longestGap, 0.1, "rendering froze for \(Int(probe.longestGap * 1000)) ms while scrolling")
        return (probe.frames, probe.distance, probe.longestGap, ProcessInfo.processInfo.systemUptime - started)
    }

    /// The longest main-thread CPU time between two heartbeats while `work` runs: work that ran
    /// without giving the main thread a chance to draw a frame. Unlike the wall-clock gap, which
    /// is also returned, it does not grow when the host is busy.
    @MainActor private func mainThreadStalls(during work: () async -> Void) async -> (cpu: UInt64, wall: TimeInterval) {
        var cpu: UInt64 = 0, wall: TimeInterval = 0
        var lastCPU = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID), lastWall = ProcessInfo.processInfo.systemUptime
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                let nowCPU = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID), nowWall = ProcessInfo.processInfo.systemUptime
                cpu = max(cpu, nowCPU - lastCPU); wall = max(wall, nowWall - lastWall)
                lastCPU = nowCPU; lastWall = nowWall
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        await work()
        heartbeat.cancel()
        _ = await heartbeat.value
        return (cpu, wall)
    }

    /// Publishes the fixture's manga again under another sync ID, as a second device would.
    @MainActor private func publishCopyOfFixtureManga(as syncId: String, title: String) async throws {
        let client = HttpSyncKvClient(baseURL: baseURL, bearerToken: token)
        for name in ["payload.zip", "payload.manifest", "bookmark", "metadata"] {
            let response = try await client.get(key: "books/\(Self.mangaSyncId)/\(name)")
            let fetched = try XCTUnwrap(response)
            var body = fetched.body
            if name == "metadata" {
                var metadata = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
                metadata["title"] = title
                body = try JSONSerialization.data(withJSONObject: metadata)
            }
            let type = name.hasSuffix(".zip") ? "application/zip" : "application/json; charset=utf-8"
            _ = try await client.put(key: "books/\(syncId)/\(name)", contentType: type, body: body)
        }
        let mapKey = httpSyncBooksMapKey
        let mapResponse = try await client.get(key: mapKey)
        let fetchedMap = try XCTUnwrap(mapResponse)
        var map = try JSONDecoder().decode([String: String].self, from: fetchedMap.body)
        map[syncId] = map[Self.mangaSyncId]
        _ = try await client.put(key: mapKey, contentType: "application/json; charset=utf-8", body: JSONEncoder().encode(map))
    }

    private struct LocalBook {
        let metadata: BookMetadata
        let root: URL
    }

    @MainActor
    private func book(_ syncId: String) throws -> LocalBook {
        let books = try BookStorage.loadAllBooks()
        guard let metadata = books.first(where: { $0.syncId == syncId }), let folder = metadata.folder else {
            throw NSError(domain: "SyncIntegrationTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "no local book with syncId \(syncId); have \(books.compactMap(\.syncId))"])
        }
        return LocalBook(metadata: metadata, root: try BookStorage.getBooksDirectory().appendingPathComponent(folder, isDirectory: true))
    }

    @MainActor
    private func exists(_ root: URL, _ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path(percentEncoded: false))
    }

    /// A brand-new install: no books, no sync sidecars, no cursor, server address configured.
    @MainActor
    private func wipeLocalInstall() throws {
        let books = try BookStorage.getBooksDirectory()
        if FileManager.default.fileExists(atPath: books.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: books)
        }
        try FileManager.default.createDirectory(at: books, withIntermediateDirectories: true)
        // Position journals live outside the library; a fresh install has none of them either.
        ReadingPositionRepository.shared.removeAllHistory()
        let settings = HttpSyncSettingsStore.shared
        settings.baseURL = baseURL
        settings.token = token
        settings.lastSyncedAt = nil
        HttpSyncCloudBooks.shared.activateScope(config: settings.currentConfig())
        HttpSyncCloudBooks.shared.retain(syncIds: [])
        XCTAssertTrue(settings.isConfigured, "settings must accept the loopback test server")
    }

    @MainActor
    private func syncNow(downloadManga: Bool = true, file: StaticString = #filePath, line: UInt = #line) async {
        let manager = HttpSyncManager.shared
        await manager.syncNow()
        if downloadManga, HttpSyncCloudBooks.shared.record(syncId: Self.mangaSyncId) != nil {
            _ = HttpSyncCloudBooks.shared.requestDownload(syncId: Self.mangaSyncId)
            await manager.syncNow()
        }
        XCTAssertEqual(manager.lastErrors, [], "sync errors", file: file, line: line)
    }

    /// `android` is the manifest the fixture holds, i.e. what the Android client published; the
    /// server's copy after a sync would already carry whatever this client wrote back.
    @MainActor
    private func assertContentHashMatchesAndroid(root: URL, android: HttpSyncPayloadManifest, manifestKey: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        XCTAssertNotNil(android.contentSha256, "the fixture manifest carries Android's content hash", file: file, line: line)
        let recomputed = try HttpSyncPayloadCodec.contentSha(bookRoot: root)
        XCTAssertEqual(recomputed, android.contentSha256, "iOS hash of the unpacked book must equal Android's manifest hash", file: file, line: line)
        XCTAssertEqual(HttpSyncPayloadCodec().cachedPayloadSha(bookRoot: root), android.contentSha256, "cached baseline", file: file, line: line)
        XCTAssertEqual(HttpSyncPayloadCodec().cachedZipSha(bookRoot: root), android.sha256, "archive baseline", file: file, line: line)
        let remote = try await manifest(manifestKey)
        XCTAssertEqual(remote, android, "the server still holds exactly what Android published", file: file, line: line)
    }

    /// A manifest exactly as the fixture (the Android-published server snapshot) stores it.
    private func fixtureManifest(_ key: String) throws -> HttpSyncPayloadManifest {
        let snapshot = try JSONDecoder().decode(FixtureSnapshot.self, from: corpus)
        guard let entry = snapshot.entries.first(where: { $0.key == key }), let body = Data(base64Encoded: entry.body) else {
            throw NSError(domain: "SyncIntegrationTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "\(key) missing from the fixture"])
        }
        return try JSONDecoder().decode(HttpSyncPayloadManifest.self, from: body)
    }

    private struct FixtureEntry: Decodable { let key: String; let body: String }
    private struct FixtureSnapshot: Decodable { let entries: [FixtureEntry] }

    // MARK: - Server access (production client for the API, plain URLSession for test hooks)

    private struct RecordedRequest: Decodable {
        let method: String
        let path: String
        let status: Int
    }

    private struct RequestLog: Decodable { let requests: [RecordedRequest] }
    private struct DumpEntry: Decodable { let key: String; let etag: String }
    private struct Dump: Decodable { let entries: [DumpEntry] }

    @MainActor
    private func manifest(_ key: String) async throws -> HttpSyncPayloadManifest {
        let client = HttpSyncKvClient(baseURL: baseURL, bearerToken: token)
        guard let fetched = try await client.get(key: key) else { throw NSError(domain: "SyncIntegrationTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(key) missing"]) }
        return try JSONDecoder().decode(HttpSyncPayloadManifest.self, from: fetched.body)
    }

    @MainActor
    private func resetServerToCorpus() async throws {
        _ = try await hitTestRoute("POST", "/_test/reset")
        _ = try await hitTestRoute("POST", "/_test/load", body: corpus)
    }

    @MainActor
    private func clearServerRequests() async throws {
        _ = try await hitTestRoute("POST", "/_test/requests/clear")
    }

    @MainActor
    private func serverRequests() async throws -> [RecordedRequest] {
        try JSONDecoder().decode(RequestLog.self, from: try await hitTestRoute("GET", "/_test/requests")).requests
    }

    @MainActor
    private func etags() async throws -> [String: String] {
        let dump = try JSONDecoder().decode(Dump.self, from: try await hitTestRoute("GET", "/_test/dump"))
        return Dictionary(uniqueKeysWithValues: dump.entries.map { ($0.key, $0.etag) })
    }

    @MainActor
    private func hitTestRoute(_ method: String, _ path: String, body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: URL(string: baseURL + path)!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw NSError(domain: "SyncIntegrationTests", code: status, userInfo: [NSLocalizedDescriptionKey: "\(method) \(path) -> \(status): \(String(data: data, encoding: .utf8) ?? "")"])
        }
        return data
    }
}

@MainActor private final class StatisticsSettingsSyncProbe: AiSettingsSyncing {
    var reads = 0
    func currentBlob() -> HttpSyncAiChatSettingsBlob? { reads += 1; return nil }
    func applyFromSync(model: String, promptText: String, imagePromptText: String, remoteLastEditedAt: String) -> Bool { false }
}

@MainActor private final class RenderedScrollProbe: NSObject {
    let scroll: UIScrollView
    var frames = 0
    var distance: CGFloat = 0
    var longestGap: TimeInterval = 0
    private var previousTime: TimeInterval?
    private var previousOffset: CGFloat
    init(scroll: UIScrollView) { self.scroll = scroll; previousOffset = scroll.contentOffset.y }
    @objc func frame(_ display: CADisplayLink) {
        let now = ProcessInfo.processInfo.systemUptime
        if let previousTime { longestGap = max(longestGap, now - previousTime) }
        distance += abs(scroll.contentOffset.y - previousOffset)
        previousTime = now; previousOffset = scroll.contentOffset.y; frames += 1
    }
}
