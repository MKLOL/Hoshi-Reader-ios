//
//  BookshelfViewModel.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import EPUBKit

nonisolated enum BookshelfActionError: LocalizedError {
    case epubRequired

    var errorDescription: String? { "This action is available for EPUB books only." }
}

@Observable
@MainActor
class BookshelfViewModel {
    var books: [BookMetadata] = []
    var shelves: [BookShelf] = []
    var isImporting: Bool = false
    var isImportingEpub: Bool = false
    var shouldShowError: Bool = false
    var errorMessage: String = ""
    var shouldShowSuccess: Bool = false
    var successMessage: String = ""
    var isSyncing: Bool = false
    var isDownloading: Bool = false
    var importBooksProgress: String?
    
    private var bookProgress: [UUID: Double] = [:]
    /// "p. X / Y" page labels for mokuro books, keyed by book id. EPUB books are absent.
    private var bookPageLabel: [UUID: String] = [:]
    private(set) var pretranslatedBookIds: Set<UUID> = []
    private var translationsTask: Task<Void, Never>?
    @ObservationIgnored private let mangaImporter: MokuroImportWorker
    @ObservationIgnored private var mangaImportTask: Task<Void, Never>?
    @ObservationIgnored private var pendingMangaImports: [URL] = []
    /// The archive the background import is reading now; it has already left the queue.
    @ObservationIgnored private var activeMangaImport: URL?
    @ObservationIgnored private var mangaImportsCompleted = 0
    @ObservationIgnored private var mangaImportTotal = 0

    init(mangaImporter: MokuroImportWorker = .shared) {
        self.mangaImporter = mangaImporter
    }
    
    func loadBooks() {
        do {
            let hidden = HttpSyncCloudBooks.shared.hiddenInstalledSyncIds
            books = try BookStorage.loadAllBooks().filter { book in
                guard let identity = syncId(for: book) else { return true }
                return !hidden.contains(identity)
            }
            backfillMissingCovers()
            loadBookProgress()
            loadShelves()
            loadTranslationBadges()
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    private func loadTranslationBadges() {
        translationsTask?.cancel()
        let ids = Set(books.map(\.id))
        pretranslatedBookIds.formIntersection(ids)
        guard let directory = try? BookStorage.getBooksDirectory() else { return }
        let inputs = books.compactMap { book -> BookTranslationAvailability.Book? in
            guard let folder = book.folder, let identity = syncId(for: book) else { return nil }
            return .init(id: book.id, root: directory.appendingPathComponent(folder), syncId: identity)
        }
        translationsTask = Task { [weak self] in
            let available = await Task.detached(priority: .utility) {
                BookTranslationAvailability.shared.load(inputs)
            }.value
            guard !Task.isCancelled else { return }
            self?.pretranslatedBookIds = available
        }
    }

    /// Synced books often arrive without a usable cover (cross-platform / ッツ payloads omit it),
    /// so the shelf shows them blank. Generate one the first time we encounter such a book —
    /// mokuro: a page-1 thumbnail; EPUB: a copy of the manifest cover from inside the book — then
    /// persist it so this runs at most once per book. Also heals a metadata cover whose file no
    /// longer exists (deleted by hand, or lost to a failed cover migration). A book that yields
    /// no cover is remembered for the life of the process so the shelf never re-parses it.
    /// Writes the hash-excluded `FileNames.generatedCover`, never a payload-visible name — a
    /// receiver-generated file inside the content hash would make this payload mismatch the
    /// origin's forever. Tolerant of any per-book failure.
    private func backfillMissingCovers() {
        guard let booksDir = try? BookStorage.getBooksDirectory() else { return }
        for i in books.indices {
            guard let folder = books[i].folder, !coverBackfillFailed.contains(folder) else { continue }
            let root = booksDir.appendingPathComponent(folder)
            if let cover = books[i].cover {
                let coverName = (cover as NSString).lastPathComponent
                let coverURL = root.appendingPathComponent(coverName)
                if FileManager.default.fileExists(atPath: coverURL.path(percentEncoded: false)) {
                    continue
                }
            }
            guard let generated = generateCover(root: root) else {
                coverBackfillFailed.insert(folder)
                continue
            }
            books[i].cover = "Books/\(folder)/\(generated)"
            try? BookStorage.save(books[i], inside: root, as: FileNames.metadata)
        }
    }

    /// Books whose cover generation already failed this process; an EPUB parse per shelf
    /// appearance on the main actor is far too expensive to repeat for the same answer.
    private var coverBackfillFailed: Set<String> = []

    /// Writes `FileNames.generatedCover` into `root` for either format. Returns the filename on
    /// success (an already-present generated cover counts), nil when no cover could be produced.
    private func generateCover(root: URL) -> String? {
        let target = root.appendingPathComponent(FileNames.generatedCover)
        if FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) {
            return FileNames.generatedCover
        }
        switch ContentType.detect(bookDir: root) {
        case .mokuro:
            let imagesDir = root.appendingPathComponent(FileNames.mokuroImages)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: imagesDir.path(percentEncoded: false)) else { return nil }
            var firstName: String? = nil
            for name in names.sorted() where !name.hasPrefix(".") { firstName = name; break }
            guard let firstName else { return nil }
            guard (try? MokuroCover.generateThumbnail(
                from: imagesDir.appendingPathComponent(firstName),
                to: target
            )) != nil else { return nil }
            return FileNames.generatedCover
        case .epub:
            guard let document = try? BookStorage.loadEpub(root),
                  let coverPath = findCoverInManifest(document: document) else { return nil }
            guard let source = document.resourceURL(for: coverPath) else { return nil }
            guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false)),
                  (try? FileManager.default.copyItem(at: source, to: target)) != nil else { return nil }
            return FileNames.generatedCover
        }
    }
    
    func loadShelves() {
        shelves = BookStorage.loadShelves() ?? []
    }
    
    func saveShelves() {
        guard let booksDirectory = try? BookStorage.getBooksDirectory() else { return }
        try? BookStorage.save(shelves, inside: booksDirectory, as: FileNames.shelves)
    }
    
    func createShelf(name: String) {
        if !shelves.contains(where: { $0.name == name }) {
            shelves.append(BookShelf(name: name, bookIds: []))
            saveShelves()
        }
    }
    
    func deleteShelf(name: String) {
        // Books on the deleted shelf become unshelved — a placement change for each of them.
        let orphanedIds = shelves.first(where: { $0.name == name })?.bookIds ?? []
        shelves.removeAll(where: { $0.name == name })
        saveShelves()
        for id in orphanedIds {
            if let book = books.first(where: { $0.id == id }) {
                HttpSyncManager.shared.onShelfPlacementChanged(book: book, shelfName: nil)
            }
        }
    }
    
    func moveShelves(from source: IndexSet, to destination: Int) {
        shelves.move(fromOffsets: source, toOffset: destination)
        saveShelves()
    }
    
    func moveBook(_ id: UUID, to name: String?) {
        for i in shelves.indices {
            shelves[i].bookIds.removeAll { $0 == id }
        }
        if let name,
           let index = shelves.firstIndex(where: { $0.name == name }) {
            shelves[index].bookIds.append(id)
        }
        saveShelves()
        // Metadata edits sync immediately (fire-and-forget; no-op when sync is off).
        if let book = books.first(where: { $0.id == id }) {
            HttpSyncManager.shared.onShelfPlacementChanged(book: book, shelfName: name)
        }
    }
    
    func moveBooks(_ books: Set<BookMetadata>, to name: String?) {
        for book in books {
            moveBook(book.id, to: name)
        }
    }
    
    func deleteBooks(_ books: Set<BookMetadata>) {
        for book in books {
            deleteBook(book)
        }
    }
    
    func shelfSections(sortedBy: SortOption, showReading: Bool = false) -> [ShelfSection] {
        var sections: [ShelfSection] = []
        
        if showReading {
            let reading = books.filter {
                let p = progress(for: $0)
                return p > 0 && p < 0.999
            }
            if !reading.isEmpty {
                sections.append(ShelfSection(
                    shelf: BookShelf(name: "Reading", bookIds: []),
                    books: sortBooks(reading, by: sortedBy),
                    isReading: true
                ))
            }
        }
        
        for shelf in shelves {
            let shelvedBooks = books.filter { shelf.bookIds.contains($0.id) }
            sections.append(ShelfSection(shelf: shelf, books: sortBooks(shelvedBooks, by: sortedBy)))
        }
        
        let shelvedIds = Set(shelves.flatMap { $0.bookIds })
        let unshelved = books.filter { !shelvedIds.contains($0.id) }
        sections.append(ShelfSection(shelf: nil, books: sortBooks(unshelved, by: sortedBy)))
        
        return sections
    }
    
    func sortBooks(_ books: [BookMetadata], by option: SortOption) -> [BookMetadata] {
        switch option {
        case .recent:
            return books.sorted { $0.lastAccess > $1.lastAccess }
        case .title:
            return books.sorted { ($0.title ?? "").localizedStandardCompare($1.title ?? "") == .orderedAscending }
        }
    }
    
    func sortedBooks(by option: SortOption) -> [BookMetadata] {
        sortBooks(books, by: option)
    }
    
    private func loadBookProgress() {
        guard let directory = try? BookStorage.getBooksDirectory() else {
            return
        }

        for book in books {
            guard let folder = book.folder else {
                continue
            }
            let root = directory.appendingPathComponent(folder)

            let bookInfo = BookStorage.loadBookInfo(root: root)
            let bookmark = BookStorage.loadBookmark(root: root)

            if let total = bookInfo?.characterCount, total > 0,
               let current = bookmark?.characterCount {
                // A position past the end (a stale bookmark or another device's count) reads as finished.
                bookProgress[book.id] = min(1, max(0, Double(current) / Double(total)))
                // For mokuro books characterCount is a page count (bookmark = page + 1), so surface
                // a human page label instead of the EPUB percentage.
                if book.resolvedContentType == .mokuro {
                    let page = min(max(current, 1), total)
                    bookPageLabel[book.id] = "p. \(page) / \(total)"
                } else {
                    bookPageLabel[book.id] = nil
                }
            } else {
                bookProgress[book.id] = 0.0
                let pages = bookInfo?.characterCount ?? 0
                bookPageLabel[book.id] = (book.resolvedContentType == .mokuro && pages > 0) ? "p. 1 / \(pages)" : nil
            }
        }
    }

    func progress(for book: BookMetadata) -> Double {
        bookProgress[book.id] ?? 0.0
    }

    /// "p. X / Y" for mokuro books, `nil` for EPUB (which use the percentage label).
    func pageLabel(for book: BookMetadata) -> String? {
        bookPageLabel[book.id]
    }
    
    func deleteBook(_ book: BookMetadata) {
        do {
            if let folder = book.folder {
                try StatisticsHistory.retain(root: BookStorage.getBooksDirectory().appendingPathComponent(folder))
            }
            // Stage a tombstone BEFORE removing the directory so the next HTTP sync pushes
            // `deletedAt` to the server (propagating the delete to other devices) and skips
            // re-importing this book before that push runs. Mirrors Android's
            // BookshelfRepository.recordHttpSyncTombstone. Only books with a derivable syncId
            // participate in sync, so skip the record when the title yields no syncId.
            if let title = book.title, let bookSyncId = syncId(for: book) {
                let deletedAt = rfc3339Now()
                HttpSyncDeletedBookStore.record(
                    syncId: bookSyncId,
                    title: title,
                    contentType: book.resolvedContentType,
                    deletedAt: deletedAt
                )
                // Push the tombstone immediately; the staged record above stays as the
                // retry path for the next manual sync.
                HttpSyncManager.shared.onBookDeleted(
                    syncId: bookSyncId, title: title,
                    contentType: book.resolvedContentType, deletedAt: deletedAt
                )
            }
            if let folder = book.folder {
                let bookURL = try BookStorage.getBooksDirectory().appendingPathComponent(folder)
                try BookStorage.delete(at: bookURL)
            }
            books.removeAll { $0.id == book.id }
            for i in shelves.indices {
                shelves[i].bookIds.removeAll { $0 == book.id }
            }
            saveShelves()
        } catch {
            showError(message: error.localizedDescription)
        }
    }
    
    func importBook(result: Result<URL, Error>) {
        do {
            try importBook(from: try result.get())
            loadBooks()
        } catch {
            showError(message: error.localizedDescription)
        }
    }
    
    func importBooks(result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            if urls.isEmpty {
                return
            }
            
            if urls.count == 1 {
                importBook(result: .success(urls[0]))
                return
            }
            
            importBooksProgress = "Importing 1 / \(urls.count)..."
            Task {
                defer { importBooksProgress = nil }
                await Task.yield()
                
                var failed: [String] = []
                for (index, url) in urls.enumerated() {
                    autoreleasepool {
                        do {
                            try importBook(from: url)
                        } catch {
                            failed.append(url.lastPathComponent)
                        }
                    }
                    let next = index + 1
                    if next < urls.count {
                        importBooksProgress = "Importing \(next + 1) / \(urls.count)..."
                        await Task.yield()
                    }
                }
                loadBooks()
                
                if !failed.isEmpty {
                    showError(message: "Failed to import:\n\(failed.joined(separator: "\n"))")
                }
            }
        } catch {
            showError(message: error.localizedDescription)
        }
    }
    
    func importMangaBundles(result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            guard !urls.isEmpty else { return }
            pendingMangaImports.append(contentsOf: urls)
            mangaImportTotal += urls.count
            updateMangaImportProgress()
            guard mangaImportTask == nil else { return }
            mangaImportTask = Task {
                defer {
                    mangaImportTask = nil
                    importBooksProgress = nil
                    mangaImportsCompleted = 0
                    mangaImportTotal = 0
                }
                var failed: [String] = []
                while !pendingMangaImports.isEmpty {
                    let url = pendingMangaImports.removeFirst()
                    activeMangaImport = url
                    do {
                        let directory = try BookStorage.getBooksDirectory()
                        let metadata = try await mangaImporter.importBundle(from: url, booksDirectory: directory)
                        // UI state and sync publication stay on the main actor; extraction,
                        // OCR decoding, image copies and cover generation run on the worker.
                        HttpSyncManager.shared.onBookImported(book: metadata)
                    } catch {
                        failed.append(url.lastPathComponent)
                    }
                    clearConsumedMangaInboxFile(url)
                    activeMangaImport = nil
                    mangaImportsCompleted += 1
                    if !pendingMangaImports.isEmpty { updateMangaImportProgress() }
                }
                loadBooks()
                if !failed.isEmpty {
                    showError(message: "Failed to import:\n\(failed.joined(separator: "\n"))")
                }
            }
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    private func updateMangaImportProgress() {
        importBooksProgress = "Importing \(mangaImportsCompleted + 1) / \(mangaImportTotal)..."
    }

    private func clearConsumedMangaInboxFile(_ source: URL) {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let inbox = documents.appendingPathComponent("Inbox", isDirectory: true).standardizedFileURL
        let file = source.standardizedFileURL
        guard file.deletingLastPathComponent() == inbox,
              !pendingMangaImports.contains(where: { $0.standardizedFileURL == file }) else { return }
        // A newly shared or unrelated Inbox file may already be waiting. Remove only
        // this source, once all queued uses have completed and security access ended.
        try? FileManager.default.removeItem(at: file)
    }

    func importRemoteBook(from url: URL) {
        isDownloading = true
        Task {
            defer {
                isDownloading = false
            }
            do {
                let (tempURL, _) = try await URLSession.shared.download(from: url)
                try processImport(sourceURL: tempURL)
                loadBooks()
            } catch {
                showError(message: "Download failed: \(error.localizedDescription)")
            }
        }
    }
    
    func syncBook(book: BookMetadata, direction: SyncDirection? = nil, syncStats: Bool, statsSyncMode: StatisticsSyncMode, syncAudioBook: Bool) {
        guard book.resolvedContentType == .epub else { return }
        isSyncing = true
        Task {
            defer {
                isSyncing = false
            }
            do {
                let result = try await SyncManager.shared.syncBook(
                    book: book,
                    direction: direction,
                    syncStats: syncStats,
                    statsSyncMode: statsSyncMode,
                    syncAudioBook: syncAudioBook
                )
                handleSyncResult(result)
            } catch {
                showError(message: "Sync failed: \(error.localizedDescription)")
            }
        }
    }
    
    private func handleSyncResult(_ result: SyncResult) {
        switch result {
        case .synced(let title):
            showSuccess(message: "\(title) is already synced")
        case .imported(let title, let characterCount):
            loadBookProgress()
            showSuccess(message: "Synced \(title) from ッツ\n\(characterCount) characters")
        case .exported(let title, let characterCount):
            showSuccess(message: "Synced \(title) to ッツ\n\(characterCount) characters")
        case .skipped:
            break
        }
    }
    
    func markRead(book: BookMetadata) {
        guard let bookFolder = book.folder else { return }
        guard let directory = try? BookStorage.getBooksDirectory() else { return }
        let url = directory.appendingPathComponent(bookFolder)
        guard let bookInfo = BookStorage.loadBookInfo(root: url) else { return }
        
        let bookmark = Bookmark(
            chapterIndex: book.resolvedContentType == .mokuro
                ? max(0, bookInfo.characterCount - 1)
                : bookInfo.chapterInfo.values.compactMap(\.spineIndex).max() ?? 0,
            progress: 1,
            characterCount: bookInfo.characterCount,
            lastModified: Date()
        )
        
        if let id = syncId(for: book) {
            let session = ReadingPositionRepository.shared.open(bookId: id, root: url)
            if let event = session.navigate(bookmark: bookmark, action: "markRead") {
                _ = ReadingPositionRepository.shared.record(root: url, event: event)
            }
        } else {
            try? BookStorage.save(bookmark, inside: url, as: FileNames.bookmark)
        }
        HttpSyncManager.shared.onPageTurnPersisted(book: book)
        loadBookProgress()
    }
    
    func clearInbox() {
        guard let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }
        
        let inboxDirectory = documentsDirectory.appendingPathComponent("Inbox")
        guard FileManager.default.fileExists(atPath: inboxDirectory.path(percentEncoded: false)),
              let inboxContents = try? FileManager.default.contentsOfDirectory(
                at: inboxDirectory,
                includingPropertiesForKeys: nil
              ) else {
            return
        }
        
        // Manga shared into the app is read by the background import after this returns. Those
        // archives are removed by the import itself once it has finished with them.
        let inUse = pendingMangaImports + [activeMangaImport].compactMap { $0 }
        let inUseFiles = Set(inUse.map(\.standardizedFileURL))
        let inUseNames = Set(inUse.filter { $0.deletingLastPathComponent().lastPathComponent == "Inbox" }.map(\.lastPathComponent))
        for item in inboxContents where !inUseFiles.contains(item.standardizedFileURL) && !inUseNames.contains(item.lastPathComponent) {
            try? FileManager.default.removeItem(at: item)
        }
    }
    
    func runSasayakiMatch(book: BookMetadata, srtURL: URL, searchWindow: Int) async throws -> SasayakiMatchData {
        guard book.resolvedContentType == .epub else {
            throw BookshelfActionError.epubRequired
        }
        guard let folder = book.folder else {
            throw URLError(.fileDoesNotExist)
        }
        
        let rootURL = try BookStorage.getBooksDirectory().appendingPathComponent(folder)
        let accessing = srtURL.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                srtURL.stopAccessingSecurityScopedResource()
            }
        }
        
        let srtData = try Data(contentsOf: srtURL)
        let cues = SasayakiParser.parseCues(from: srtData)
        let result = try SasayakiMatcher.match(
            rootURL: rootURL,
            cues: cues,
            searchWindow: searchWindow
        )
        try BookStorage.save(result, inside: rootURL, as: FileNames.sasayakiMatch)
        return result
    }
    
    func loadSasayakiMatch(book: BookMetadata) -> SasayakiMatchData? {
        guard let folder = book.folder,
              let books = try? BookStorage.getBooksDirectory() else {
            return nil
        }
        
        let root = books.appendingPathComponent(folder)
        return BookStorage.loadSasayakiMatch(root: root)
    }
    
    private func importBook(from url: URL) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        try processImport(sourceURL: url)
    }
    
    private func processImport(sourceURL: URL) throws {
        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("epub")
        
        try FileManager.default.copyItem(at: sourceURL, to: tempURL)
        
        defer {
            try? FileManager.default.removeItem(at: tempURL)
            try? FileManager.default.removeItem(at: tempURL.deletingPathExtension())
        }
        
        let tempDocument = try BookStorage.loadEpub(tempURL)
        guard let title = tempDocument.title, !title.isEmpty else {
            return
        }
        
        let safeTitle = sanitizeFileName(title)
        
        let booksDir = try BookStorage.getBooksDirectory()
        let targetFolder = booksDir.appendingPathComponent(safeTitle)
        
        if FileManager.default.fileExists(atPath: targetFolder.path(percentEncoded: false)) {
            return
        }
        
        let destinationPath = "Books/\(safeTitle).epub"
        let localURL = try BookStorage.copyFile(from: tempURL, to: destinationPath)
        let bookFolder = localURL.deletingPathExtension()
        
        let document = try BookStorage.loadEpub(localURL)
        
        try finalizeImport(localURL: localURL, bookFolder: bookFolder, document: document)
    }
    
    private func finalizeImport(localURL: URL, bookFolder: URL, document: EPUBDocument) throws {
        do {
            var coverURL: String?
            if let coverPath = findCoverInManifest(document: document), let coverSourceURL = document.resourceURL(for: coverPath) {
                let coverDestination = "Books/\(bookFolder.lastPathComponent)/\(coverSourceURL.lastPathComponent)"
                try BookStorage.copyFile(from: coverSourceURL, to: coverDestination)
                coverURL = coverDestination
            }
            
            let metadata = BookMetadata(
                title: document.title,
                cover: coverURL,
                folder: bookFolder.lastPathComponent,
                lastAccess: Date(),
                contentType: .epub,
                importedAt: rfc3339Now(),
                syncId: deriveSyncId(document.title, folderName: bookFolder.lastPathComponent)
            )
            
            let bookinfo = BookProcessor.process(document: document)
            
            try BookStorage.save(metadata, inside: bookFolder, as: FileNames.metadata)
            try BookStorage.save(bookinfo, inside: bookFolder, as: FileNames.bookinfo)
            try BookStorage.delete(at: localURL)
            // Publish the new book's metadata immediately (payload uploads on manual sync).
            HttpSyncManager.shared.onBookImported(book: metadata)
        } catch {
            try? BookStorage.delete(at: localURL)
            try? BookStorage.delete(at: bookFolder)
            throw error
        }
    }
    
    /// A folder whose name starts with a dot is hidden: the book would be imported and never
    /// listed. Each leading dot becomes an underscore, which the sync ID ignores as it did the dot.
    private func sanitizeFileName(_ string: String) -> String {
        let cleaned = string
            .components(separatedBy: CharacterSet(charactersIn: "\\/:*?\"<>|").union(.newlines).union(.controlCharacters))
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let dots = cleaned.prefix(while: { $0 == "." }).count
        return String(repeating: "_", count: dots) + cleaned.dropFirst(dots)
    }
    
    private func findCoverInManifest(document: EPUBDocument) -> String? {
        // EPUB3
        // <item href="Images/embed0028_HD.jpg" properties="cover-image" id="embed0028_HD" media-type="image/jpeg"/>
        if let coverItem = document.manifest.items.values.first(where: { $0.property?.contains("cover-image") == true }) {
            return coverItem.path
        }
        
        // EPUB2
        // <meta name="cover" content="cover"/>
        // <item id="cover" href="cover.jpeg" media-type="image/jpeg"/>
        if let coverId = document.metadata.coverId,
           let coverItem = document.manifest.items[coverId] {
            return coverItem.path
        }
        
        // fallbacks in case the epub doesn't conform to any standards
        let imageTypes: [EPUBMediaType] = [.jpeg, .png, .gif, .svg]
        if let coverItem = document.manifest.items.values.first(where: { $0.id.lowercased().contains("cover") }),
           imageTypes.contains(coverItem.mediaType) {
            return coverItem.path
        }
        if let firstImage = document.manifest.items.values.first(where: { imageTypes.contains($0.mediaType) }) {
            return firstImage.path
        }
        
        return nil
    }
    
    private func showError(message: String) {
        errorMessage = message
        shouldShowError = true
    }
    
    private func showSuccess(message: String) {
        successMessage = message
        shouldShowSuccess = true
    }
}

struct ShelfSection: Identifiable {
    let shelf: BookShelf?
    var books: [BookMetadata]
    var isReading: Bool = false
    
    var id: String {
        if isReading {
            return "__reading__"
        }
        return shelf.map { "shelf:\($0.name)" } ?? "unshelved"
    }
}
