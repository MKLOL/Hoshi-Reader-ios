import XCTest
import EPUBKit
import SwiftUI
@testable import Hoshi_Reader

nonisolated final class FeatureParityTests: XCTestCase {
    func testUnchangedUnshelvedMetadataDoesNotCreateAShelfEdit() {
        let metadataStamp = "2026-09-10T15:00:00Z"
        let removalStamp = "2026-09-09T15:00:00Z"
        XCTAssertNil(remoteShelfPlacementStamp(shelfName: nil, shelfUpdatedAt: nil, metadataModifiedAt: metadataStamp))
        XCTAssertEqual(remoteShelfPlacementStamp(shelfName: "Reading", shelfUpdatedAt: nil, metadataModifiedAt: metadataStamp), metadataStamp)
        XCTAssertEqual(remoteShelfPlacementStamp(shelfName: nil, shelfUpdatedAt: removalStamp, metadataModifiedAt: metadataStamp), removalStamp)
    }
    @MainActor func testEncodedEpubResourcesAndNestedContentsResolveAgainstTheirDocument() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("epub-paths-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try makePathFixture(root)
        let document = try EPUBParser().parse(documentAt: root)
        let chapter = try XCTUnwrap(document.resourceURL(for: "Text/chapter%201+%2520.xhtml"))
        XCTAssertEqual(chapter.lastPathComponent, "chapter 1+%20.xhtml")
        XCTAssertTrue(FileManager.default.fileExists(atPath: chapter.path))
        XCTAssertEqual(document.resourceURL(for: "/OEBPS/Text/chapter%201+%2520.xhtml"), chapter)
        let toc = try XCTUnwrap(document.tableOfContents.subTable?.first)
        XCTAssertEqual(document.resourceURL(for: try XCTUnwrap(toc.item)), chapter)
        let rows = ChapterListViewModel(document: document, bookInfo: BookProcessor.process(document: document), currentIndex: 0).rows
        XCTAssertEqual(rows.map(\.spineIndex), [0])
        XCTAssertEqual(rows.first?.fragment, "見出し%20")
        XCTAssertEqual(SentenceReaderLoader.chapterSources(document: document).first?.url, chapter)
        XCTAssertGreaterThan(SentenceReaderLoader.segment(sources: SentenceReaderLoader.chapterSources(document: document)).chapters.first?.sentences.count ?? 0, 0)
        XCTAssertEqual(document.cover?.lastPathComponent, "cover 1.png")
    }

    func testEpubResourceContainmentRejectsTraversalAndSymlinks() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("epub-containment-\(UUID())", isDirectory: true)
        let root = parent.appendingPathComponent("book", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try makePathFixture(root)
        let outside = parent.appendingPathComponent("outside.txt")
        try "private".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("OEBPS/linked.txt"), withDestinationURL: outside)
        let document = try EPUBParser().parse(documentAt: root)
        XCTAssertNil(document.resourceURL(for: "../../outside.txt"))
        XCTAssertNil(document.resourceURL(for: "%2e%2e/%2e%2e/outside.txt"))
        XCTAssertNil(document.resourceURL(for: "linked.txt"))
        XCTAssertNil(document.resourceURL(for: "file:///etc/passwd"))
        XCTAssertNil(document.resourceURL(for: "https://example.org/chapter.xhtml"))
        let container = root.appendingPathComponent("META-INF/container.xml")
        try "<container><rootfiles><rootfile full-path=\"../outside.txt\"/></rootfiles></container>".write(to: container, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try EPUBParser().parse(documentAt: root))
    }

    private func makePathFixture(_ root: URL) throws {
        let files = [
            "META-INF/container.xml": "<container><rootfiles><rootfile full-path=\"OEBPS/content.opf\"/></rootfiles></container>",
            "OEBPS/content.opf": """
            <package xmlns:dc="http://purl.org/dc/elements/1.1/"><metadata><dc:title>Path fixture</dc:title><meta name="cover" content="cover"/></metadata><manifest>
            <item id="chapter" href="Text/chapter%201+%2520.xhtml" media-type="application/xhtml+xml"/>
            <item id="nav" href="Nav/toc.ncx" media-type="application/x-dtbncx+xml"/>
            <item id="cover" href="Images/cover%201.png" media-type="image/png"/>
            </manifest><spine toc="nav"><itemref idref="chapter"/></spine></package>
            """,
            "OEBPS/Nav/toc.ncx": """
            <ncx><docTitle><text>Path fixture</text></docTitle><navMap><navPoint id="one"><navLabel><text>Chapter one</text></navLabel><content src="../Text/chapter%201+%2520.xhtml#%E8%A6%8B%E5%87%BA%E3%81%97%2520"/></navPoint></navMap></ncx>
            """,
            "OEBPS/Text/chapter 1+%20.xhtml": "<html><body><p id=\"見出し%20\">日本語を読みます。</p></body></html>",
            "OEBPS/Images/cover 1.png": "fixture"
        ]
        for (path, content) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    @MainActor func testAnkiRefreshKeepsSelectionAndOnlyExistingFields() {
        let result = AnkiManager.reconciledOptions(decks: ["Default", "Other", "Japanese"],
            noteTypes: [AnkiNoteType(name: "Basic", fields: ["Front"]), AnkiNoteType(name: "Lapis", fields: ["Expression", "Meaning"])],
            selectedDeck: "Japanese", selectedNoteType: "Lapis", mappings: ["Expression": "{expression}", "Removed": "old"])
        XCTAssertEqual(result.deck, "Japanese")
        XCTAssertEqual(result.model, "Lapis")
        XCTAssertEqual(result.mappings, ["Expression": "{expression}"])
    }
    @MainActor func testAnkiReplacementModelDoesNotInheritOldMappings() {
        let result = AnkiManager.reconciledOptions(decks: ["Default", "Japanese"],
            noteTypes: [AnkiNoteType(name: "New", fields: ["Expression"])], selectedDeck: "Gone",
            selectedNoteType: "Old", mappings: ["Expression": "old"])
        XCTAssertEqual(result.deck, "Japanese")
        XCTAssertEqual(result.model, "New")
        XCTAssertTrue(result.mappings.isEmpty)
    }
    func testTinyOfflineModelAndLegacyDownloadsRemainDiscoverable() {
        XCTAssertEqual(LlmModelCatalog.byId("qwen3.5-0.8b-q4km")?.contextLength, 4096)
        XCTAssertNotNil(LlmModelCatalog.byId("qwen2.5-7b-instruct-q4km"))
        XCTAssertEqual(Set(LlmModelCatalog.all.map(\.id)).count, LlmModelCatalog.all.count)
    }

    @MainActor func testFullScreenReadingModeKeepsSessionUntilReaderWindowDismissal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reader-lifetime-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try makePathFixture(root)
        let document = try EPUBParser().parse(documentAt: root)
        let log = UsageLog(directory: root.appendingPathComponent("usage"))
        let book = BookMetadata(title: "Lifetime fixture", cover: nil, folder: root.lastPathComponent,
                                lastAccess: .now, contentType: .epub, syncId: UUID().uuidString)
        let model = ReaderViewModel(book: book, document: document, rootURL: root,
            enableStatistics: true, autostartStatistics: true, autoSyncEnabled: false, syncStats: false,
            statsSyncMode: .merge, syncAudioBook: false, showSentenceTranslations: false, usageLog: log)
        let syncId = try XCTUnwrap(syncId(for: book))
        HttpSyncActiveBooks.open(syncId)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let presenter = UIViewController()
        window.rootViewController = presenter
        window.makeKeyAndVisible()
        let readerWindow = ReaderWindow()
        defer {
            readerWindow.dismiss()
            model.stopTracking()
            HttpSyncActiveBooks.close(syncId)
            window.isHidden = true
            previous?.makeKeyAndVisible()
        }
        let config = UserConfig()
        readerWindow.present(content: { ReaderView(viewModel: model).environment(config) }, onDismiss: {})
        try await waitUntil { readerWindow.lifetime?.onDismiss != nil }
        let lifetime = try XCTUnwrap(readerWindow.lifetime)
        let host = try XCTUnwrap(presenter.presentedViewController)

        // UIKit's full-screen presentation invokes the same presenting-view disappearance as
        // SwiftUI's fullScreenCover. Use the actual sentence view as the covering controller.
        func cover() -> UIViewController {
            let controller = UIHostingController(rootView: SentenceReaderView(book: book, document: document,
                coverURL: nil, bookmark: nil, backgroundColor: .white, foregroundColor: .black,
                usage: model.usage).environment(config))
            controller.modalPresentationStyle = .fullScreen
            return controller
        }
        let firstCover = cover()
        await withCheckedContinuation { continuation in
            host.present(firstCover, animated: false) { continuation.resume() }
        }
        let before = model.sessionStatistics.readingTime
        try await waitUntil { model.sessionStatistics.readingTime > before + 0.5 }
        XCTAssertFalse(lifetime.isClosed)
        XCTAssertTrue(HttpSyncActiveBooks.contains(syncId))
        model.usage?.record(.lookup, text: "during-cover", found: true)
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        try await waitUntil { model.isPaused }
        let pausedTime = model.sessionStatistics.readingTime
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertEqual(model.sessionStatistics.readingTime, pausedTime)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        try await waitUntil { !model.isPaused && model.sessionStatistics.readingTime > pausedTime + 0.5 }
        await withCheckedContinuation { continuation in
            firstCover.dismiss(animated: false) { continuation.resume() }
        }
        model.usage?.record(.lookup, text: "after-return", found: true)
        var events = await log.read().events
        XCTAssertFalse(events.contains { $0.type == .closed })
        XCTAssertEqual(events.filter { $0.type == .lookup }.compactMap(\.text), ["during-cover", "after-return"])

        // A shortcut can close ReaderWindow while the nested mode is still displayed.
        let secondCover = cover()
        await withCheckedContinuation { continuation in
            host.present(secondCover, animated: false) { continuation.resume() }
        }
        let dismissed = expectation(description: "reader and nested mode dismissed")
        readerWindow.dismiss { dismissed.fulfill() }
        await fulfillment(of: [dismissed], timeout: 5)
        try await waitUntil { !HttpSyncActiveBooks.contains(syncId) }
        XCTAssertTrue(lifetime.isClosed)
        XCTAssertFalse(model.isTracking)
        XCTAssertNil(presenter.presentedViewController)
        events = await log.read().events
        XCTAssertEqual(events.filter { $0.type == .closed }.count, 1)
        XCTAssertGreaterThan(ReadingStatisticsStore.reading(root: root).reduce(0) { $0 + $1.readingTime }, 0)
    }

    @MainActor private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "Presentation/session state did not settle")
    }
}
