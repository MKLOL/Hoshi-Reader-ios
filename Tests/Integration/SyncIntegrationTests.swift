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
            let history = ReadingDay.streakHistory([reading], resetHour: 3)
            let now = ReadingDay.parse("2026-10-01")!.addingTimeInterval(3600)
            XCTAssertEqual(StatisticsMath.streak(history.days, goalMinutes: 10, now: now, resetHour: 3).current, 1)
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
        let settings = HttpSyncSettingsStore.shared
        settings.baseURL = baseURL
        settings.token = token
        settings.lastSyncedAt = nil
        XCTAssertTrue(settings.isConfigured, "settings must accept the loopback test server")
    }

    @MainActor
    private func syncNow(file: StaticString = #filePath, line: UInt = #line) async {
        let manager = HttpSyncManager.shared
        await manager.syncNow()
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
