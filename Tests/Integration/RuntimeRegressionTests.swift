import XCTest
import UIKit
import WebKit
@testable import Hoshi_Reader

nonisolated final class RuntimeRegressionTests: XCTestCase {
    /// Settings → Diagnostics keeps a bounded record on the device, and reports a run that was
    /// still in front when it ended: iOS moves an app to the background before it quits it.
    func testDiagnosticsKeepTheNewestOfEachKindAndReportARunThatEndedInFront() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let log = DiagnosticsLog(directory: directory)
        for index in 0..<12 {
            log.record(DiagnosticEvent(kind: .crash, time: start.addingTimeInterval(Double(index)), version: "1.0 (1)", title: "crash \(index)"))
        }
        log.record(DiagnosticEvent(kind: .hang, time: start, version: "1.0 (1)", title: "hang"))
        var events = await log.events()
        XCTAssertEqual(events.filter { $0.kind == .crash }.map(\.title), (2..<12).reversed().map { "crash \($0)" })
        XCTAssertEqual(events.filter { $0.kind == .hang }.count, 1)

        // Opened, brought to the front, and never seen leaving it.
        log.beginSession(version: "1.0 (1)", now: start.addingTimeInterval(100))
        log.sessionMoved(foreground: true, now: start.addingTimeInterval(101))
        _ = await log.events() // Each launch has its own writer; let this one finish first.
        let relaunched = DiagnosticsLog(directory: directory)
        relaunched.beginSession(version: "1.1 (2)", now: start.addingTimeInterval(500))
        events = await relaunched.events()
        let exit = try XCTUnwrap(events.first { $0.kind == .unexpectedExit })
        XCTAssertEqual(exit.version, "1.0 (1)")
        XCTAssertEqual(exit.time, start.addingTimeInterval(101))
        XCTAssertTrue(exit.details.contains("Next opened: \(DiagnosticsReport.stamp(start.addingTimeInterval(500)))"))

        // Locked, switched away from or closed from the app switcher: an ordinary ending.
        relaunched.sessionMoved(foreground: true, now: start.addingTimeInterval(501))
        relaunched.sessionMoved(foreground: false, now: start.addingTimeInterval(502))
        _ = await relaunched.events()
        let third = DiagnosticsLog(directory: directory)
        third.beginSession(version: "1.1 (2)", now: start.addingTimeInterval(900))
        events = await third.events()
        XCTAssertEqual(events.filter { $0.kind == .unexpectedExit }.count, 1)
    }

    func testDiagnosticsReportNamesTheBlamedThreadAndBoundsLongTraces() async throws {
        let tree = Data("""
        {"callStackPerThread": true, "callStacks": [
          {"threadAttributed": false, "callStackRootFrames": [{"binaryName": "other", "address": 1, "offsetIntoBinaryTextSegment": 1, "binaryUUID": "A"}]},
          {"threadAttributed": true, "callStackRootFrames": [
            {"binaryName": "libswiftCore.dylib", "address": 6917529027641081856, "offsetIntoBinaryTextSegment": 123, "binaryUUID": "B",
             "subFrames": [{"binaryName": "Hoshi Reader", "address": 4096, "offsetIntoBinaryTextSegment": 45, "binaryUUID": "C",
                            "subFrames": [{"binaryName": "dyld", "address": 16, "offsetIntoBinaryTextSegment": 6, "binaryUUID": "D"}]}]}]}]}
        """.utf8)
        XCTAssertEqual(DiagnosticsReport.trace(fromCallStackTree: tree), """
        0  libswiftCore.dylib  0x6000000000000000  +123  B
        1  Hoshi Reader  0x1000  +45  C
        2  dyld  0x10  +6  D
        """)
        XCTAssertEqual(DiagnosticsReport.trace(fromCallStackTree: tree, frameLimit: 2)?.components(separatedBy: "\n").count, 2)
        XCTAssertNil(DiagnosticsReport.trace(fromCallStackTree: Data("not json".utf8)))
        XCTAssertEqual(DiagnosticsReport.crashTitle(exceptionType: 1, signal: 11), "EXC_BAD_ACCESS (SIGSEGV)")
        XCTAssertEqual(DiagnosticsReport.crashTitle(exceptionType: nil, signal: 6), "SIGABRT")
        XCTAssertEqual(DiagnosticsReport.crashTitle(exceptionType: 99, signal: nil), "Exception 99")
        XCTAssertEqual(DiagnosticsReport.exitLines(foreground: [("closed normally", 3), ("memory limit", 0)], background: [("memory needed by other apps", 2)]),
                       ["Open, closed normally: 3", "In the background, memory needed by other apps: 2"])

        let long = String(repeating: "a", count: 20_000) + String(repeating: "z", count: 20_000)
        let bounded = DiagnosticsReport.bounded(long)
        XCTAssertTrue(bounded.hasPrefix(String(repeating: "a", count: 6_000) + "\n[trace truncated"))
        XCTAssertTrue(bounded.hasSuffix(String(repeating: "z", count: 6_000)))
        XCTAssertEqual(DiagnosticsReport.bounded("short"), "short")

        // An uncaught exception is written as the app goes down; only the newest five are kept.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("crashes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<7 {
            XCTAssertNotNil(DiagnosticsLog.saveCapturedCrash(name: "NSRangeException", reason: "index \(index) beyond bounds", symbols: ["0 CoreFoundation", "1 Hoshi Reader"],
                                                             header: ["Version: 1.0 (1)"], time: start.addingTimeInterval(Double(index)), in: directory))
        }
        let captured = DiagnosticsLog.capturedCrashes(in: directory)
        XCTAssertEqual(captured.map(\.time), (2..<7).reversed().map { start.addingTimeInterval(Double($0)) })
        XCTAssertTrue(try XCTUnwrap(captured.first).text.contains("Reason: index 6 beyond bounds\n\n0 CoreFoundation\n1 Hoshi Reader"))

        let app = DiagnosticsReport.App(bundle: "com.example.hoshi", version: "1.0 (1)", system: "27.0.0", device: "iPad14,1")
        XCTAssertTrue(DiagnosticsReport(app: app).text.contains("Nothing has been recorded."))
        let report = DiagnosticsReport(app: app, capturedCrashes: Array(captured.prefix(1)), events: [
            DiagnosticEvent(kind: .pageProcess, time: start, version: "1.0 (1)", title: "Manga page process ended", details: ["On screen: yes"]),
            DiagnosticEvent(kind: .crash, time: start, version: "1.0 (1)", title: "EXC_CRASH (SIGABRT)", details: ["iOS: 27.0"], trace: long)])
        XCTAssertEqual(report.sections.map { String($0.prefix(while: { $0 != "\n" })) },
                       ["Hoshi Reader Diagnostics", "Captured Crash 1", "Crash 1", "Page Restart 1"])
        XCTAssertTrue(report.sections[0].hasSuffix("Bundle: com.example.hoshi\nVersion: 1.0 (1)\niOS: 27.0.0\nDevice: iPad14,1"))
        XCTAssertTrue(report.sections[2].contains("Time: 2027-01-15T08:00:00Z\nVersion: 1.0 (1)\nEXC_CRASH (SIGABRT)\niOS: 27.0\nTrace:\naaaa"))
        XCTAssertTrue(report.sections[2].contains("[trace truncated"))
        XCTAssertFalse(report.text.contains("Nothing has been recorded."))
        XCTAssertEqual(DiagnosticsReport.fileName(now: start), "hoshi-diagnostics-20270115-080000.txt")
    }

    /// Storage Cleanup offers only files the app is known to leave behind, never one written
    /// recently enough to belong to running work, and removes only what still qualifies.
    func testStorageCleanupOffersOnlyTheAppsOwnIdleLeftovers() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("cleanup-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let temporary = root.appendingPathComponent("tmp"), books = root.appendingPathComponent("Books")
        let dictionaries = root.appendingPathComponent("Dictionaries"), received = root.appendingPathComponent("Inbox")
        let now = Date(), old = now.addingTimeInterval(-3600)
        func make(_ url: URL, bytes: Int = 10, modified: Date) throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: bytes).write(to: url)
            try fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        let restore = temporary.appendingPathComponent("hoshi-restore-1")
        try make(restore.appendingPathComponent("Books/a/metadata.json"), bytes: 100, modified: old)
        try make(restore.appendingPathComponent("Books/a/cover.jpg"), bytes: 200, modified: old)
        for folder in [restore, restore.appendingPathComponent("Books"), restore.appendingPathComponent("Books/a")] {
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: folder.path)
        }
        let export = temporary.appendingPathComponent("Books_2026-11-10_10-00-00.hoshi")
        try make(export, bytes: 1000, modified: old)
        let copy = temporary.appendingPathComponent("\(UUID().uuidString).epub")
        try make(copy, bytes: 50, modified: old)
        let running = temporary.appendingPathComponent("hoshi-sync-stage-2")
        try make(running.appendingPathComponent("page.jpg"), modified: now.addingTimeInterval(-30))
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: running.path)
        let foreign = temporary.appendingPathComponent("WebKit/MediaCache/clip")
        try make(foreign, modified: old)
        let system = temporary.appendingPathComponent("CFNetworkDownload_abc.tmp")
        try make(system, modified: old)
        let manga = books.appendingPathComponent(".MokuroImport-1/pages/1.jpg")
        try make(manga, bytes: 300, modified: old)
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: manga.deletingLastPathComponent().path)
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: manga.deletingLastPathComponent().deletingLastPathComponent().path)
        let book = books.appendingPathComponent("A Book/metadata.json")
        try make(book, modified: old)
        let hidden = books.appendingPathComponent(".hack/metadata.json")
        try make(hidden, modified: old)
        let dictionary = dictionaries.appendingPathComponent("Term/.import-1/index.json")
        try make(dictionary, bytes: 40, modified: old)
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: dictionary.deletingLastPathComponent().path)
        let installed = dictionaries.appendingPathComponent("Term/JMdict/index.json")
        try make(installed, modified: old)
        let waiting = received.appendingPathComponent("volume.cbz")
        try make(waiting, modified: old)
        let stale = received.appendingPathComponent("old.epub")
        try make(stale, bytes: 70, modified: now.addingTimeInterval(-2 * 86_400))

        let cleanup = StorageCleanup(temporary: temporary, books: books, dictionaries: dictionaries, received: received, now: now)
        let shown = cleanup.scan()
        XCTAssertEqual(shown.map(\.id), [.temporary, .imports, .received])
        XCTAssertEqual(Set(shown[0].targets.map(\.lastPathComponent)), [restore.lastPathComponent, export.lastPathComponent, copy.lastPathComponent])
        XCTAssertEqual(shown[0].size, 1350)
        XCTAssertEqual(shown[0].count, 4)
        XCTAssertEqual(shown[1].size, 340)
        XCTAssertEqual(shown[1].count, 2)
        XCTAssertEqual(shown[2].targets.map(\.lastPathComponent), ["old.epub"])

        // An import picked the export up again while the list was on screen.
        try fm.setAttributes([.modificationDate: now], ofItemAtPath: export.path)
        let after = cleanup.clean(shown)
        XCTAssertEqual(after, [])
        for kept in [export, running.appendingPathComponent("page.jpg"), foreign, system, book, hidden, installed, waiting] {
            XCTAssertTrue(fm.fileExists(atPath: kept.path), kept.lastPathComponent)
        }
        for removed in [restore, copy, manga.deletingLastPathComponent().deletingLastPathComponent(), dictionary.deletingLastPathComponent(), stale] {
            XCTAssertFalse(fm.fileExists(atPath: removed.path), removed.lastPathComponent)
        }
    }

    /// AnkiMobile and the app's own pages fetch a card's cover and audio through localhost. The
    /// server listens on the loopback interface only and must still answer there.
    @MainActor func testLocalFileServerAnswersOnLocalhost() async throws {
        let clip = Data("sasayaki-clip".utf8)
        LocalFileServer.shared.setSasayakiAudio(clip)
        defer { LocalFileServer.shared.clearMedia() }
        let url = try XCTUnwrap(URL(string: "http://localhost:\(LocalFileServer.port)/sasayaki/audio.m4a"))
        var received: Data?, status = 0
        // The listener may need a moment, or a retry when its port was just released.
        for _ in 0..<40 where received == nil {
            var request = URLRequest(url: url); request.timeoutInterval = 2
            if let (data, response) = try? await URLSession.shared.data(for: request) {
                received = data; status = (response as? HTTPURLResponse)?.statusCode ?? 0
            } else { try await Task.sleep(for: .milliseconds(150)) }
        }
        XCTAssertEqual(status, 200)
        XCTAssertEqual(received, clip)
    }
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
