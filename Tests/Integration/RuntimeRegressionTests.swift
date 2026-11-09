import XCTest
import UIKit
import WebKit
@testable import Hoshi_Reader

nonisolated final class RuntimeRegressionTests: XCTestCase {
    @MainActor func testMangaSchemeProxyRoutesLateStopsToOriginalReceiverAndRetiresCompletedTasks() {
        let proxy = MangaImageSchemeProxy(), webView = WKWebView(frame: .zero)
        var original: MangaSchemeReceiverFixture? = MangaSchemeReceiverFixture()
        weak var releasedOriginal = original
        let next = MangaSchemeReceiverFixture(), pending = MangaSchemeTaskFixture(), completed = MangaSchemeTaskFixture()
        proxy.receiver = original
        proxy.webView(webView, start: pending)
        proxy.receiver = next
        proxy.webView(webView, stop: pending)
        XCTAssertEqual(original?.starts, 1)
        XCTAssertEqual(original?.stops, 1, "a prior reader's cancellation must reach its original coordinator")
        XCTAssertEqual(next.stops, 0)

        proxy.receiver = original
        proxy.webView(webView, start: completed)
        proxy.complete(completed)
        proxy.receiver = next
        proxy.webView(webView, stop: completed)
        XCTAssertEqual(original?.starts, 2)
        XCTAssertEqual(original?.stops, 1, "terminal completion retires routing even if WebKit later sends stop")
        XCTAssertEqual(next.stops, 0)
        original = nil
        XCTAssertNil(releasedOriginal, "the reusable configuration cannot retain the previous coordinator")
    }

    @MainActor func testMangaWebViewPoolReusesCleanViewsAndKeepsActiveReadersIndependent() {
        let pool = MangaWebViewPreloader()
        defer { pool.discardIdle() }
        pool.warmup()
        let first = pool.take()
        var previousReader: MangaSchemeReceiverFixture? = MangaSchemeReceiverFixture()
        weak var releasedReader = previousReader
        var arrows = 0
        first.schemeHandler.receiver = previousReader
        first.webView.onArrowLeft = { arrows += 1 }
        first.webView.onArrowRight = { arrows += 1 }
        first.webView.navigationDelegate = previousReader
        first.webView.uiDelegate = previousReader
        first.webView.scrollView.delegate = previousReader
        first.webView.configuration.userContentController.add(previousReader!, name: "previousReader")
        first.webView.configuration.userContentController.addUserScript(WKUserScript(
            source: "window.previousReader = true", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        pool.discardIdle()
        XCTAssertTrue(first.schemeHandler.receiver === previousReader)
        first.webView.onArrowLeft?()
        XCTAssertEqual(arrows, 1, "discarding the idle pool must not dismantle a checked-out reader")

        pool.recycle(first)
        previousReader = nil
        XCTAssertNil(releasedReader, "script handlers must not retain a closed reader")
        XCTAssertNil(first.schemeHandler.receiver)
        XCTAssertNil(first.webView.onArrowLeft)
        XCTAssertNil(first.webView.onArrowRight)
        XCTAssertNil(first.webView.navigationDelegate)
        XCTAssertNil(first.webView.uiDelegate)
        XCTAssertNil(first.webView.scrollView.delegate)
        XCTAssertTrue(first.webView.configuration.userContentController.userScripts.isEmpty)
        XCTAssertTrue(first.webView.isHidden)

        let reused = pool.take()
        XCTAssertTrue(reused.webView === first.webView)
        let concurrent = pool.take()
        XCTAssertFalse(concurrent.webView === reused.webView, "two readers cannot share one live WebView")
        pool.recycle(reused)
        pool.recycle(concurrent)
        let final = pool.take()
        XCTAssertTrue(final.webView === concurrent.webView, "only the last active reader supplies the next idle checkout")
        pool.recycle(final)
        pool.discardIdle()
        let fresh = pool.take()
        XCTAssertFalse(fresh.webView === final.webView, "an explicitly discarded idle view is not reused")
        pool.recycle(fresh)
    }

    @MainActor func testLocalMangaReadinessAndFirstDocumentDoNotWaitForBookmarkRefresh() async throws {
        let (root, book) = try mangaOpenFixture(), refresh = MangaOpenRefreshGate()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = MangaReaderViewModel(metadata: book), controller = MangaWebViewController(), preferences = UserConfig()
        defer { model.cancelPreload(); model.usage?.close() }
        let ready = expectation(description: "local manga opens while refresh is suspended")
        let opening = Task { @MainActor in
            await model.load(controller: controller, userConfig: preferences, bookmarkRefresh: { _ in await refresh.pauseOnce() })
            model.renderCurrentPage(controller: controller, screenSize: CGSize(width: 744, height: 1133), userConfig: preferences)
            ready.fulfill()
        }
        await refresh.waitUntilPaused()
        await fulfillment(of: [ready], timeout: 3)
        XCTAssertTrue(model.isReady)
        XCTAssertEqual(model.pageIndex, 1)
        XCTAssertNil(model.errorMessage)
        // This is document preparation, before the separate UI first-paint check. The remote
        // refresh remains suspended throughout both parsing and the initial render request.
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while controller.loadToken == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(controller.loadToken, 0)
        XCTAssertEqual(BookStorage.loadBookmark(root: root)?.chapterIndex, 1,
                       "the initial render must not create a newer local navigation")
        await refresh.release()
        await opening.value
    }

    @MainActor func testLateBookmarkMapMovesAnAlreadyReadyMangaToItsRemoteWinner() async throws {
        try await assertLateMangaBookmark(navigateBeforeRefresh: false)
    }

    @MainActor func testMangaNavigationDuringOpeningRefreshWinsOverAnOlderRemoteBookmark() async throws {
        try await assertLateMangaBookmark(navigateBeforeRefresh: true)
    }

    @MainActor private func mangaOpenFixture() throws -> (URL, BookMetadata) {
        let folder = "MangaStartupTest-\(UUID().uuidString)"
        let root = try BookStorage.getBooksDirectory().appendingPathComponent(folder, isDirectory: true)
        let book = BookMetadata(title: "Synthetic manga startup fixture", cover: nil, folder: folder,
                                lastAccess: .distantPast, contentType: .mokuro, syncId: "startup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try BookStorage.save(book, inside: root, as: FileNames.metadata)
        let pages: [[String: Any]] = (0..<6).map { index in
            ["img_path": "images/\(index).png", "img_width": 744, "img_height": 1133, "blocks": []]
        }
        try JSONSerialization.data(withJSONObject: ["title": "Fixture", "pages": pages])
            .write(to: root.appendingPathComponent(FileNames.mokuro))
        try BookStorage.save(Bookmark(chapterIndex: 1, progress: 2.0 / 6, characterCount: 2,
                                     lastModified: Date().addingTimeInterval(-120)), inside: root, as: FileNames.bookmark)
        let journal = ReadingPositionRepository.journalURL(book.syncId!, in: ReadingPositionRepository.shared.directory)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: journal)
        }
        return (root, book)
    }

    @MainActor private func assertLateMangaBookmark(navigateBeforeRefresh: Bool) async throws {
        let (root, book) = try mangaOpenFixture(), refresh = MangaOpenRefreshGate()
        let suite = "MangaStartupMaps.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let settings = HttpSyncSettingsStore(defaults: defaults), previousToken = settings.token
        defer { settings.token = previousToken; defaults.removePersistentDomain(forName: suite) }
        settings.baseURL = "http://localhost"
        settings.token = "manga-startup-fixture"
        let remote = Bookmark(chapterIndex: 5, progress: 1, characterCount: 6,
                              lastModified: Date().addingTimeInterval(-60)).toBlob()
        let transport = try MangaOpenKV(bookId: book.syncId!, bookmark: remote, gate: refresh)
        let stateDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("MangaStartupState-\(UUID())")
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        // Keep the manager's outbox/cache isolated while both it and the real reader resolve
        // the same fixture bytes. The scan contains this test's book alone.
        try FileManager.default.createSymbolicLink(at: stateDirectory.appendingPathComponent(book.folder!), withDestinationURL: root)
        let exchange = HttpSyncBatchState(booksDirectory: stateDirectory, scanLibrary: { _ in
            let bookmark = (try? Data(contentsOf: root.appendingPathComponent(FileNames.bookmark)))
                .flatMap { try? JSONDecoder().decode(Bookmark.self, from: $0) }
            return HttpSyncLocalLibrary(books: [.init(metadata: book, root: root, bookmark: bookmark,
                bookmarkModified: nil, payloadSha: nil, payloadDirty: false)])
        })
        let manager = HttpSyncManager(settings: settings, batchState: exchange, mapTransportFactory: { _ in transport },
                                      positionHistoryExchange: { _, _, _, _ in }, pollCompanionLanes: false)
        manager.suspendPolling()
        let model = MangaReaderViewModel(metadata: book), controller = MangaWebViewController()
        defer { model.cancelPreload(); model.usage?.close() }
        let ready = expectation(description: "manga ready before late map arrives")
        let refreshed = expectation(description: "opening bookmark refresh completed")
        let opening = Task { @MainActor in
            await model.load(controller: controller, userConfig: UserConfig(), bookmarkRefresh: { metadata in
                await manager.syncBookmarksBeforeReading(book: metadata)
                refreshed.fulfill()
            })
            ready.fulfill()
        }
        await refresh.waitUntilPaused()
        await fulfillment(of: [ready], timeout: 3)
        XCTAssertTrue(model.isReady)
        XCTAssertEqual(model.pageIndex, 1)
        if navigateBeforeRefresh {
            model.goToPage(3)
            XCTAssertEqual(BookStorage.loadBookmark(root: root)?.chapterIndex, 3)
        }
        let applied = navigateBeforeRefresh ? nil : expectation(forNotification: .httpSyncBookmarkApplied, object: nil) { note in
            note.userInfo?["syncId"] as? String == book.syncId
        }
        await refresh.release()
        if let applied { await fulfillment(of: [applied], timeout: 3) }
        await fulfillment(of: [refreshed], timeout: 3)
        await manager.flushBookmarkSync()
        await opening.value
        // The reader's notification handler invokes this same reload after the real map merge.
        model.reloadAfterHttpBookmark()
        let expectedPage = navigateBeforeRefresh ? 3 : 5
        XCTAssertEqual(model.pageIndex, expectedPage)
        XCTAssertEqual(BookStorage.loadBookmark(root: root)?.chapterIndex, expectedPage)
        if navigateBeforeRefresh {
            let uploaded = try await transport.uploadedPage()
            XCTAssertEqual(uploaded, 3, "late refresh must upload the newer local turn, not replay remote page 5")
        }
    }

    @MainActor func testMangaStartupTraceUsesMonotonicStagesAndFreezesAtFirstVisible() {
        var now = 100.0, lines: [String] = []
        let trace = MangaStartupTrace(enabled: true, clock: { now }, output: { lines.append($0) })
        now = 100.025
        trace.mark("parse_ready")
        now = 100.125
        trace.mark("document_loaded")
        now = 100.225
        trace.finish()
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("stage=parse_ready elapsed_ms=25.000 delta_ms=25.000"))
        XCTAssertTrue(lines[1].contains("stage=document_loaded elapsed_ms=125.000 delta_ms=100.000"))
        XCTAssertTrue(lines[2].contains("stage=first_visible elapsed_ms=225.000 delta_ms=100.000"))
        XCTAssertEqual(trace.firstVisibleMilliseconds ?? -1, 225, accuracy: 0.001)
        XCTAssertTrue(trace.isFinished)
        now = 200
        trace.mark("late_document")
        trace.finish()
        XCTAssertEqual(lines.count, 3, "a stale completion or later turn cannot rewrite startup evidence")
        XCTAssertEqual(trace.elapsedMilliseconds, 225, accuracy: 0.001)
    }

    @MainActor func testMangaStartupTraceDisabledHasNoClockOrOutputWork() {
        var reads = 0, lines: [String] = []
        let trace = MangaStartupTrace(enabled: false, clock: { reads += 1; return 100 }, output: { lines.append($0) })
        trace.mark("parse_ready")
        trace.finish()
        XCTAssertEqual(trace.elapsedMilliseconds, 0)
        XCTAssertEqual(reads, 0)
        XCTAssertTrue(lines.isEmpty)
        XCTAssertNil(trace.firstVisibleMilliseconds)
    }

    @MainActor func testMangaStartupTraceBoundsRepeatedStagesAndRejectsFreeFormValues() {
        var lines: [String] = []
        let trace = MangaStartupTrace(enabled: true, clock: { 100 }, output: { lines.append($0) })
        for _ in 0..<1000 { trace.mark("same_stage") }
        trace.mark("a title / private/path")
        trace.mark("https://example.test?token=secret")
        XCTAssertEqual(lines.count, 1)
        for index in 0..<1000 { trace.mark("stage_\(index)") }
        trace.finish()
        XCTAssertEqual(lines.count, MangaStartupTrace.maximumStages)
        XCTAssertTrue(lines.last?.contains("stage=first_visible") == true,
                      "the bounded event budget always preserves the real completion")
    }

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

@MainActor private final class MangaSchemeTaskFixture: NSObject, WKURLSchemeTask {
    let request = URLRequest(url: URL(string: "hoshi-img://manga/fixture.png")!)
    func didReceive(_ response: URLResponse) { }
    func didReceive(_ data: Data) { }
    func didFinish() { }
    func didFailWithError(_ error: Error) { }
}

@MainActor private final class MangaSchemeReceiverFixture: NSObject, WKURLSchemeHandler, WKScriptMessageHandler,
                                                           WKNavigationDelegate, WKUIDelegate, UIScrollViewDelegate {
    private(set) var starts = 0
    private(set) var stops = 0
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) { starts += 1 }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) { stops += 1 }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { }
}

private actor MangaOpenRefreshGate {
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

private actor MangaOpenKV: HttpSyncKvTransport {
    private let bookId: String
    private let gate: MangaOpenRefreshGate
    private var paused = false
    private var bodies: [String: Data]
    private var contentTypes: [String: String] = [:]
    private var writes: [String] = []
    init(bookId: String, bookmark: HttpSyncBookmarkBlob, gate: MangaOpenRefreshGate) throws {
        self.bookId = bookId; self.gate = gate
        let entry = HttpSyncBookmarkMapEntry(etag: "remote-position", lastModified: bookmark.lastModified, value: bookmark)
        bodies = [httpSyncBooksMapKey: Data("{}".utf8),
                  httpSyncBookmarksMapPrefix + "remote.json": try JSONEncoder().encode([bookId: entry])]
    }
    func uploadedPage() throws -> Int? {
        // The manager also polls statistics/usage lanes. Their JSON or gzip PUT can finish
        // after the bookmark map; assert the actual bookmark upload, irrespective of order.
        guard let key = writes.last(where: { $0 == httpSyncBookmarksMapKey || $0.hasPrefix(httpSyncBookmarksMapPrefix) }),
              let body = bodies[key] else { return nil }
        return try JSONDecoder().decode([String: HttpSyncBookmarkMapEntry].self, from: body)[bookId]?.value?.chapterIndex
    }
    func get(key: String) async throws -> HttpSyncKvFetched? {
        if !paused { paused = true; await gate.pauseOnce() }
        return bodies[key].map { .init(body: $0, contentType: contentTypes[key] ?? "application/json", lastModified: "", etag: "etag-\(key)") }
    }
    func put(key: String, contentType: String, body: Data) async throws -> HttpSyncKvWriteResponse {
        bodies[key] = body; contentTypes[key] = contentType; writes.append(key)
        return .init(key: key, lastModified: "2026-11-09T00:00:00Z", etag: "write-\(writes.count)", size: body.count)
    }
    func putFile(key: String, contentType: String, fileURL: URL) async throws -> HttpSyncKvWriteResponse {
        try await put(key: key, contentType: contentType, body: Data(contentsOf: fileURL))
    }
    func downloadToFile(key: String, targetURL: URL) async throws -> HttpSyncKvFileFetched? { nil }
    func list(prefix: String?, since: String?, cursor: String?, limit: Int?) async throws -> HttpSyncKvList {
        .init(keys: bodies.map { .init(key: $0.key, lastModified: "", etag: "etag-\($0.key)", size: $0.value.count) })
    }
    func delete(key: String) async throws { bodies[key] = nil; contentTypes[key] = nil }
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
