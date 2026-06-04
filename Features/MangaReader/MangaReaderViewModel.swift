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

    private var bookmarkSaveTask: Task<Void, Never>?
    private var pendingBookmarkPage: Int?
    private let bookmarkDebounce: Duration = .milliseconds(400)

    /// Small render cache of recently built page HTML (keyed by page index + e-ink + size).
    private var htmlCache: [MangaRenderKey: String] = [:]
    private let htmlCacheLimit = 5

    var pageCount: Int { book?.pages.count ?? 0 }
    var title: String? { book?.title ?? metadata.title }

    init(metadata: BookMetadata) {
        self.metadata = metadata
    }

    // MARK: Loading

    func load(controller: MangaWebViewController) async {
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
        } else {
            errorMessage = parsed.error ?? "Could not parse the manga."
        }
    }

    // MARK: Rendering

    func renderCurrentPage(controller: MangaWebViewController, eInkMode: Bool, screenSize: CGSize, userConfig: UserConfig) {
        guard let book, !book.pages.isEmpty, screenSize.width > 0, screenSize.height > 0 else { return }
        let index = max(0, min(pageIndex, book.pages.count - 1))
        let page = book.pages[index]

        let width = Int(screenSize.width.rounded())
        let height = Int(screenSize.height.rounded())
        let key = MangaRenderKey(pageIndex: index, eInk: eInkMode, width: width, height: height)
        let html = htmlCache[key] ?? buildHtml(page: page, eInkMode: eInkMode, width: width, height: height, userConfig: userConfig)
        cacheHtml(html, for: key)

        let allowedPaths = Set([page.imagePath.trimmingPrefixSlash()])
        controller.load(html: html, allowedImagePaths: allowedPaths)

        scheduleBookmark(page: index)
    }

    private func buildHtml(page: MokuroPage, eInkMode: Bool, width: Int, height: Int, userConfig: UserConfig) -> String {
        MangaPageHtml.build(
            page: page,
            backgroundCssColor: eInkMode ? "#ffffff" : "#000000",
            selectionScript: Self.selectionScript,
            scanNonJapaneseText: false,
            eInkMode: eInkMode,
            viewportCssWidth: width,
            viewportCssHeight: height
        )
    }

    private func cacheHtml(_ html: String, for key: MangaRenderKey) {
        htmlCache[key] = html
        if htmlCache.count > htmlCacheLimit {
            // Drop entries for pages furthest from the current one.
            let sorted = htmlCache.keys.sorted { abs($0.pageIndex - pageIndex) > abs($1.pageIndex - pageIndex) }
            for stale in sorted.prefix(htmlCache.count - htmlCacheLimit) {
                htmlCache.removeValue(forKey: stale)
            }
        }
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
        // The view observes pageIndex to drive the crossfade and re-render.
        pageIndex = index
    }

    // MARK: Image file resolution (for screenshot crop)

    func imageFile(forPageIndex index: Int) -> URL? {
        guard let book, let bookRoot, let page = book.pages.first(where: { $0.index == index }) else { return nil }
        let relative = page.imagePath.trimmingPrefixSlash()
        guard !relative.isEmpty else { return nil }
        let candidate = bookRoot.appendingPathComponent(relative).standardizedFileURL
        // Containment guard mirrors the scheme handler.
        let rootPath = bookRoot.standardizedFileURL.path
        guard candidate.path.hasPrefix(rootPath + "/"),
              FileManager.default.fileExists(atPath: candidate.path) else {
            return nil
        }
        return candidate
    }

    // MARK: Dictionary lookup (reuses the shared engine + popup model)

    func handleTextSelection(_ selection: SelectionData, maxResults: Int, scanLength: Int, isVertical: Bool, isFullWidth: Bool) -> Int? {
        let lookupResults = LookupEngine.shared.lookup(selection.text, maxResults: maxResults, scanLength: scanLength)
        var dictionaryStyles: [String: String] = [:]
        for style in LookupEngine.shared.getStyles() {
            dictionaryStyles[String(style.dict_name)] = String(style.styles)
        }
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
            return String(firstResult.matched).count
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

private struct MangaRenderKey: Hashable {
    let pageIndex: Int
    let eInk: Bool
    let width: Int
    let height: Int
}

private extension String {
    func trimmingPrefixSlash() -> String {
        var s = self
        while s.hasPrefix("/") { s.removeFirst() }
        return s
    }
}
