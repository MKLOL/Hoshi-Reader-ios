import EPUBKit
import SwiftUI
import XCTest
@testable import Hoshi_Reader

nonisolated final class ReaderLifetimeTests: XCTestCase {
    @MainActor func testActualLoaderRedrawsAndTicksKeepOneUsageSessionUntilDismissal() async throws {
        let root = try BookStorage.getBooksDirectory().appendingPathComponent("reader-loader-\(UUID())", isDirectory: true)
        try makeBook(root)
        let log = UsageLog(directory: root.appendingPathComponent("usage"))
        let book = BookMetadata(title: "Loader lifetime", cover: nil, folder: root.lastPathComponent,
            lastAccess: .now, contentType: .epub, syncId: UUID().uuidString.lowercased())
        let config = UserConfig()
        config.enableSync = false
        config.statisticsAutostartMode = .on
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: AnyView(ReaderLoader(book: book, usageLog: log).environment(config)))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            host.rootView = AnyView(EmptyView())
            window.isHidden = true
            previous?.makeKeyAndVisible()
            HttpSyncActiveBooks.close(syncId(for: book))
            try? FileManager.default.removeItem(at: root)
        }
        try await waitUntil { await log.read().events.contains { $0.type == .started } }
        // Reconstruct the actual loader while its retained reader receives one-second ticks.
        // SwiftUI must retain its State even though new view values are supplied by the parent.
        for index in 0..<4 {
            config.readerShowProgressTop = index.isMultiple(of: 2)
            host.rootView = AnyView(ReaderLoader(book: book, usageLog: log).environment(config))
            try await Task.sleep(for: .milliseconds(600))
        }
        var events = await log.read().events
        XCTAssertEqual(events.filter { $0.type == .opened }.count, 1)
        XCTAssertEqual(events.filter { $0.type == .started }.count, 1)
        XCTAssertEqual(Set(events.compactMap(\.session)).count, 1)
        XCTAssertFalse(events.contains { $0.type == .closed })

        host.rootView = AnyView(EmptyView())
        try await waitUntil { await log.read().events.contains { $0.type == .closed } }
        events = await log.read().events
        XCTAssertEqual(events.filter { $0.type == .stopped }.count, 1)
        XCTAssertEqual(events.filter { $0.type == .closed }.count, 1)
        let count = events.count
        try await Task.sleep(for: .milliseconds(1100))
        let afterDismissal = await log.read().events
        XCTAssertEqual(afterDismissal.count, count)
    }

    @MainActor func testUnusedModelHasNoSessionAndSentenceAutostartUsesItsConfiguration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reader-start-\(UUID())", isDirectory: true)
        try makeBook(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = try EPUBParser().parse(documentAt: root)
        let log = UsageLog(directory: root.appendingPathComponent("usage"))
        let book = BookMetadata(title: "Start fixture", cover: nil, folder: root.lastPathComponent, lastAccess: .now)
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "statisticsAutostartMode")
        defer { defaults.set(previous, forKey: "statisticsAutostartMode") }
        defaults.set(StatisticsAutostartMode.pageturn.rawValue, forKey: "statisticsAutostartMode")
        let model = ReaderViewModel(book: book, document: document, rootURL: root,
            enableStatistics: true, autostartStatistics: false, autoSyncEnabled: false, syncStats: false,
            statsSyncMode: .merge, syncAudioBook: false, showSentenceTranslations: false,
            statisticsAutostartMode: .off, usageLog: log)
        let unused = await log.read().events
        XCTAssertTrue(unused.isEmpty)
        model.start()
        model.start()
        model.beginSentenceMode()
        model.saveSentenceProgress(.init(chapterIndex: 0, progress: 0.5, characterCount: 5))
        XCTAssertFalse(model.isTracking, "A stale defaults value must not override the retained reader's mode")
        XCTAssertTrue(model.finish())
        XCTAssertFalse(model.finish())
        model.start()
        let events = await log.read().events
        XCTAssertEqual(events.filter { $0.type == .opened }.count, 1)
        XCTAssertEqual(events.filter { $0.type == .closed }.count, 1)
        XCTAssertFalse(events.contains { $0.type == .started })
    }

    @MainActor func testStatisticsDuplicateSaveDoesNotRewriteOrAnnounceAndPreservesOrigins() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reader-stats-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var row = Statistics.empty(title: "Fixture", day: "2026-11-08", device: ReadingDevice(id: "fixture", name: "Fixture"))
        row.readingTime = 10
        row.lastStatisticModified = 1
        let origin = UUID()
        let ownChange = expectation(forNotification: .readingStatisticsChanged, object: nil) { note in
            note.object as? URL == root && note.userInfo?["origin"] as? UUID == origin
        }
        try ReadingStatisticsStore.save([row], root: root, scheduleSync: false, origin: origin)
        await fulfillment(of: [ownChange], timeout: 1)
        let file = root.appendingPathComponent(FileNames.statistics)
        let before = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let duplicate = expectation(forNotification: .readingStatisticsChanged, object: nil) { $0.object as? URL == root }
        duplicate.isInverted = true
        try ReadingStatisticsStore.save([row], root: root, scheduleSync: false, origin: origin)
        await fulfillment(of: [duplicate], timeout: 0.1)
        XCTAssertEqual(try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, before)
        let external = UUID()
        let externalChange = expectation(forNotification: .readingStatisticsChanged, object: nil) { note in
            note.object as? URL == root && note.userInfo?["origin"] as? UUID == external
        }
        row.readingTime = 20
        row.lastStatisticModified = 2
        try ReadingStatisticsStore.save([row], root: root, scheduleSync: false, origin: external)
        await fulfillment(of: [externalChange], timeout: 1)
        XCTAssertEqual(ReadingStatisticsStore.reading(root: root).first?.readingTime, 20)
    }

    func testDateCacheHandlesConcurrentZonesAndOffsetsAcrossDST() async {
        let date = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01 00:00 UTC
        let correct = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<100 {
                group.addTask {
                    let east = index.isMultiple(of: 2)
                    let zone = TimeZone(secondsFromGMT: (east ? 14 : -11) * 3600)!
                    return ReaderDateFormatting.shared.dayKey(for: date, timeZone: zone) == (east ? "2026-01-01" : "2025-12-31")
                }
            }
            for await result in group where !result { return false }
            return true
        }
        XCTAssertTrue(correct)
        let eastern = TimeZone(identifier: "America/New_York")!
        XCTAssertEqual(ReaderDateFormatting.utcOffset(for: date, timeZone: eastern), "-05:00")
        XCTAssertEqual(ReaderDateFormatting.utcOffset(for: date.addingTimeInterval(180 * 86400), timeZone: eastern), "-04:00")
        XCTAssertEqual(ReaderDateFormatting.utcOffset(for: date, timeZone: TimeZone(secondsFromGMT: 19800)!), "+05:30")
        XCTAssertEqual(ReaderDateFormatting.utcOffset(for: date, timeZone: TimeZone(secondsFromGMT: 0)!), "+00:00")
    }

    @MainActor private func waitUntil(_ condition: @escaping @MainActor () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Reader lifecycle did not settle")
    }

    @MainActor private func makeBook(_ root: URL) throws {
        let files = [
            "META-INF/container.xml": "<container><rootfiles><rootfile full-path=\"content.opf\"/></rootfiles></container>",
            "content.opf": """
            <package xmlns:dc="http://purl.org/dc/elements/1.1/"><metadata><dc:title>Lifetime fixture</dc:title></metadata>
            <manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
            <item id="nav" href="toc.ncx" media-type="application/x-dtbncx+xml"/></manifest>
            <spine toc="nav"><itemref idref="chapter"/></spine></package>
            """,
            "toc.ncx": """
            <ncx><docTitle><text>Lifetime fixture</text></docTitle><navMap>
            <navPoint id="chapter"><navLabel><text>Chapter one</text></navLabel><content src="chapter.xhtml"/></navPoint>
            </navMap></ncx>
            """,
            "chapter.xhtml": "<!doctype html><html><head><meta charset=\"utf-8\"/></head><body><p>日本語を読みます。次の文章です。</p></body></html>"
        ]
        for (path, content) in files {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: file, atomically: true, encoding: .utf8)
        }
        let document = try EPUBParser().parse(documentAt: root)
        try BookStorage.save(BookProcessor.process(document: document), inside: root, as: FileNames.bookinfo)
    }
}
