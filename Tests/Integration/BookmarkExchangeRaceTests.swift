import XCTest
@testable import Hoshi_Reader

nonisolated final class BookmarkExchangeRaceTests: XCTestCase {
    @MainActor private func fixture() throws -> (URL, BookMetadata) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let book = BookMetadata(title: "Bookmark race", cover: nil, folder: "book", lastAccess: .now, syncId: "race")
        let root = directory.appendingPathComponent("book")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try BookStorage.save(book, inside: root, as: FileNames.metadata)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (directory, book)
    }

    @MainActor private func save(_ page: Int, book: BookMetadata, directory: URL) throws {
        try BookStorage.save(Bookmark(chapterIndex: page, progress: 0, characterCount: page,
            lastModified: Date(timeIntervalSince1970: 1_800_000_000 + Double(page))),
            inside: directory.appendingPathComponent(book.folder!), as: FileNames.bookmark)
    }

    @MainActor func testSaveDuringSuspendedScanStaysPendingUntilItsExactPageIsUploaded() async throws {
        let (directory, book) = try fixture(), gate = BookmarkRaceGate(), kv = BookmarkRaceKV()
        let exchange = HttpSyncBatchState(booksDirectory: directory, scanLibrary: { directory in
            let snapshot = await HttpSyncLocalLibrary.scan(booksDirectory: directory)
            await gate.pauseOnce()
            return snapshot
        })
        try save(1, book: book, directory: directory)
        exchange.queueBookmark(book: book)
        let running = Task { try await exchange.syncMaps(transport: kv, scope: "account") }
        await gate.waitUntilPaused()
        try save(2, book: book, directory: directory)
        exchange.queueBookmark(book: book)
        await gate.release()
        _ = try await running.value
        XCTAssertTrue(exchange.hasPending, "the newer mutation was absent from this upload")
        let first = try await kv.uploadedPage()
        XCTAssertEqual(first, 1)
        _ = try await exchange.syncMaps(transport: kv, scope: "account")
        XCTAssertFalse(exchange.hasPending)
        let final = try await kv.uploadedPage()
        XCTAssertEqual(final, 2)
        let reopened = HttpSyncBatchState(booksDirectory: directory)
        XCTAssertFalse(reopened.hasPending)
    }

    @MainActor func testAccountSwitchDuringRemoteMapGetCannotApplyOrAcknowledgeOldAccount() async throws {
        let (directory, book) = try fixture(), gate = BookmarkRaceGate(), kv = BookmarkRaceKV()
        try save(1, book: book, directory: directory)
        let exchange = HttpSyncBatchState(booksDirectory: directory)
        exchange.queueBookmark(book: book)
        let pending = exchange.pendingGeneration
        await kv.suspendGet(gate)
        var current = true
        let running = Task { try await exchange.syncMaps(transport: kv, scope: "old", stillCurrent: { current }) }
        await gate.waitUntilPaused()
        current = false
        await gate.release()
        do { _ = try await running.value; XCTFail("old-account exchange completed") }
        catch is CancellationError { }
        XCTAssertEqual(exchange.pendingGeneration, pending)
        XCTAssertEqual(BookStorage.loadBookmark(root: directory.appendingPathComponent("book"))?.chapterIndex, 1)
        let writes = await kv.writes
        XCTAssertTrue(writes.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".http_sync_exchange_cache.json").path))
        _ = try await exchange.syncMaps(transport: BookmarkRaceKV(), scope: "new")
        XCTAssertFalse(exchange.hasPending)
    }

    @MainActor func testAccountSwitchDuringUploadLeavesOutboxUnacknowledged() async throws {
        let (directory, book) = try fixture(), gate = BookmarkRaceGate(), kv = BookmarkRaceKV()
        try save(1, book: book, directory: directory)
        let exchange = HttpSyncBatchState(booksDirectory: directory)
        exchange.queueBookmark(book: book)
        let pending = exchange.pendingGeneration
        await kv.suspendPut(gate)
        var current = true
        let running = Task { try await exchange.syncMaps(transport: kv, scope: "old", stillCurrent: { current }) }
        await gate.waitUntilPaused()
        current = false
        await gate.release()
        do { _ = try await running.value; XCTFail("old-account upload acknowledged") }
        catch is CancellationError { }
        XCTAssertEqual(exchange.pendingGeneration, pending)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".http_sync_exchange_cache.json").path))
    }
}

private actor BookmarkRaceGate {
    private var paused = false
    private var used = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func pauseOnce() async {
        guard !used else { return }; used = true; paused = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            for waiter in waiters { waiter.resume() }; waiters = []
        }
    }
    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { continuation?.resume(); continuation = nil }
}

private actor BookmarkRaceKV: HttpSyncKvTransport {
    var bodies: [String: Data] = [httpSyncBooksMapKey: Data("{}".utf8), httpSyncBookmarksMapPrefix + "remote.json": Data("{}".utf8)]
    var writes: [String] = []
    private var getGate: BookmarkRaceGate?
    private var putGate: BookmarkRaceGate?
    func suspendGet(_ gate: BookmarkRaceGate) { getGate = gate }
    func suspendPut(_ gate: BookmarkRaceGate) { putGate = gate }
    func uploadedPage() throws -> Int? {
        guard let key = writes.last, let data = bodies[key] else { return nil }
        return try JSONDecoder().decode([String: HttpSyncBookmarkMapEntry].self, from: data)["race"]?.value?.chapterIndex
    }
    func put(key: String, contentType: String, body: Data) async throws -> HttpSyncKvWriteResponse {
        if let gate = putGate { putGate = nil; await gate.pauseOnce() }
        bodies[key] = body; writes.append(key)
        return .init(key: key, lastModified: "2026-11-08T00:00:00Z", etag: "write-\(writes.count)", size: body.count)
    }
    func get(key: String) async throws -> HttpSyncKvFetched? {
        if let gate = getGate { getGate = nil; await gate.pauseOnce() }
        return bodies[key].map { .init(body: $0, contentType: "application/json", lastModified: "", etag: "etag-\(key)") }
    }
    func putFile(key: String, contentType: String, fileURL: URL) async throws -> HttpSyncKvWriteResponse {
        try await put(key: key, contentType: contentType, body: Data(contentsOf: fileURL))
    }
    func downloadToFile(key: String, targetURL: URL) async throws -> HttpSyncKvFileFetched? { nil }
    func list(prefix: String?, since: String?, cursor: String?, limit: Int?) async throws -> HttpSyncKvList {
        .init(keys: bodies.map { .init(key: $0.key, lastModified: "", etag: "etag-\($0.key)", size: $0.value.count) })
    }
    func delete(key: String) async throws { bodies[key] = nil }
}
