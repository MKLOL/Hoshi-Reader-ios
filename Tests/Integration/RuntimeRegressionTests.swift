import XCTest
@testable import Hoshi_Reader

nonisolated final class RuntimeRegressionTests: XCTestCase {
    func testDenseProgressSamplesKeepStartsCompletionRetriesAndBoundUIWork() {
        let throttle = HttpSyncProgressThrottle()
        var updates = 0
        for byte in 0...10_000 {
            if throttle.shouldPublish(.init(key: "book", uploading: false, completed: Int64(byte), total: 10_000),
                                      now: Double(byte) / 10_000) { updates += 1 }
        }
        XCTAssertLessThanOrEqual(updates, 12)
        XCTAssertTrue(throttle.shouldPublish(.init(key: "book", uploading: false, completed: 0, total: 10_000), now: 1.001))
        XCTAssertTrue(throttle.shouldPublish(.init(key: "next", uploading: false, completed: 0, total: 10_000), now: 1.002))
        XCTAssertTrue(throttle.shouldPublish(.init(key: "next", uploading: false, completed: 10_000, total: 10_000), now: 1.003))
        XCTAssertFalse(throttle.shouldPublish(.init(key: "next", uploading: false, completed: 10_000, total: 10_000), now: 1.004))
    }

    @MainActor func testRepeatedPodcastValidationLeavesMarkerUntouchedAndCanRevalidate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = PodcastFiles(root: root), account = String(repeating: "a", count: 64)
        files.validatedAccount = account
        let marker = root.appendingPathComponent("validated-account")
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: fixed], ofItemAtPath: marker.path)
        files.validatedAccount = account
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: marker.path)[.modificationDate] as? Date, fixed)
        XCTAssertEqual(files.validatedAccount, account)
        files.validatedAccount = nil
        XCTAssertNil(files.validatedAccount)
        files.validatedAccount = account
        XCTAssertEqual(files.validatedAccount, account)
    }

    @MainActor func testReturningToTheSameEndpointInvalidatesOldConnectionSnapshots() {
        let suite = "ConnectionGeneration.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = HttpSyncSettingsStore(defaults: defaults)
        settings.baseURL = "https://first.example"
        let first = settings.currentConfig().generation
        settings.baseURL = "https://second.example"
        settings.baseURL = "https://first.example"
        XCTAssertGreaterThan(settings.currentConfig().generation, first)
    }

    @MainActor func testAbsentCoversBackOffButNewArchivesAndLaterBackfillRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HttpSyncCloudBooks(directory: root), kv = MissingCoverKV()
        let first = HttpSyncPayloadManifest(sha256: "sha256:" + String(repeating: "a", count: 64), sizeBytes: 10, originalName: "book.cbz", format: .mokuro)
        store.recordListed(syncId: "book", manifest: first, shelfName: nil)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        await store.fetchMissingCovers(transport: kv, now: now)
        await store.fetchMissingCovers(transport: kv, now: now.addingTimeInterval(1))
        var count = await kv.gets
        XCTAssertEqual(count, 1)
        await store.fetchMissingCovers(transport: kv, now: now.addingTimeInterval(301))
        count = await kv.gets
        XCTAssertEqual(count, 2, "a later server backfill remains discoverable")
        let second = HttpSyncPayloadManifest(sha256: "sha256:" + String(repeating: "b", count: 64), sizeBytes: 10, originalName: "book.cbz", format: .mokuro)
        store.recordListed(syncId: "book", manifest: second, shelfName: nil)
        await store.fetchMissingCovers(transport: kv, now: now.addingTimeInterval(302))
        count = await kv.gets
        XCTAssertEqual(count, 3, "a changed archive bypasses old negative cache")
        store.activateScope(config: .init(baseURL: "https://example.test", token: "changed"))
        store.recordListed(syncId: "book", manifest: second, shelfName: nil)
        await store.fetchMissingCovers(transport: kv, now: now.addingTimeInterval(303))
        count = await kv.gets
        XCTAssertEqual(count, 4, "another account never inherits negative cache")
    }
}

private actor MissingCoverKV: HttpSyncKvTransport {
    var gets = 0
    func get(key: String) async throws -> HttpSyncKvFetched? { gets += 1; return nil }
    func put(key: String, contentType: String, body: Data) async throws -> HttpSyncKvWriteResponse { throw URLError(.unsupportedURL) }
    func putFile(key: String, contentType: String, fileURL: URL) async throws -> HttpSyncKvWriteResponse { throw URLError(.unsupportedURL) }
    func downloadToFile(key: String, targetURL: URL) async throws -> HttpSyncKvFileFetched? { nil }
    func list(prefix: String?, since: String?, cursor: String?, limit: Int?) async throws -> HttpSyncKvList { .init(keys: []) }
    func delete(key: String) async throws { }
}
