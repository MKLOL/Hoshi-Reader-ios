import XCTest
@testable import Hoshi_Reader

nonisolated final class RecentParitySafetyTests: XCTestCase {
    func testAnkiRequiresAnExplicitSuccessfulEnvelopeAndHTTPStatus() throws {
        let url = URL(string: "http://127.0.0.1:8765")!
        let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        for body in ["{}", "[]", "{\"result\":42}", "{\"error\":null}", "{\"result\":42,\"error\":false}", "{\"result\":42,\"error\":\"failed\"}"] {
            XCTAssertThrowsError(try AnkiConnectResponse.result(data: Data(body.utf8), response: ok), body)
        }
        let body = Data("{\"result\":42,\"error\":null}".utf8)
        XCTAssertEqual(try AnkiConnectResponse.noteID(AnkiConnectResponse.result(data: body, response: ok)), 42)
        let failed = HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!
        XCTAssertThrowsError(try AnkiConnectResponse.result(data: body, response: failed))
        let sync = try AnkiConnectResponse.result(data: Data("{\"result\":null,\"error\":null}".utf8), response: ok)
        XCTAssertTrue(sync is NSNull, "Void actions still accept their documented null result.")
    }
    func testAnkiNeverReportsSuccessForMissingNotesOrMedia() throws {
        for value: Any in [NSNull(), true, false, -1, 0, 1.5, "123", 1e25] {
            XCTAssertThrowsError(try AnkiConnectResponse.noteID(value))
        }
        XCTAssertEqual(try AnkiConnectResponse.noteID(1_700_000_000_000 as Int64), 1_700_000_000_000)
        XCTAssertThrowsError(try AnkiConnectResponse.storedFilename(NSNull(), expected: "media.png"))
        XCTAssertThrowsError(try AnkiConnectResponse.storedFilename("other.png", expected: "media.png"))
        XCTAssertNoThrow(try AnkiConnectResponse.storedFilename("media.png", expected: "media.png"))
    }
    func testCancelledRestorePreservesExistingCollection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let live = root.appendingPathComponent("Books"), stage = root.appendingPathComponent("staging")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: live.appendingPathComponent("current"))
        try Data("replacement".utf8).write(to: stage.appendingPathComponent("new"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try replaceRestoredFolder(staging: stage, destination: live, fileManager: .default)
        }
        do { try await task.value; XCTFail("Cancelled restore must not publish staging.") }
        catch is CancellationError { }
        XCTAssertEqual(try String(contentsOf: live.appendingPathComponent("current"), encoding: .utf8), "keep")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.appendingPathComponent("new").path))
    }
    func testFailedRestoreSwapRollsBackExistingCollection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let live = root.appendingPathComponent("Books")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: live.appendingPathComponent("current"))
        XCTAssertThrowsError(try replaceRestoredFolder(staging: root.appendingPathComponent("missing"), destination: live, fileManager: .default))
        XCTAssertEqual(try String(contentsOf: live.appendingPathComponent("current"), encoding: .utf8), "keep")
    }
    /// Both backups are `.hoshi` files. One picked under the other heading must be refused,
    /// since restoring replaces the whole collection.
    func testABackupIsOnlyRestoredOverTheKindOfCollectionItHolds() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func staged(_ name: String, _ files: [String]) throws -> URL {
            let folder = root.appendingPathComponent(name)
            for file in files {
                let url = folder.appendingPathComponent(file)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("{}".utf8).write(to: url)
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }
        let books = try staged("books", ["Novel/metadata.json", "Novel/bookmark.json", "Manga/metadata.json", "shelves.json", ".reading_history/a/statistics.json"])
        let dictionaries = try staged("dictionaries", ["Term/JMdict/index.json", "Frequency/Jiten/index.json", "config.json"])
        let emptyLibrary = try staged("empty", ["shelves.json"])
        let unrelated = try staged("unrelated", ["notes/readme.txt", "photo.jpg"])
        XCTAssertTrue(backupMatches("Books", staging: books, fileManager: .default))
        XCTAssertTrue(backupMatches("Dictionaries", staging: dictionaries, fileManager: .default))
        XCTAssertFalse(backupMatches("Books", staging: dictionaries, fileManager: .default), "dictionaries must not replace the library")
        XCTAssertFalse(backupMatches("Dictionaries", staging: books, fileManager: .default), "books must not replace the dictionaries")
        for folder in ["Books", "Dictionaries"] {
            XCTAssertFalse(backupMatches(folder, staging: emptyLibrary, fileManager: .default), "nothing to restore over \(folder)")
            XCTAssertFalse(backupMatches(folder, staging: unrelated, fileManager: .default), "an unrelated archive over \(folder)")
        }
    }
}

nonisolated final class BookshelfUsabilityTests: XCTestCase {
    @MainActor func testMarkReadRestoresLastMangaPageAndPreservesEPUBSpineSemantics() throws {
        let directory = try BookStorage.getBooksDirectory()
        let mangaRoot = directory.appendingPathComponent("mark-read-manga-\(UUID())")
        let epubRoot = directory.appendingPathComponent("mark-read-epub-\(UUID())")
        defer {
            try? FileManager.default.removeItem(at: mangaRoot)
            try? FileManager.default.removeItem(at: epubRoot)
        }
        let shelf = BookshelfViewModel()
        for (root, type, info, finalIndex) in [
            (mangaRoot, ContentType.mokuro, BookInfo(characterCount: 200, chapterInfo: [:]), 199),
            (epubRoot, ContentType.epub, BookInfo(characterCount: 200, chapterInfo: [
                "first": .init(spineIndex: 2, currentTotal: 0, chapterCount: 100),
                "last": .init(spineIndex: 7, currentTotal: 100, chapterCount: 100)
            ]), 7)
        ] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let book = BookMetadata(title: "Mark read fixture", cover: nil, folder: root.lastPathComponent,
                                    lastAccess: .now, contentType: type, syncId: UUID().uuidString.lowercased())
            try BookStorage.save(book, inside: root, as: FileNames.metadata)
            try BookStorage.save(info, inside: root, as: FileNames.bookinfo)
            shelf.markRead(book: book)
            let bookmark = try XCTUnwrap(BookStorage.loadBookmark(root: root))
            XCTAssertEqual(bookmark.chapterIndex, finalIndex)
            XCTAssertEqual(bookmark.progress, 1)
            XCTAssertEqual(bookmark.characterCount, 200)
            let reopened = ReadingPositionRepository.shared.open(bookId: try XCTUnwrap(book.syncId), root: root)
            XCTAssertEqual(reopened.initialBookmark?.chapterIndex, finalIndex)
        }
    }

    @MainActor func testMangaRejectsEPUBOnlyActionsBeforeSyncOrReadingSubtitles() async {
        let shelf = BookshelfViewModel()
        let manga = BookMetadata(title: "Manga", cover: nil, folder: nil, lastAccess: .now, contentType: .mokuro)
        shelf.syncBook(book: manga, syncStats: true, statsSyncMode: .merge, syncAudioBook: true)
        XCTAssertFalse(shelf.isSyncing)
        do {
            _ = try await shelf.runSasayakiMatch(book: manga,
                srtURL: URL(fileURLWithPath: "/nonexistent/subtitles.srt"), searchWindow: 100)
            XCTFail("Manga must not be sent to the EPUB parser")
        } catch BookshelfActionError.epubRequired { }
        catch { XCTFail("Wrong failure: \(error)") }
    }

    @MainActor func testSingleMangaImportShowsProgressWithoutBlockingMainActorAndQueuesLaterImports() async throws {
        let started = expectation(description: "Background import started")
        let imported = expectation(description: "All queued manga imported")
        imported.expectedFulfillmentCount = 3
        let release = DispatchSemaphore(value: 0)
        let first = URL(fileURLWithPath: "/fixture/first.cbz")
        let worker = MokuroImportWorker { source, _ in
            XCTAssertFalse(Thread.isMainThread, "Archive and image work must stay off the UI thread")
            if source == first { started.fulfill() }
            guard release.wait(timeout: .now() + 5) == .success else { throw CancellationError() }
            imported.fulfill()
            return BookMetadata(title: nil, cover: nil, folder: nil, lastAccess: .now, contentType: .mokuro)
        }
        let shelf = BookshelfViewModel(mangaImporter: worker)
        defer { for _ in 0..<3 { release.signal() } }
        shelf.importMangaBundles(result: .success([first]))
        XCTAssertEqual(shelf.importBooksProgress, "Importing 1 / 1...")
        await fulfillment(of: [started], timeout: 2)
        // These main-actor updates execute while the worker is deliberately blocked.
        shelf.importMangaBundles(result: .success([
            URL(fileURLWithPath: "/fixture/second.cbz"), URL(fileURLWithPath: "/fixture/third.cbz")
        ]))
        XCTAssertEqual(shelf.importBooksProgress, "Importing 1 / 3...")
        for _ in 0..<3 { release.signal() }
        await fulfillment(of: [imported], timeout: 3)
        let deadline = ContinuousClock.now + .seconds(2)
        while shelf.importBooksProgress != nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(shelf.importBooksProgress)
        XCTAssertFalse(shelf.shouldShowError, shelf.errorMessage)
    }

    func testBackgroundMangaImportPublishesCompleteVolumeDeduplicatesAndPreservesExistingBookOnFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("manga-import-\(UUID())")
        let source = root.appendingPathComponent("source"), books = root.appendingPathComponent("Books")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a3ioAAAAASUVORK5CYII="))
        for page in ["one.png", "two.png"] { try png.write(to: source.appendingPathComponent(page)) }
        let json = try JSONSerialization.data(withJSONObject: ["title": "Import fixture", "pages": [
            ["img_path": "one.png", "img_width": 1, "img_height": 1, "blocks": []],
            ["img_path": "two.png", "img_width": 1, "img_height": 1, "blocks": []]
        ]])
        try json.write(to: source.appendingPathComponent("fixture.mokuro"))
        let worker = MokuroImportWorker()
        let book = try await worker.importBundle(from: source, booksDirectory: books)
        let installed = books.appendingPathComponent(try XCTUnwrap(book.folder))
        XCTAssertEqual(try JSONDecoder().decode(BookMetadata.self,
            from: Data(contentsOf: installed.appendingPathComponent(FileNames.metadata))), book)
        XCTAssertEqual(try JSONDecoder().decode(BookInfo.self,
            from: Data(contentsOf: installed.appendingPathComponent(FileNames.bookinfo))).characterCount, 2)
        XCTAssertEqual(try MokuroBookParser().parse(bookRoot: installed).pages.count, 2)
        let again = try await worker.importBundle(from: source, booksDirectory: books)
        XCTAssertEqual(again.id, book.id)
        try FileManager.default.removeItem(at: source.appendingPathComponent("two.png"))
        do {
            _ = try await worker.importBundle(from: source, booksDirectory: books)
            XCTFail("Missing source page must fail")
        } catch MokuroImportError.missingImage { }
        XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent("images/two.png")), png)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: books.path), [book.folder!],
                       "Only the complete volume is published; no staging directory survives")
    }

    @MainActor func testSharedMangaInboxSourceSurvivesUntilImportCompletesAndCleanupPreservesOtherFiles() async throws {
        let documents = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        let inbox = documents.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let source = inbox.appendingPathComponent("shared-manga-\(UUID()).cbz")
        let unrelated = inbox.appendingPathComponent("other-share-\(UUID()).cbz")
        let bytes = Data("Shared source fixture".utf8)
        try bytes.write(to: source)
        try bytes.write(to: unrelated)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: unrelated)
        }
        let started = expectation(description: "Shared source import started")
        let finished = expectation(description: "Shared source was read")
        let release = DispatchSemaphore(value: 0)
        let worker = MokuroImportWorker { url, _ in
            started.fulfill()
            guard release.wait(timeout: .now() + 5) == .success else { throw CancellationError() }
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            finished.fulfill()
            return BookMetadata(title: nil, cover: nil, folder: nil, lastAccess: .now, contentType: .mokuro)
        }
        let shelf = BookshelfViewModel(mangaImporter: worker)
        defer { release.signal() }
        shelf.importMangaBundles(result: .success([source]))
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        release.signal()
        await fulfillment(of: [finished], timeout: 3)
        let deadline = ContinuousClock.now + .seconds(2)
        while shelf.importBooksProgress != nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(shelf.importBooksProgress)
        XCTAssertFalse(shelf.shouldShowError, shelf.errorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: unrelated), bytes)
    }
}
