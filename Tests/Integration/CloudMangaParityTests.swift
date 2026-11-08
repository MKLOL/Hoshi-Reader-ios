import XCTest
import UIKit
@testable import Hoshi_Reader

nonisolated final class CloudMangaParityTests: XCTestCase {
    @MainActor private func makeStore() -> HttpSyncCloudBooks {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-manga-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return HttpSyncCloudBooks(directory: directory)
    }

    private var manifest: HttpSyncPayloadManifest {
        .init(sha256: "sha256:" + String(repeating: "a", count: 64), sizeBytes: 123_456,
              originalName: "Cloud Manga", format: .mokuro, contentSha256: "sha256:" + String(repeating: "b", count: 64))
    }

    @MainActor func testListingDoesNotCreateInstalledBookAndRequestsSurviveReload() throws {
        let store = makeStore()
        XCTAssertTrue(store.recordListed(syncId: "cloud", manifest: manifest, shelfName: "Manga"))
        XCTAssertFalse(store.recordListed(syncId: "cloud", manifest: manifest, shelfName: "Manga"))
        XCTAssertFalse(store.hasRequestedDownloads)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.stagingRoot(syncId: "cloud").path))
        XCTAssertTrue(store.requestDownload(syncId: "cloud"))
        let request = store.record(syncId: "cloud")?.downloadRequestedAt
        store.reload()
        XCTAssertEqual(store.record(syncId: "cloud")?.downloadRequestedAt, request)
        XCTAssertTrue(store.hasRequestedDownloads)
        store.cancelRequest(syncId: "cloud")
        store.reload()
        XCTAssertFalse(store.hasRequestedDownloads)
    }

    @MainActor func testMapCompletionControlsRevealAndFailureCanBeRetried() {
        let store = makeStore()
        store.recordListed(syncId: "cloud", manifest: manifest, shelfName: nil)
        XCTAssertTrue(store.requestDownload(syncId: "cloud"))
        store.failDownload(syncId: "cloud", message: "payload cloud: unreachable")
        XCTAssertEqual(store.hiddenInstalledSyncIds, ["cloud"])
        XCTAssertEqual(store.record(syncId: "cloud")?.downloadError, "payload cloud: unreachable")
        XCTAssertFalse(store.hasRequestedDownloads)
        XCTAssertTrue(store.requestDownload(syncId: "cloud"))
        XCTAssertNil(store.record(syncId: "cloud")?.downloadError)
        store.markAwaitingBookmarkMap(syncId: "cloud")
        XCTAssertEqual(store.hiddenInstalledSyncIds, ["cloud"])
        // Only an exchange that started after the install may show it.
        store.reveal([])
        XCTAssertEqual(store.readySyncIds, ["cloud"])
        store.reveal(["cloud"])
        XCTAssertNil(store.record(syncId: "cloud"))
        XCTAssertTrue(store.hiddenInstalledSyncIds.isEmpty)
    }

    @MainActor func testRemovedRemoteBookCannotKeepItsRequestOrStagingFiles() throws {
        let store = makeStore()
        store.recordListed(syncId: "deleted", manifest: manifest, shelfName: nil)
        XCTAssertTrue(store.requestDownload(syncId: "deleted"))
        let stage = store.stagingRoot(syncId: "deleted")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: stage.appendingPathComponent("part"))
        store.retain(syncIds: [])
        store.reload()
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertFalse(store.requestDownload(syncId: "deleted"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
    }

    @MainActor func testAccountScopeIsolatesCloudRequestsAndCovers() {
        let store = makeStore()
        let first = HttpSyncConfig(baseURL: "https://example.com", token: "test-first")
        let second = HttpSyncConfig(baseURL: "https://example.com", token: "test-second")
        store.activateScope(config: first)
        store.recordListed(syncId: "cloud", manifest: manifest, shelfName: nil)
        XCTAssertTrue(store.requestDownload(syncId: "cloud"))
        let originalGeneration = store.generation
        store.activateScope(config: second)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertFalse(store.hasRequestedDownloads)
        XCTAssertGreaterThan(store.generation, originalGeneration)
        store.activateScope(config: first)
        XCTAssertEqual(store.requestedSyncIds, ["cloud"])
    }

    @MainActor func testCatalogueOpensInItsAccountScopeBeforeAnySync() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-manga-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let config = HttpSyncConfig(baseURL: "https://example.com", token: "test-scope")
        let previous = HttpSyncCloudBooks(directory: directory)
        previous.activateScope(config: config)
        previous.recordListed(syncId: "cloud", manifest: manifest, shelfName: nil)
        XCTAssertTrue(previous.requestDownload(syncId: "cloud"))
        previous.markAwaitingBookmarkMap(syncId: "cloud")
        // A cold launch: the shelf loads before any sync or foreground activation.
        XCTAssertEqual(HttpSyncCloudBooks(directory: directory, scope: config).hiddenInstalledSyncIds, ["cloud"])
        XCTAssertTrue(HttpSyncCloudBooks(directory: directory).hiddenInstalledSyncIds.isEmpty, "only the scoped catalogue knows it")
    }

    @MainActor func testOnlyTheArchiveInTransferCountsAsTransferring() {
        let store = makeStore()
        store.recordListed(syncId: "cloud", manifest: manifest, shelfName: nil)
        XCTAssertTrue(store.requestDownload(syncId: "cloud"))
        store.beginDownload(syncId: "cloud")
        XCTAssertEqual(store.transferringSyncId, "cloud")
        store.endTransfer(syncId: "other")
        XCTAssertEqual(store.transferringSyncId, "cloud")
        store.endTransfer(syncId: "cloud")
        XCTAssertNil(store.transferringSyncId, "an unpacked archive waiting for install is no longer transferring")
        XCTAssertNotNil(store.downloads["cloud"])
    }

    @MainActor func testCancellingOneWaitingDownloadKeepsTheOthers() {
        // The host app's foreground poll must not start a pass during this check.
        HttpSyncManager.shared.suspendPolling()
        let catalogue = HttpSyncCloudBooks.shared
        let ids: Set<String> = ["cancel-test-a", "cancel-test-b"]
        defer { catalogue.retain(syncIds: Set(catalogue.records.map(\.syncId)).subtracting(ids)) }
        for id in ids {
            catalogue.recordListed(syncId: id, manifest: manifest, shelfName: nil)
            XCTAssertTrue(catalogue.requestDownload(syncId: id))
        }
        XCTAssertFalse(HttpSyncManager.shared.isSyncing)
        HttpSyncManager.shared.cancelCloudBookDownload(syncId: "cancel-test-a")
        XCTAssertNil(catalogue.record(syncId: "cancel-test-a")?.downloadRequestedAt)
        XCTAssertNotNil(catalogue.record(syncId: "cancel-test-b")?.downloadRequestedAt, "another tapped manga still downloads")
    }

    @MainActor func testTransferProgressOnlyBelongsToRequestedMangaDownload() {
        let store = makeStore()
        store.recordListed(syncId: "cloud", manifest: manifest, shelfName: nil)
        _ = store.requestDownload(syncId: "cloud")
        store.updateTransfer(.init(key: "books/cloud/payload.zip", uploading: false, completed: 25, total: 100))
        XCTAssertEqual(store.downloads["cloud"], 0.25)
        store.updateTransfer(.init(key: "books/cloud/payload.zip", uploading: true, completed: 90, total: 100))
        XCTAssertEqual(store.downloads["cloud"], 0.25)
        store.withdrawRequests()
        store.updateTransfer(.init(key: "books/cloud/payload.zip", uploading: false, completed: 80, total: 100))
        XCTAssertNil(store.downloads["cloud"])
    }

    func testCoverThumbnailRejectsInvalidDataAndBoundsImageSize() throws {
        XCTAssertNil(HttpSyncCloudBooks.thumbnail(Data("invalid".utf8)))
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2000, height: 1000))
        let input = renderer.jpegData(withCompressionQuality: 0.9) { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2000, height: 1000))
        }
        let image = try XCTUnwrap(UIImage(data: XCTUnwrap(HttpSyncCloudBooks.thumbnail(input))))
        XCTAssertEqual(image.size.width, 768)
        XCTAssertEqual(image.size.height, 384)
    }
}
