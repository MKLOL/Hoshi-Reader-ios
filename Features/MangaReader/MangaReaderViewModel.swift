//
//  MangaReaderViewModel.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  State + behaviour for the mokuro manga reader screen: parses the MokuroBook, owns the page
//  index, builds + loads per-page HTML, drives the shared dictionary popups (reusing
//  LookupEngine + the EPUB PopupItem model), and persists a debounced page-index bookmark.
//

import SwiftUI
import CHoshiDicts

@Observable
@MainActor
final class MangaReaderViewModel {
    private var metadata: BookMetadata

    private(set) var book: MokuroBook?
    private(set) var bookRoot: URL?
    private(set) var isReady = false
    private(set) var errorMessage: String?

    var pageIndex = 0
    var viewportSize: CGSize = .zero

    /// Per-book preference (persisted in UserDefaults) to show two pages side by side. Toggled from
    /// the reader's options menu. The spread only actually renders in landscape (`isLandscape`).
    var twoPageEnabled: Bool {
        didSet { UserDefaults.standard.set(twoPageEnabled, forKey: Self.twoPageKey(metadata.id)) }
    }
    /// Set by the view from the live geometry; a spread needs the extra horizontal room.
    var isLandscape: Bool = false
    /// Whether a two-page spread should render right now: enabled for this book, in landscape, and
    /// the volume has more than one page.
    var twoPageActive: Bool { twoPageEnabled && isLandscape && (book?.pages.count ?? 0) > 1 }

    private static func twoPageKey(_ id: UUID) -> String { "mangaTwoPage.\(id.uuidString)" }

    /// The right/earlier page index of the spread containing `index`: pages pair (0,1),(2,3),…, the
    /// earlier page on the right (right-to-left reading), so the spread starts on an even index.
    static func spreadStart(_ index: Int) -> Int { index - (index % 2) }

    /// Shared dictionary popups, mirroring `ReaderViewModel.popups`.
    var popups: [PopupItem] = []

    /// Reading statistics tracker (page/time based). `nil` until the book loads.
    private(set) var usage: ReaderUsageSession?
    private(set) var statistics: MangaStatisticsTracker?
    private var pagesRead = 0
    private var resumeTracking = false
    private(set) var sessionCharacters = 0
    private(set) var textStatistics: [MangaTextStatistic] = []
    var todayCharacters: Int { statistics?.textTotal(textStatistics) ?? 0 }
    var allTimeCharacters: Int { textStatistics.reduce(0) { StatisticsNumbers.adding($0, $1.charactersRead) } }


    private var bookmarkSaveTask: Task<Void, Never>?
    private var pendingBookmarkPage: Int?
    private let bookmarkDebounce: Duration = .milliseconds(400)
    private var positionSession: ReadingPositionSession?

    /// Off-main LRU cache of generated page HTML + warmed adjacent image files. The live page
    /// reuses HTML the adjacent-page preloader already built; see `MangaPageRenderCache`.
    private let imageLoader = MangaImageLoader()
    private let renderCache: MangaPageRenderCache
    /// Tracks the most recent preload so a fast second page turn cancels the prior preload.
    private var preloadTask: Task<Void, Never>?
    /// Bumped on every `renderCurrentPage`; lets a slow build for a stale page be discarded if a
    /// newer render started in the meantime (the user flicked again before the build finished).
    private var renderGeneration = 0

    var pageCount: Int { book?.pages.count ?? 0 }
    var title: String? { book?.title ?? metadata.title }

    init(metadata: BookMetadata) {
        self.metadata = metadata
        self.renderCache = MangaPageRenderCache(imageLoader: imageLoader)
        self.twoPageEnabled = UserDefaults.standard.bool(forKey: Self.twoPageKey(metadata.id))
    }

    // MARK: Loading

    func load(controller: MangaWebViewController, userConfig: UserConfig) async {
        guard !isReady, errorMessage == nil else { return }
        await HttpSyncManager.shared.syncBookmarksBeforeReading(book: metadata)
        guard let booksDir = try? BookStorage.getBooksDirectory(), let folder = metadata.folder else {
            errorMessage = "Could not locate the manga book."
            return
        }
        let root = booksDir.appendingPathComponent(folder)
        // Parse off the main actor; return a Sendable tuple (the error reduced to its message so
        // no non-Sendable `Error` existential crosses the task boundary; `String` can't be a
        // `Result.Failure` since it isn't `Error`).
        let parsed: (book: MokuroBook?, error: String?) = await Task.detached(priority: .userInitiated) {
            do { return (try MokuroBookParser.shared.parse(bookRoot: root), nil) }
            catch { return (nil, error.localizedDescription) }
        }.value

        if let parsedBook = parsed.book {
            book = parsedBook
            bookRoot = root
            controller.bookRootForScheme = root
            controller.imageLoader = imageLoader
            await imageLoader.configure(root: root, declaredPaths: Set(parsedBook.pages.map { $0.imagePath.trimmingPrefixSlash() }))
            // Mark this book as the most recently opened so "Recent" sort floats it to the front of
            // its shelf. Mirrors the EPUB reader (ReaderLoaderViewModel.loadBook); the bookshelf
            // re-reads metadata from disk on its next loadBooks().
            metadata.lastAccess = Date()
            try? BookStorage.save(metadata, inside: root, as: FileNames.metadata)
            if let id = syncId(for: metadata) { positionSession = ReadingPositionRepository.shared.open(bookId: id, root: root) }
            let restored = (positionSession?.initialBookmark ?? BookStorage.loadBookmark(root: root))?.chapterIndex ?? 0
            pageIndex = max(0, min(restored, max(0, parsedBook.pages.count - 1)))
            isReady = true
            setUpStatistics(title: parsedBook.title, root: root, userConfig: userConfig)
        } else {
            errorMessage = parsed.error ?? "Could not parse the manga."
        }
    }

    // MARK: Statistics

    private func setUpStatistics(title: String, root: URL, userConfig: UserConfig) {
        usage = ReaderUsageSession(book: metadata)
        statistics = MangaStatisticsTracker(title: title, initialStatistics: ReadingStatisticsStore.reading(root: root), enabled: true,
                                            device: .current, trackPageDurations: true)
        textStatistics = ReadingStatisticsStore.text(root: root)
        // A slow load can finish after the app left the foreground; start when it returns.
        if UIApplication.shared.applicationState == .active {
            usage?.reading(true)
            statistics?.start(currentPage: pagesRead)
        } else {
            resumeTracking = true
        }
    }

    func toggleStatisticsTracking() {
        guard let tracker = statistics else { return }
        if tracker.isTracking { statistics?.pause(currentPage: pagesRead) }
        else { statistics?.start(currentPage: pagesRead) }
        usage?.reading(statistics?.isTracking == true)
        persistStatistics()
    }

    func suspendStatistics() {
        usage?.reading(false)
        resumeTracking = statistics?.isTracking == true
        statistics?.pause(currentPage: pagesRead)
        persistStatistics()
        if let root = bookRoot { HttpReadingStatisticsSync.shared.schedule(root: root, delay: .milliseconds(1500)) }
    }

    func resumeStatistics() {
        if resumeTracking { statistics?.start(currentPage: pagesRead); usage?.reading(true) }
        resumeTracking = false
    }

    private func recordTurn(to index: Int) {
        guard statistics?.isTracking == true, index > pageIndex, let book else { return }
        pagesRead += index - pageIndex
        let characters = book.pages[pageIndex..<index].reduce(0) { sum, page in
            sum + page.textBoxes.reduce(0) { $0 + $1.lines.reduce(0) { $0 + $1.filter { !$0.isWhitespace }.utf16.count } }
        }
        let device = ReadingDevice.current
        let day = MangaStatisticsTracker.dateKey(for: .now)
        var row = textStatistics.first { $0.dateKey == day && $0.deviceId == device.id }
            ?? MangaTextStatistic(dateKey: day, deviceId: device.id, deviceName: device.name)
        row.charactersRead = StatisticsNumbers.adding(row.charactersRead, characters)
        row.lastModified = max(Int(Date().timeIntervalSince1970 * 1000), StatisticsNumbers.nextStamp(row.lastModified))
        textStatistics = MangaTextStatistic.merged(textStatistics + [row])
        sessionCharacters = StatisticsNumbers.adding(sessionCharacters, characters)
        if let root = bookRoot { try? ReadingStatisticsStore.saveText(textStatistics, root: root) }
    }

    func reloadStatistics() {
        guard let bookRoot else { return }
        statistics?.mergeHistory(ReadingStatisticsStore.reading(root: bookRoot))
        textStatistics = MangaTextStatistic.merged(textStatistics + ReadingStatisticsStore.text(root: bookRoot))
    }

    func persistStatistics() {
        guard let bookRoot else { return }
        statistics?.update(currentPage: pagesRead)
        if let rows = statistics?.statisticsForPersistence() {
            try? ReadingStatisticsStore.save(rows, root: bookRoot)
        }
    }

    // MARK: Rendering

    func renderCurrentPage(controller: MangaWebViewController, screenSize: CGSize, userConfig: UserConfig,
                           onLoadToken: ((Int) -> Void)? = nil) {
        guard let book, !book.pages.isEmpty, screenSize.width > 0, screenSize.height > 0 else { return }
        let index = max(0, min(pageIndex, book.pages.count - 1))
        // In a spread the right/earlier page is the spread start; the later page (if any) goes left.
        let twoPage = twoPageActive
        let rightIndex = twoPage ? Self.spreadStart(index) : index
        let page = book.pages[rightIndex]
        let leftPage = (twoPage && rightIndex + 1 < book.pages.count) ? book.pages[rightIndex + 1] : nil
        // Everything the off-main render needs is captured up front as Sendable values, so the
        // build Task never reaches back into the non-Sendable `userConfig`.
        let config = renderConfig(screenSize: screenSize, userConfig: userConfig)
        var allowedPaths = Set([page.imagePath.trimmingPrefixSlash()])
        if let leftPage { allowedPaths.insert(leftPage.imagePath.trimmingPrefixSlash()) }

        let adjacentIndexes = adjacentIndexes(currentIndex: rightIndex, pageCount: book.pages.count, twoPage: twoPage)
        let imageIndexes = ([rightIndex] + adjacentIndexes).flatMap { candidate in
            twoPage && candidate + 1 < book.pages.count ? [candidate, candidate + 1] : [candidate]
        }
        for imageIndex in imageIndexes { allowedPaths.insert(book.pages[imageIndex].imagePath.trimmingPrefixSlash()) }
        let priorityIndexes = Array(imageIndexes.dropFirst(twoPage && leftPage != nil ? 2 : 1).prefix(twoPage ? 2 : 1)) + imageIndexes
        let wantedPaths = priorityIndexes.map { book.pages[$0].imagePath.trimmingPrefixSlash() }
        preloadTask?.cancel()
        renderGeneration += 1
        let generation = renderGeneration

        // Build (or reuse) the HTML off the main actor via the render cache, then load. On a
        // preload hit this resolves immediately; on a miss the (possibly large) build happens on
        // the actor's executor so the main thread never blocks. A newer render supersedes this one.
        Task { [renderCache, imageLoader] in
            guard self.renderGeneration == generation else { return }
            await imageLoader.setWindow(wantedPaths)
            let html = await renderCache.htmlFor(page: page, leftPage: leftPage, config: config)
            guard self.renderGeneration == generation else { return }
            let loadToken = controller.load(html: html, allowedImagePaths: allowedPaths)
            onLoadToken?(loadToken)
            self.preloadAdjacentPages(config: config, controller: controller, loadToken: loadToken, generation: generation)
        }

        scheduleBookmark(page: index)
    }

    /// HTML preparation, encoded reads and WebKit decoding are independent background work.
    /// A new render cancels its predecessor before it can enqueue more speculative images.
    private func preloadAdjacentPages(config: MangaPageRenderConfig, controller: MangaWebViewController,
                                      loadToken: Int, generation: Int) {
        guard let book, !book.pages.isEmpty else { return }
        let twoPage = twoPageActive
        let current = twoPage ? Self.spreadStart(pageIndex) : pageIndex
        let indexes = adjacentIndexes(currentIndex: current, pageCount: book.pages.count, twoPage: twoPage)
        let pages = indexes.flatMap { index -> [MokuroPage] in
            twoPage && index + 1 < book.pages.count ? [book.pages[index], book.pages[index + 1]] : [book.pages[index]]
        }
        preloadTask = Task(priority: .utility) { [renderCache, imageLoader, book] in
            async let html: Void = renderCache.preloadAdjacentPages(book: book, pageIndexes: indexes, twoPage: twoPage, config: config)
            var candidates: [MangaImageDecodeCandidate] = []
            for page in pages {
                guard !Task.isCancelled else { return }
                if let source = await imageLoader.source(relativePath: page.imagePath.trimmingPrefixSlash()) {
                    candidates.append(MangaImageDecodeCandidate(url: source.url, width: page.imageWidth, height: page.imageHeight))
                }
            }
            guard !Task.isCancelled, self.renderGeneration == generation else { return }
            controller.setPredecodeScript(MangaImagePredecode.script(pageIndex: current, candidates: candidates), for: loadToken)
            await imageLoader.prepare(pages.map { $0.imagePath.trimmingPrefixSlash() })
            _ = await html
        }
    }

    private func adjacentIndexes(currentIndex: Int, pageCount: Int, twoPage: Bool) -> [Int] {
        if !twoPage { return mangaAdjacentPreloadIndexes(currentIndex: currentIndex, pageCount: pageCount) }
        return [currentIndex + 2, currentIndex - 2, currentIndex + 4, currentIndex - 4, currentIndex + 6]
            .filter { $0 >= 0 && $0 < pageCount }
    }

    private func renderConfig(screenSize: CGSize, userConfig: UserConfig) -> MangaPageRenderConfig {
        MangaPageRenderConfig(
            backgroundCssColor: "#000000",
            scanNonJapaneseText: userConfig.mangaScanNonJapaneseText,
            viewportCssWidth: Int(screenSize.width.rounded()),
            viewportCssHeight: Int(screenSize.height.rounded()),
            singleTapLookup: userConfig.mangaSingleTapLookup,
            useNotoSansJpFont: userConfig.mangaUseNotoSansJpFont,
            showActionButtons: userConfig.mangaShowActionButtons,
            selectionScript: Self.selectionScript,
            showCopyButton: userConfig.mangaShowCopyButton,
            enlargeSmallText: userConfig.mangaEnlargeSmallText,
            showFurigana: userConfig.mangaShowFurigana
        )
    }

    // MARK: Navigation

    func navigate(_ direction: NavigationDirection) {
        // In a spread, a page turn moves a whole spread (±2 from the current spread's even start).
        if twoPageActive, let book, !book.pages.isEmpty {
            let start = Self.spreadStart(pageIndex)
            let target = direction == .forward ? start + 2 : start - 2
            guard target >= 0, target < book.pages.count else { return }
            recordTurn(to: target)
            goToPage(target, isTurn: true)
            return
        }
        guard let target = MangaPageNavigation.targetIndex(
            currentIndex: pageIndex,
            pageCount: pageCount,
            direction: direction
        ) else { return }
        recordTurn(to: target)
        goToPage(target, isTurn: true)
    }

    func goToPage(_ index: Int, isTurn: Bool = false) {
        guard index != pageIndex, (0..<pageCount).contains(index) else { return }
        usage?.record(.page, source: isTurn ? nil : "jump", page: index + 1, from: pageIndex + 1, to: index + 1)
        // A spread turn completes every page that was on screen, including an odd page's partner.
        let shown = twoPageActive ? Self.spreadStart(pageIndex) : pageIndex
        statistics?.pageChanged(currentPage: pagesRead, completedPages: isTurn ? max(0, index - shown) : 0)
        persistStatistics()
        // The view observes pageIndex to drive the directional page-turn slide and re-render.
        pageIndex = index
        writeBookmark(page: index, action: isTurn ? "pageTurn" : "jump")
    }

    // MARK: Image file resolution (for screenshot crop)

    func imageFile(forPageIndex index: Int) -> URL? {
        guard let book, let bookRoot, let page = book.pages.first(where: { $0.index == index }) else { return nil }
        let relative = page.imagePath.trimmingPrefixSlash()
        guard !relative.isEmpty else { return nil }
        let candidate = bookRoot.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        // Containment guard mirrors the scheme handler (incl. symlink canonicalization).
        let rootPath = bookRoot.standardizedFileURL.resolvingSymlinksInPath().path
        guard candidate.path.hasPrefix(rootPath + "/"),
              FileManager.default.fileExists(atPath: candidate.path) else {
            return nil
        }
        return candidate
    }

    // MARK: Dictionary lookup (reuses the shared engine + popup model)

    private var lookupGeneration = 0
    func handleTextSelection(_ selection: SelectionData, maxResults: Int, scanLength: Int, isVertical: Bool, isFullWidth: Bool) async -> Int? {
        guard !Task.isCancelled else { return nil }
        lookupGeneration += 1
        let generation = lookupGeneration
        let snapshot = await LookupEngine.shared.lookupAsync(selection.text, maxResults: maxResults, scanLength: scanLength)
        guard !Task.isCancelled, lookupGeneration == generation else { return nil }
        let lookupResults = snapshot.results
        usage?.record(.lookup, text: lookupResults.first.map { cxxStringToSwift($0.matched) } ?? selection.text,
            term: lookupResults.first.map { cxxStringToSwift($0.term.expression) },
            source: popups.contains { $0.showPopup } ? "popup" : "page", found: !lookupResults.isEmpty, page: pageIndex + 1)
        let dictionaryStyles = snapshot.styles
        guard !lookupResults.isEmpty else { return nil }
        let popup = PopupItem(
            showPopup: false,
            currentSelection: selection,
            lookupResults: lookupResults,
            dictionaryStyles: dictionaryStyles,
            isVertical: isVertical,
            isFullWidth: isFullWidth,
            clearSelection: false,
            sasayakiCue: nil
        )
        popups.append(popup)

        if let firstResult = lookupResults.first {
            withAnimation(.default.speed(2.2)) {
                popups = popups.map {
                    var p = $0
                    if p.id == popup.id { p.showPopup = true }
                    return p
                }
            }
            return cxxStringToSwift(firstResult.matched).unicodeScalars.count
        }
        return nil
    }

    func closePopups() {
        lookupGeneration += 1
        let popupIds = Set(popups.map(\.id))
        withAnimation(.default.speed(2.4)) {
            for index in popups.indices { popups[index].showPopup = false }
        } completion: {
            self.popups.removeAll { popupIds.contains($0.id) }
        }
    }

    func closeChildPopups(parent: Int) {
        lookupGeneration += 1
        var popupIds: Set<UUID> = []
        withAnimation(.default.speed(2.4)) {
            for index in popups.indices.dropFirst(parent + 1) {
                popups[index].showPopup = false
                popupIds.insert(popups[index].id)
            }
        } completion: {
            self.popups.removeAll { popupIds.contains($0.id) }
        }
    }

    func clearSelection(in controller: MangaWebViewController) {
        controller.clearRevealedBubbles()
    }

    // MARK: Bookmark persistence (debounced)

    private func scheduleBookmark(page: Int) {
        // Rendering, appearance changes and opening a book do not constitute navigation.
        // goToPage commits actual turns immediately, before a render can be cancelled.
    }

    /// Cancels the in-flight adjacent-page preload, if any (e.g. on reader close). The preload is a
    /// pure cache-warming task with no user-visible state, so cancelling it just stops needless work.
    func cancelPreload() {
        preloadTask?.cancel()
        preloadTask = nil
        renderGeneration += 1
        Task { await imageLoader.cancelPreparation() }
    }

    /// Flushes any pending debounced bookmark write immediately (e.g. on reader close).
    func flushPendingBookmark() {
        bookmarkSaveTask?.cancel()
        bookmarkSaveTask = nil
        if let page = pendingBookmarkPage {
            writeBookmark(page: page)
            pendingBookmarkPage = nil
        }
    }

    func reloadAfterHttpBookmark() {
        guard let bookRoot, let book else { return }
        bookmarkSaveTask?.cancel()
        bookmarkSaveTask = nil
        pendingBookmarkPage = nil
        if let id = syncId(for: metadata) { positionSession = ReadingPositionRepository.shared.open(bookId: id, root: bookRoot) }
        guard let restored = (positionSession?.initialBookmark ?? BookStorage.loadBookmark(root: bookRoot))?.chapterIndex else { return }
        let index = max(0, min(restored, max(0, book.pages.count - 1)))
        // Another device's position is not a completed page here.
        if index != pageIndex { statistics?.pageChanged(currentPage: pagesRead, completedPages: 0) }
        pageIndex = index
    }

    private func writeBookmark(page: Int, action: String = "pageTurn") {
        guard let bookRoot, pageCount > 0 else { return }
        let total = pageCount
        let bookmark = Bookmark(
            chapterIndex: page,
            progress: Double(page + 1) / Double(total),
            characterCount: page + 1,
            lastModified: Date()
        )
        if let positionSession {
            guard let event = positionSession.navigate(bookmark: bookmark, action: action) else { return }
            _ = ReadingPositionRepository.shared.record(root: bookRoot, event: event)
        } else {
            try? BookStorage.save(bookmark, inside: bookRoot, as: FileNames.bookmark)
        }
        // Fire-and-forget push to the HTTP KV sync server (no-op unless sync is enabled).
        HttpSyncManager.shared.onPageTurnPersisted(book: metadata)
    }

    // MARK: Selection script

    private static let selectionScript: String = {
        guard let url = Bundle.main.url(forResource: "selection", withExtension: "js"),
              let js = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return js
    }()
}

private extension String {
    func trimmingPrefixSlash() -> String {
        var s = self
        while s.hasPrefix("/") { s.removeFirst() }
        return s
    }
}
