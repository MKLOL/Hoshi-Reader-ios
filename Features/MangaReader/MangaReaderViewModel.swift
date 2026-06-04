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
    private let metadata: BookMetadata

    private(set) var book: MokuroBook?
    private(set) var bookRoot: URL?
    private(set) var isReady = false
    private(set) var errorMessage: String?

    var pageIndex = 0
    var viewportSize: CGSize = .zero

    /// Shared dictionary popups, mirroring `ReaderViewModel.popups`.
    var popups: [PopupItem] = []

    /// Reading statistics tracker (page/time based). `nil` until the book loads.
    private(set) var statistics: MangaStatisticsTracker?

    private var bookmarkSaveTask: Task<Void, Never>?
    private var pendingBookmarkPage: Int?
    private let bookmarkDebounce: Duration = .milliseconds(400)

    /// Off-main LRU cache of generated page HTML + warmed adjacent image files. The live page
    /// reuses HTML the adjacent-page preloader already built; see `MangaPageRenderCache`.
    private let renderCache = MangaPageRenderCache()
    /// Tracks the most recent preload so a fast second page turn cancels the prior preload.
    private var preloadTask: Task<Void, Never>?
    /// Bumped on every `renderCurrentPage`; lets a slow build for a stale page be discarded if a
    /// newer render started in the meantime (the user flicked again before the build finished).
    private var renderGeneration = 0

    var pageCount: Int { book?.pages.count ?? 0 }
    var title: String? { book?.title ?? metadata.title }

    init(metadata: BookMetadata) {
        self.metadata = metadata
    }

    // MARK: Loading

    func load(controller: MangaWebViewController, userConfig: UserConfig) async {
        guard !isReady, errorMessage == nil else { return }
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
            let restored = BookStorage.loadBookmark(root: root)?.chapterIndex ?? 0
            pageIndex = max(0, min(restored, max(0, parsedBook.pages.count - 1)))
            isReady = true
            setUpStatistics(title: parsedBook.title, root: root, userConfig: userConfig)
        } else {
            errorMessage = parsed.error ?? "Could not parse the manga."
        }
    }

    // MARK: Statistics

    private func setUpStatistics(title: String, root: URL, userConfig: UserConfig) {
        let initial = BookStorage.loadMangaStatistics(root: root) ?? []
        var tracker = MangaStatisticsTracker(
            title: title,
            initialStatistics: initial,
            enabled: userConfig.enableStatistics
        )
        // Respect the autostart mode: `on` starts tracking immediately on open; `pageTurn` starts
        // on the first page turn (handled in `recordPageTurnForStatistics`); `off` never auto-starts
        // (the user starts it manually from the stats sheet's play button).
        if userConfig.enableStatistics, userConfig.statisticsAutostartMode == .on {
            tracker.start(currentPage: pageIndex + 1)
        }
        statistics = tracker
    }

    /// Re-syncs the tracker with `userConfig.enableStatistics` when it changes while the reader is
    /// open. The tracker captures `enabled` at construction, so flipping the toggle from the stats
    /// sheet (or Settings) would otherwise do nothing until the book is reopened. Re-inits with a
    /// fresh `enabled` and starts tracking immediately when turned on; persists/drops the in-memory
    /// tracker when turned off.
    func updateStatisticsEnabled(_ enabled: Bool, title: String, autostartMode: StatisticsAutostartMode) {
        // Already in the requested state — nothing to do.
        if let tracker = statistics, tracker.enabled == enabled { return }
        guard let bookRoot else { return }

        if enabled {
            let initial = BookStorage.loadMangaStatistics(root: bookRoot) ?? []
            var tracker = MangaStatisticsTracker(
                title: title,
                initialStatistics: initial,
                enabled: true
            )
            // Enabling live from the sheet honours the autostart mode, matching open-time behaviour.
            if autostartMode == .on {
                tracker.start(currentPage: pageIndex + 1)
            }
            statistics = tracker
        } else {
            // Flush whatever was accumulated before tearing the tracker down.
            persistStatistics()
            statistics = nil
        }
    }

    func toggleStatisticsTracking() {
        guard var tracker = statistics, tracker.enabled else { return }
        if tracker.isTracking {
            tracker.pause(currentPage: pageIndex + 1)
        } else {
            tracker.start(currentPage: pageIndex + 1)
        }
        statistics = tracker
        persistStatistics()
    }

    /// Records a real page turn for statistics. Must be called only from the actual page-turn path
    /// (gated on an actual page-index change in the view), never from `renderCurrentPage` — that
    /// also runs on initial appear and on rotation, which would make `.pageturn` autostart trigger
    /// on open/rotation rather than on the first true page turn (mirrors the EPUB reader, which only
    /// starts/updates stats on a real scroll/page-turn event).
    func recordPageTurnForStatistics(autostartMode: StatisticsAutostartMode) {
        guard var tracker = statistics, tracker.enabled else { return }
        // Page-turn autostart: a page turn starts tracking on the first turn. In `off` mode a page
        // turn must not auto-start (the user controls it manually); `on` mode is already tracking.
        if autostartMode == .pageturn {
            tracker.startForPageTurnIfNeeded(currentPage: pageIndex + 1)
        }
        tracker.update(currentPage: pageIndex + 1)
        statistics = tracker
    }

    /// Flushes accumulated stats and persists today's bucket to the manga sidecar.
    func persistStatistics() {
        guard let bookRoot, var tracker = statistics, tracker.enabled else { return }
        tracker.update(currentPage: pageIndex + 1)
        if let toPersist = tracker.statisticsForPersistence() {
            try? BookStorage.save(toPersist, inside: bookRoot, as: FileNames.mangaStatistics)
        }
        statistics = tracker
    }

    // MARK: Rendering

    func renderCurrentPage(controller: MangaWebViewController, screenSize: CGSize, userConfig: UserConfig) {
        guard let book, !book.pages.isEmpty, screenSize.width > 0, screenSize.height > 0 else { return }
        let index = max(0, min(pageIndex, book.pages.count - 1))
        let page = book.pages[index]
        // Everything the off-main render needs is captured up front as Sendable values, so the
        // build Task never reaches back into the non-Sendable `userConfig`.
        let config = renderConfig(screenSize: screenSize, userConfig: userConfig)
        let allowedPaths = Set([page.imagePath.trimmingPrefixSlash()])

        renderGeneration += 1
        let generation = renderGeneration

        // Build (or reuse) the HTML off the main actor via the render cache, then load. On a
        // preload hit this resolves immediately; on a miss the (possibly large) build happens on
        // the actor's executor so the main thread never blocks. A newer render supersedes this one.
        Task { [renderCache] in
            let html = await renderCache.htmlFor(page: page, config: config)
            guard self.renderGeneration == generation else { return }
            controller.load(html: html, allowedImagePaths: allowedPaths)
            self.preloadAdjacentPages(config: config)
        }

        scheduleBookmark(page: index)
    }

    /// Proactively builds + caches HTML for the ±1 neighbour pages and warms their image files so
    /// the next page turn is instant. Runs off the main actor; superseded by the next page turn.
    private func preloadAdjacentPages(config: MangaPageRenderConfig) {
        guard let book, !book.pages.isEmpty else { return }
        let indexes = mangaAdjacentPreloadIndexes(currentIndex: pageIndex, pageCount: book.pages.count)
        guard !indexes.isEmpty else { return }
        // Resolve image files on the main actor (needs bookRoot), then hand the URLs to the actor.
        var imageFiles: [Int: URL] = [:]
        for index in indexes {
            if let file = imageFile(forPageIndex: index) { imageFiles[index] = file }
        }
        preloadTask?.cancel()
        preloadTask = Task(priority: .utility) { [renderCache, book] in
            await renderCache.preloadAdjacentPages(
                book: book,
                pageIndexes: indexes,
                config: config,
                imageFiles: imageFiles
            )
        }
    }

    private func renderConfig(screenSize: CGSize, userConfig: UserConfig) -> MangaPageRenderConfig {
        MangaPageRenderConfig(
            backgroundCssColor: "#000000",
            scanNonJapaneseText: userConfig.mangaScanNonJapaneseText,
            viewportCssWidth: Int(screenSize.width.rounded()),
            viewportCssHeight: Int(screenSize.height.rounded()),
            singleTapLookup: userConfig.mangaSingleTapLookup,
            useNotoSansJpFont: userConfig.mangaUseNotoSansJpFont,
            selectionScript: Self.selectionScript
        )
    }

    // MARK: Navigation

    func navigate(_ direction: NavigationDirection) {
        guard let target = MangaPageNavigation.targetIndex(
            currentIndex: pageIndex,
            pageCount: pageCount,
            direction: direction
        ) else { return }
        goToPage(target)
    }

    func goToPage(_ index: Int) {
        guard index != pageIndex, (0..<pageCount).contains(index) else { return }
        // The view observes pageIndex to drive the directional page-turn slide and re-render.
        pageIndex = index
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

    func handleTextSelection(_ selection: SelectionData, maxResults: Int, scanLength: Int, isVertical: Bool, isFullWidth: Bool) -> Int? {
        let lookupResults = LookupEngine.shared.lookup(selection.text, maxResults: maxResults, scanLength: scanLength)
        let dictionaryStyles = LookupEngine.shared.getStylesMap()
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
            return cxxStringToSwift(firstResult.matched).count
        }
        return nil
    }

    func closePopups() {
        let popupIds = Set(popups.map(\.id))
        withAnimation(.default.speed(2.4)) {
            for index in popups.indices { popups[index].showPopup = false }
        } completion: {
            self.popups.removeAll { popupIds.contains($0.id) }
        }
    }

    func closeChildPopups(parent: Int) {
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
        pendingBookmarkPage = page
        bookmarkSaveTask?.cancel()
        bookmarkSaveTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.bookmarkDebounce)
            if Task.isCancelled { return }
            self.writeBookmark(page: page)
        }
    }

    /// Cancels the in-flight adjacent-page preload, if any (e.g. on reader close). The preload is a
    /// pure cache-warming task with no user-visible state, so cancelling it just stops needless work.
    func cancelPreload() {
        preloadTask?.cancel()
        preloadTask = nil
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

    private func writeBookmark(page: Int) {
        guard let bookRoot, pageCount > 0 else { return }
        let total = pageCount
        let bookmark = Bookmark(
            chapterIndex: page,
            progress: Double(page + 1) / Double(total),
            characterCount: page + 1,
            lastModified: Date()
        )
        try? BookStorage.save(bookmark, inside: bookRoot, as: FileNames.bookmark)
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
