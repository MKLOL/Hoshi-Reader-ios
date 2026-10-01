import XCTest
@testable import Hoshi_Reader

nonisolated final class HttpSyncTransferTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testTransferSpeedUsesNewBytesAndResetsOnRetryOrNewFile() {
        var meter = HttpSyncTransferMeter()
        XCTAssertNil(meter.update(.init(key: "a", uploading: false, completed: 2_000_000, total: 8_000_000), now: 10).bytesPerSecond)
        let progress = meter.update(.init(key: "a", uploading: false, completed: 3_000_000, total: 8_000_000), now: 12)
        XCTAssertEqual(progress.bytesPerSecond, 500_000)
        XCTAssertEqual(progress.remainingSeconds, 10)
        XCTAssertEqual(progress.fraction, 0.375)
        XCTAssertTrue(progress.label.contains("0.50 MB/s"))
        XCTAssertNil(meter.update(.init(key: "a", uploading: false, completed: 0, total: 8_000_000), now: 13).bytesPerSecond)
        XCTAssertNil(meter.update(.init(key: "b", uploading: true, completed: 1, total: -1), now: 14).fraction)
    }
    func testCheckpointRestoresOnlyForSameAccountAndDestination() throws {
        let destination = try temporaryDirectory().appendingPathComponent("payload.zip")
        var request = URLRequest(url: URL(string: "https://example.com/v1/kv/book.zip")!)
        request.setValue("Bearer first", forHTTPHeaderField: "Authorization")
        let record = HttpSyncDownloadRecord(request: request, destination: destination)
        try record.prepare()
        try record.saveResumeData(Data("opaque native checkpoint".utf8))
        let restored = try XCTUnwrap(HttpSyncDownloadRecord(description: record.description))
        XCTAssertEqual(restored, record)
        let reordered = try JSONSerialization.data(withJSONObject: ["destination": destination.absoluteString,
            "identity": record.identity, "url": record.url], options: [.sortedKeys])
        XCTAssertTrue(record.matches(description: String(decoding: reordered, as: UTF8.self)),
            "task restoration compares semantic identity across different JSON encoder key orders")
        XCTAssertEqual(restored.resumeData, Data("opaque native checkpoint".utf8))
        XCTAssertFalse(record.description.contains("Bearer first"))
        request.setValue("Bearer second", forHTTPHeaderField: "Authorization")
        let switched = HttpSyncDownloadRecord(request: request, destination: destination)
        XCTAssertNil(switched.resumeData)
        try switched.prepare()
        XCTAssertNil(record.resumeData)
        XCTAssertNil(switched.resumeData)
        try record.saveResumeData(Data("late old-account checkpoint".utf8))
        XCTAssertNil(switched.resumeData)
        try switched.saveResumeData(Data("new checkpoint".utf8))
        record.discard()
        XCTAssertEqual(switched.resumeData, Data("new checkpoint".utf8))
        let staged = destination.appendingPathExtension("staged")
        try Data("old-account archive".utf8).write(to: staged)
        XCTAssertThrowsError(try record.install(staged: staged,
            fetched: .init(contentType: "application/zip", lastModified: "", etag: "old")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(switched.resumeData, Data("new checkpoint".utf8))
    }
    func testCleanupOnlyRemovesExpiredInactiveOwnedDirectories() throws {
        let books = try temporaryDirectory(), cache = HttpSyncDownloadCache()
        let old = cache.directory(books: books, key: "book", archiveSHA: "old")
        let current = cache.directory(books: books, key: "book", archiveSHA: "new")
        let active = cache.directory(books: books, key: "active", archiveSHA: "hash")
        let restored = cache.directory(books: books, key: "restored", archiveSHA: "hash")
        let now = Date(), stale = now.addingTimeInterval(-2 * HttpSyncDownloadCache.retention)
        for entry in [old, active, restored] { try cache.acquire(entry, now: stale); cache.release(entry) }
        try Data(repeating: 7, count: 128).write(to: old.appendingPathComponent("payload.zip"))
        try FileManager.default.setAttributes([.modificationDate: stale], ofItemAtPath: old.path)
        try cache.acquire(current, now: now); cache.release(current)
        try cache.acquire(active, now: stale)
        let unknown = old.deletingLastPathComponent().appendingPathComponent("unrelated")
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: true)
        XCTAssertEqual(cache.summary(books: books, excluding: [restored]).count, 2)
        XCTAssertEqual(cache.summary(books: books, excluding: [restored]).bytes, 128)
        XCTAssertEqual(cache.clean(books: books, olderThan: now.addingTimeInterval(-HttpSyncDownloadCache.retention), excluding: [restored]), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        for entry in [current, active, restored, unknown] { XCTAssertTrue(FileManager.default.fileExists(atPath: entry.path)) }
        cache.release(active)
    }
    @MainActor func testURLDraftRemainsEditableAndCursorBelongsToConfiguration() throws {
        let suite = "HttpSyncTransferTests-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = HttpSyncSettingsStore(defaults: defaults)
        settings.baseURL = "https://"
        XCTAssertEqual(settings.baseURL, "https://")
        settings.baseURL = "https://one.example/"
        let original = settings.currentConfig()
        settings.lastSyncedAt = "2026-09-30T00:00:00Z"
        settings.baseURL = "https://two.example/"
        XCTAssertNil(settings.lastSyncedAt)
        settings.recordCursor("2026-10-01T00:00:00Z", for: original)
        XCTAssertNil(settings.lastSyncedAt)
        settings.recordCursor("2026-10-01T00:00:00Z", for: settings.currentConfig())
        XCTAssertNotNil(settings.lastSyncedAt)
    }
    func testLANEndpointsDoNotRequirePublicInternetOrPlaintextPublicServers() {
        for value in ["http://192.168.1.2:9000", "http://10.2.3.4", "http://172.31.2.3", "http://reader.local", "http://[fd00::1]", "http://127.0.0.1"] {
            XCTAssertTrue(HttpSyncSettingsStore.isSecureBaseURL(value), value)
        }
        for value in ["http://example.com", "http://172.32.2.3", "http://10.fake.1.2.3", "file:///tmp/x"] {
            XCTAssertFalse(HttpSyncSettingsStore.isSecureBaseURL(value), value)
        }
    }

    // Uses the production background URLSession, its delegate and Foundation's real opaque
    // resume checkpoint, against the same HTTP server as the cross-platform integration suite.
    @MainActor func testNativeBackgroundDownloadCancelsResumesAndPreservesExactBytes() async throws {
        let (base, token) = try environment()
        let data = Data((0..<(2 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0) })
        let key = "tests/transfer-\(UUID()).zip"
        let client = HttpSyncKvClient(baseURL: base, bearerToken: token)
        _ = try await client.put(key: key, contentType: "application/zip", body: data)
        try await control(base: base, token: token, path: "/_test/download_next", body: ["pathPrefix": "/v1/kv/" + key, "chunkDelay": 0.04])
        let target = try temporaryDirectory().appendingPathComponent("payload.zip")
        var request = URLRequest(url: URL(string: base + "/v1/kv/" + key)!)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let began = expectation(description: "native delegate receives actual network bytes")
        let once = TransferSignal()
        let task = Task {
            try await HttpSyncBackgroundDownloads.shared.download(request, to: target) { written, _ in
                if written >= 128 * 1024, once.first() { began.fulfill() }
            }
        }
        await fulfillment(of: [began], timeout: 20)
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled transfer succeeded") }
        catch is CancellationError {} catch { XCTFail("unexpected cancellation: \(error)") }
        let record = HttpSyncDownloadRecord(request: request, destination: target)
        XCTAssertNotNil(record.resumeData, "Foundation checkpoint persisted for next sync")
        let result = try await HttpSyncBackgroundDownloads.shared.download(request, to: target) { _, _ in }
        XCTAssertNotNil(result)
        XCTAssertEqual(try Data(contentsOf: target), data)
        XCTAssertNil(record.resumeData, "completed download retires checkpoint")
        let requests = try await logs(base: base, token: token)
        XCTAssertTrue(requests.contains { ($0["path"] as? String) == "/v1/kv/" + key && ($0["range"] as? String)?.hasPrefix("bytes=") == true }, "resume must request remaining HTTP bytes")
    }
    @MainActor func testTruncatedBackgroundDownloadRecoversWithoutInstallingPartialData() async throws {
        let (base, token) = try environment()
        let client = HttpSyncKvClient(baseURL: base, bearerToken: token)
        let data = Data(repeating: 37, count: 512 * 1024), key = "tests/retry-\(UUID()).zip"
        _ = try await client.put(key: key, contentType: "application/zip", body: data)
        try await control(base: base, token: token, path: "/_test/download_next", body: ["pathPrefix": "/v1/kv/" + key, "disconnectAfter": 65536])
        let target = try temporaryDirectory().appendingPathComponent("payload.zip")
        let result = try await client.downloadToFile(key: key, targetURL: target)
        XCTAssertNotNil(result)
        XCTAssertEqual(try Data(contentsOf: target), data)
    }
    @MainActor func testRateLimitedBackgroundDownloadUsesTheSharedRetryGate() async throws {
        let (base, token) = try environment()
        let client = HttpSyncKvClient(baseURL: base, bearerToken: token)
        let key = "tests/limited-" + UUID().uuidString, body = Data("whole archive".utf8)
        _ = try await client.put(key: key, contentType: "application/zip", body: body)
        try await control(base: base, token: token, path: "/_test/fail_next", body: ["pathPrefix": "/v1/kv/" + key, "method": "GET", "status": 429])
        let target = try temporaryDirectory().appendingPathComponent("payload.zip")
        let fetched = try await client.downloadToFile(key: key, targetURL: target)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(try Data(contentsOf: target), body)
        let attempts = try await logs(base: base, token: token).filter { ($0["path"] as? String) == "/v1/kv/" + key && ($0["method"] as? String) == "GET" }
        XCTAssertEqual(attempts.compactMap { $0["status"] as? Int }, [429, 200])
    }
    @MainActor func testCompletedBackgroundArchiveSurvivesReconcileRestartWithoutAnotherDownload() async throws {
        let (base, token) = try environment()
        let corpusPath = try XCTUnwrap(ProcessInfo.processInfo.environment["HOSHI_SYNC_CORPUS"])
        let corpus = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: corpusPath))) as! [String: Any]
        let entries = corpus["entries"] as! [[String: Any]]
        func fixture(_ suffix: String) throws -> Data {
            let entry = try XCTUnwrap(entries.first { ($0["key"] as? String) == "books/integration_manga/" + suffix })
            return try XCTUnwrap(Data(base64Encoded: entry["body"] as! String))
        }
        let zip = try fixture("payload.zip"), manifestData = try fixture("payload.manifest")
        let manifest = try JSONDecoder().decode(HttpSyncPayloadManifest.self, from: manifestData)
        let id = "cached-" + UUID().uuidString, keys = HttpSyncPayloadKeys.forFormat(.mokuro, syncId: id)
        let client = HttpSyncKvClient(baseURL: base, bearerToken: token)
        _ = try await client.put(key: keys.zip, contentType: "application/zip", body: zip)
        _ = try await client.put(key: keys.manifest, contentType: "application/json", body: manifestData)
        let books = try temporaryDirectory(), target = books.appendingPathComponent("installed")
        let checkpoint = HttpSyncDownloadCache.shared.directory(books: books, key: keys.zip, archiveSHA: manifest.sha256)
        let downloaded = try await client.downloadToFile(key: keys.zip, targetURL: checkpoint.appendingPathComponent("payload.zip"))
        XCTAssertNotNil(downloaded)
        // Model process termination after native completion but before the old reconciler installs it.
        try await client.delete(key: keys.zip)
        let before = try await logs(base: base, token: token).filter { ($0["path"] as? String) == "/v1/kv/" + keys.zip && ($0["method"] as? String) == "GET" }.count
        _ = try await HttpSyncPayloadCodec().downloadAndUnpack(transport: client, syncId: id, keys: keys, expectedFormat: .mokuro, targetDir: target)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("mokuro.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpoint.path))
        let after = try await logs(base: base, token: token).filter { ($0["path"] as? String) == "/v1/kv/" + keys.zip && ($0["method"] as? String) == "GET" }.count
        XCTAssertEqual(after, before)
    }
    func testPayloadReplacementDiscardsStaleCoverButKeepsReadingState() throws {
        let parent = try temporaryDirectory(), book = parent.appendingPathComponent("book"), staging = parent.appendingPathComponent("staged")
        for folder in [book, staging] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data("old cover".utf8).write(to: book.appendingPathComponent(FileNames.generatedCover))
        try Data("bookmark".utf8).write(to: book.appendingPathComponent("bookmark.json"))
        try Data("new page".utf8).write(to: staging.appendingPathComponent("page.txt"))
        try HttpSyncPayloadCodec().installReplacement(bookRoot: book, stagingRoot: staging, sha: "sha256:" + String(repeating: "a", count: 64))
        XCTAssertFalse(FileManager.default.fileExists(atPath: book.appendingPathComponent(FileNames.generatedCover).path))
        XCTAssertEqual(try String(contentsOf: book.appendingPathComponent("bookmark.json"), encoding: .utf8), "bookmark")
        XCTAssertEqual(try String(contentsOf: book.appendingPathComponent("page.txt"), encoding: .utf8), "new page")
    }
    private func environment() throws -> (String, String) {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["HOSHI_KV_BASE_URL"], let token = env["HOSHI_KV_TOKEN"] else {
            throw XCTSkip("Run through Tests/Regression/test_sync_integration.py with the real HTTP server")
        }
        return (base, token)
    }
    private func control(base: String, token: String, path: String, body: [String: Any]) async throws {
        var request = URLRequest(url: URL(string: base + path)!)
        request.httpMethod = "POST"; request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }
    private func logs(base: String, token: String) async throws -> [[String: Any]] {
        var request = URLRequest(url: URL(string: base + "/_test/requests")!)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (body, _) = try await URLSession.shared.data(for: request)
        return (try JSONSerialization.jsonObject(with: body) as? [String: Any])?["requests"] as? [[String: Any]] ?? []
    }
}
nonisolated private final class TransferSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var sent = false
    func first() -> Bool { lock.withLock { if sent { return false }; sent = true; return true } }
}
