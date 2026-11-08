import CryptoKit
import XCTest
@testable import Hoshi_Reader

/// Suspended transport hooks make local edits and remote deletes occur at exact network waits.
nonisolated final class SyncReconcileRaceTests: XCTestCase {
    @MainActor private func prepare() throws -> (books: URL, scratch: URL, cloud: HttpSyncCloudBooks) {
        HttpSyncManager.shared.suspendPolling()
        let books = try BookStorage.getBooksDirectory()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("reconcile-races-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let backup = scratch.appendingPathComponent("saved-books")
        if FileManager.default.fileExists(atPath: books.path) { try FileManager.default.moveItem(at: books, to: backup) }
        try FileManager.default.createDirectory(at: books, withIntermediateDirectories: true)
        addTeardownBlock {
            await MainActor.run {
                try? FileManager.default.removeItem(at: books)
                if FileManager.default.fileExists(atPath: backup.path) { try? FileManager.default.moveItem(at: backup, to: books) }
                try? FileManager.default.removeItem(at: scratch)
            }
        }
        return (books, scratch, HttpSyncCloudBooks(directory: scratch.appendingPathComponent("catalogue")))
    }

    @MainActor private func makeBook(_ id: String, root: URL, version: String = "old") throws -> BookMetadata {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{\"version\":\"\(version)\"}".utf8).write(to: root.appendingPathComponent(FileNames.mokuro))
        let book = BookMetadata(id: UUID(), title: id, cover: nil, folder: root.lastPathComponent,
                                lastAccess: .distantPast, contentType: .mokuro,
                                importedAt: "2026-01-01T00:00:00Z", syncId: id)
        try BookStorage.save(book, inside: root, as: FileNames.metadata)
        return book
    }

    @MainActor private func publish(_ id: String, root: URL, transport: ReconcileRaceKV) async throws -> HttpSyncPayloadManifest {
        _ = try await HttpSyncPayloadCodec().uploadIfChanged(transport: transport, syncId: id, bookRoot: root,
                                                            originalName: id, format: .mokuro)
        let manifest = try await HttpSyncPayloadCodec().fetchManifest(transport: transport,
                                                                       keys: .forFormat(.mokuro, syncId: id))
        return try XCTUnwrap(manifest)
    }

    @MainActor private func metadata(_ id: String, shelf: String? = nil, stamp: String = "2026-02-01T00:00:00Z",
                                    deleted: String? = nil) throws -> Data {
        try JSONEncoder().encode(HttpSyncMetadataBlob(title: id, contentType: .mokuro, shelfName: shelf,
                                                      shelfUpdatedAt: stamp, importedAt: "2026-01-01T00:00:00Z",
                                                      deletedAt: deleted, rev: 1))
    }

    @MainActor private static func move(_ book: BookMetadata, to shelf: String, at stamp: String, books: URL) throws {
        try BookStorage.save([BookShelf(name: shelf, bookIds: [book.id])], inside: books, as: FileNames.shelves)
        var state = HttpSyncShelfStateStore.load()
        state[try XCTUnwrap(book.syncId)] = HttpSyncShelfPlacementRecord(shelfName: shelf, updatedAt: stamp)
        HttpSyncShelfStateStore.save(state)
        _ = HttpSyncRevisionStore.bumpForLocalEdit(SyncKeys.metadata(try XCTUnwrap(book.syncId)))
    }

    @MainActor func testQueuedMangaDeletedWhileEarlierMangaDownloadsCannotResurrect() async throws {
        let env = try prepare(), transport = ReconcileRaceKV()
        for id in ["queue-a", "queue-b"] {
            let source = env.scratch.appendingPathComponent(id)
            _ = try makeBook(id, root: source)
            let manifest = try await publish(id, root: source, transport: transport)
            await transport.seed(SyncKeys.metadata(id), body: try metadata(id))
            env.cloud.recordListed(syncId: id, manifest: manifest, shelfName: nil)
            XCTAssertTrue(env.cloud.requestDownload(syncId: id))
        }
        let tombstone = try metadata("queue-b", deleted: rfc3339(from: Date().addingTimeInterval(-1)))
        await transport.beforeDownload(SyncKeys.payloadZip("queue-a")) {
            await transport.seed(SyncKeys.metadata("queue-b"), body: tombstone)
        }
        let result = await HttpSyncReconciler(transport: transport, cloudBooks: env.cloud).syncOnce(sinceCursor: nil)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        XCTAssertTrue(result.localLibraryChanged, "the first manga was installed")
        XCTAssertEqual(Set(try BookStorage.loadAllBooks().compactMap(\.syncId)), ["queue-a"])
        let downloads = await transport.downloadedKeys()
        XCTAssertFalse(downloads.contains(SyncKeys.payloadZip("queue-b")), "a queued tombstone is checked before downloading")
        let fetched = try await transport.get(key: SyncKeys.metadata("queue-b"))
        let remote = try XCTUnwrap(fetched)
        XCTAssertNotNil(try JSONDecoder().decode(HttpSyncMetadataBlob.self, from: remote.body).deletedAt)
        XCTAssertNil(env.cloud.record(syncId: "queue-b"))
    }

    @MainActor func testTombstonePublishedDuringTransferPreventsInstallation() async throws {
        let env = try prepare(), transport = ReconcileRaceKV(), id = "delete-during-transfer"
        let source = env.scratch.appendingPathComponent("source")
        _ = try makeBook(id, root: source)
        let manifest = try await publish(id, root: source, transport: transport)
        await transport.seed(SyncKeys.metadata(id), body: try metadata(id))
        env.cloud.recordListed(syncId: id, manifest: manifest, shelfName: "Manga")
        XCTAssertTrue(env.cloud.requestDownload(syncId: id))
        let tombstone = try metadata(id, shelf: "Manga", deleted: rfc3339Now())
        await transport.beforeDownload(SyncKeys.payloadZip(id)) {
            await transport.seed(SyncKeys.metadata(id), body: tombstone)
        }
        let result = await HttpSyncReconciler(transport: transport, cloudBooks: env.cloud).syncOnce(sinceCursor: nil)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        XCTAssertFalse(result.localLibraryChanged, "a discarded staged copy never changed the library")
        XCTAssertTrue(try BookStorage.loadAllBooks().isEmpty)
        XCTAssertNil(env.cloud.record(syncId: id))
        XCTAssertTrue((BookStorage.loadShelves() ?? []).allSatisfy { $0.bookIds.isEmpty })
    }

    @MainActor private func checkShelfMoveDuringMetadataGet(number: Int) async throws {
        let env = try prepare(), transport = ReconcileRaceKV(), id = "shelf-race"
        let root = env.books.appendingPathComponent(id)
        let book = try makeBook(id, root: root)
        _ = try await publish(id, root: root, transport: transport)
        try Self.move(book, to: "Old", at: "2026-01-01T00:00:00Z", books: env.books)
        await transport.seed(SyncKeys.metadata(id), body: try metadata(id, shelf: "Remote"))
        await transport.beforeGet(SyncKeys.metadata(id), number: number) {
            try Self.move(book, to: "Local", at: "2030-01-01T00:00:00Z", books: env.books)
            // A different book's hook-created stamp must also survive the whole-map save.
            HttpSyncShelfStateStore.save(["another-book": .init(shelfName: "Other", updatedAt: "2030-01-01T00:00:00Z")])
        }
        let result = await HttpSyncReconciler(transport: transport, cloudBooks: env.cloud).syncOnce(sinceCursor: nil)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        XCTAssertEqual(BookStorage.loadShelves()?.first(where: { $0.bookIds.contains(book.id) })?.name, "Local")
        XCTAssertEqual(HttpSyncShelfStateStore.load()[id], .init(shelfName: "Local", updatedAt: "2030-01-01T00:00:00Z"))
        XCTAssertNotNil(HttpSyncShelfStateStore.load()["another-book"])
        let fetched = try await transport.get(key: SyncKeys.metadata(id))
        let remote = try XCTUnwrap(fetched)
        XCTAssertEqual(try JSONDecoder().decode(HttpSyncMetadataBlob.self, from: remote.body).shelfName, "Local")
    }

    @MainActor func testNewLocalShelfMoveWinsDuringInboundMetadataGet() async throws {
        try await checkShelfMoveDuringMetadataGet(number: 2)
    }

    @MainActor func testNewLocalShelfMoveWinsDuringOutboundMetadataGet() async throws {
        try await checkShelfMoveDuringMetadataGet(number: 3)
    }

    @MainActor func testInvalidatedAccountCannotApplySuspendedMetadataGet() async throws {
        let env = try prepare(), transport = ReconcileRaceKV(), id = "old-account"
        let root = env.books.appendingPathComponent(id)
        let book = try makeBook(id, root: root)
        _ = try await publish(id, root: root, transport: transport)
        try Self.move(book, to: "Local", at: "2026-01-01T00:00:00Z", books: env.books)
        await transport.seed(SyncKeys.metadata(id), body: try metadata(id, shelf: "Old account"))
        let account = ReconcileRaceFlight()
        await transport.beforeGet(SyncKeys.metadata(id), number: 2) { account.current = false }
        let result = await HttpSyncReconciler(transport: transport, cloudBooks: env.cloud,
                                             stillCurrent: { account.current }).syncOnce(sinceCursor: nil)
        XCTAssertTrue(result.errors.isEmpty, "account invalidation is an intentional stop")
        XCTAssertFalse(result.localLibraryChanged)
        XCTAssertNil(result.newLastSyncedAt)
        XCTAssertEqual(BookStorage.loadShelves()?.first(where: { $0.bookIds.contains(book.id) })?.name, "Local")
        XCTAssertEqual(HttpSyncShelfStateStore.load()[id]?.shelfName, "Local")
    }

    @MainActor func testLocalShelfMoveDuringMetadataPutIsImmediatelyRepairedOnServer() async throws {
        let env = try prepare(), transport = ReconcileRaceKV(), id = "shelf-put-race"
        let root = env.books.appendingPathComponent(id)
        var book = try makeBook(id, root: root)
        book.importedAt = "2026-01-02T00:00:00Z"
        try BookStorage.save(book, inside: root, as: FileNames.metadata)
        _ = try await publish(id, root: root, transport: transport)
        await transport.seed(SyncKeys.metadata(id), body: try metadata(id, shelf: "Remote"))
        let movedBook = book
        await transport.beforePut(SyncKeys.metadata(id)) {
            try Self.move(movedBook, to: "Local", at: "2030-01-01T00:00:00Z", books: env.books)
        }
        let result = await HttpSyncReconciler(transport: transport, cloudBooks: env.cloud).syncOnce(sinceCursor: nil)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        let fetched = try await transport.get(key: SyncKeys.metadata(id))
        let remote = try XCTUnwrap(fetched)
        XCTAssertEqual(try JSONDecoder().decode(HttpSyncMetadataBlob.self, from: remote.body).shelfName, "Local")
        XCTAssertEqual(BookStorage.loadShelves()?.first(where: { $0.bookIds.contains(book.id) })?.name, "Local")
        XCTAssertEqual(HttpSyncShelfStateStore.load()[id]?.updatedAt, "2030-01-01T00:00:00Z")
    }

    @MainActor func testStagedReplacementExposesTransferAndStopsWhenCancelled() async throws {
        let env = try prepare(), transport = ReconcileRaceKV(), id = "staged-retry"
        let source = env.scratch.appendingPathComponent("new-source")
        _ = try makeBook(id, root: source, version: "new")
        let manifest = try await publish(id, root: source, transport: transport)
        await transport.seed(SyncKeys.metadata(id), body: try metadata(id))
        env.cloud.recordListed(syncId: id, manifest: manifest, shelfName: nil)
        let staged = env.cloud.stagingRoot(syncId: id)
        _ = try makeBook(id, root: staged)
        _ = try await HttpSyncPayloadCodec().ensurePayloadContentSha(bookRoot: staged)
        XCTAssertTrue(env.cloud.requestDownload(syncId: id))
        let flight = ReconcileRaceFlight()
        await transport.beforeDownload(SyncKeys.payloadZip(id)) {
            XCTAssertEqual(env.cloud.transferringSyncId, id, "the per-item Cancel action identifies this transfer")
            XCTAssertEqual(env.cloud.downloadState(syncId: id), .downloading(0))
            env.cloud.cancelRequest(syncId: id)
            flight.task?.cancel()
        }
        flight.task = Task { await HttpSyncReconciler(transport: transport, cloudBooks: env.cloud).syncOnce(sinceCursor: nil) }
        let result = await flight.task!.value
        XCTAssertFalse(result.localLibraryChanged)
        XCTAssertTrue(try BookStorage.loadAllBooks().isEmpty)
        XCTAssertNil(env.cloud.transferringSyncId)
        XCTAssertEqual(env.cloud.downloadState(syncId: id), .available)
        let cancelled = await transport.cancelledDownloads()
        XCTAssertEqual(cancelled, [SyncKeys.payloadZip(id)])
    }

    @MainActor func testUnchangedFullReconcileDoesNotReportLibraryChange() async throws {
        let env = try prepare(), transport = ReconcileRaceKV(), id = "unchanged"
        let root = env.books.appendingPathComponent(id)
        _ = try makeBook(id, root: root)
        _ = try await publish(id, root: root, transport: transport)
        await transport.seed(SyncKeys.metadata(id), body: try metadata(id))
        let reconciler = HttpSyncReconciler(transport: transport, cloudBooks: env.cloud)
        _ = await reconciler.syncOnce(sinceCursor: nil)
        let result = await reconciler.syncOnce(sinceCursor: nil)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        XCTAssertFalse(result.localLibraryChanged)
        await transport.failListing()
        let failed = await reconciler.syncOnce(sinceCursor: nil)
        XCTAssertFalse(failed.errors.isEmpty)
        XCTAssertFalse(failed.localLibraryChanged)
    }
}

@MainActor private final class ReconcileRaceFlight {
    var task: Task<HttpSyncResult, Never>?
    var current = true
}

private actor ReconcileRaceKV: HttpSyncKvTransport {
    typealias Hook = @MainActor @Sendable () async throws -> Void
    private var bodies: [String: Data] = [:]
    private var getCounts: [String: Int] = [:]
    private var getHooks: [String: (Int, Hook)] = [:]
    private var putHooks: [String: Hook] = [:]
    private var downloadHooks: [String: Hook] = [:]
    private var downloads: [String] = [], cancelled: [String] = []
    private var listingFails = false
    func seed(_ key: String, body: Data) { bodies[key] = body }
    func beforeGet(_ key: String, number: Int, hook: @escaping Hook) { getHooks[key] = (number, hook) }
    func beforeDownload(_ key: String, hook: @escaping Hook) { downloadHooks[key] = hook }
    func beforePut(_ key: String, hook: @escaping Hook) { putHooks[key] = hook }
    func downloadedKeys() -> [String] { downloads }
    func cancelledDownloads() -> [String] { cancelled }
    func failListing() { listingFails = true }
    private func meta(_ key: String) -> HttpSyncKvKeyMeta? {
        bodies[key].map { .init(key: key, lastModified: "2026-03-01T00:00:00Z",
                               etag: "sha256:" + SHA256.hash(data: $0).lowercaseHex, size: $0.count) }
    }
    func get(key: String) async throws -> HttpSyncKvFetched? {
        getCounts[key, default: 0] += 1
        if let (number, hook) = getHooks[key], getCounts[key] == number {
            getHooks[key] = nil
            try await hook()
        }
        return bodies[key].map { .init(body: $0, contentType: "application/json", lastModified: meta(key)!.lastModified, etag: meta(key)!.etag!) }
    }
    func put(key: String, contentType: String, body: Data) async throws -> HttpSyncKvWriteResponse {
        if let hook = putHooks.removeValue(forKey: key) { try await hook() }
        bodies[key] = body
        return meta(key)!
    }
    func putFile(key: String, contentType: String, fileURL: URL) async throws -> HttpSyncKvWriteResponse {
        try await put(key: key, contentType: contentType, body: Data(contentsOf: fileURL))
    }
    func downloadToFile(key: String, targetURL: URL) async throws -> HttpSyncKvFileFetched? {
        downloads.append(key)
        if let hook = downloadHooks.removeValue(forKey: key) { try await hook() }
        do { try Task.checkCancellation() } catch { cancelled.append(key); throw error }
        guard let body = bodies[key], let meta = meta(key) else { return nil }
        try body.write(to: targetURL)
        return .init(contentType: "application/zip", lastModified: meta.lastModified, etag: meta.etag!)
    }
    func list(prefix: String?, since: String?, cursor: String?, limit: Int?) async throws -> HttpSyncKvList {
        if listingFails { throw HttpSyncError("Test listing failure") }
        return HttpSyncKvList(keys: bodies.keys.sorted().filter { prefix == nil || $0.hasPrefix(prefix!) }.compactMap(meta))
    }
    func delete(key: String) async throws { bodies[key] = nil }
}
