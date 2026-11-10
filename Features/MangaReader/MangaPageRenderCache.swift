//
//  MangaPageRenderCache.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  HTML and offline readings are prepared off the main actor. The book-scoped image
//  backend supplies current-version URLs independently of this small document cache.

import Foundation

/// The render inputs that decide a page's HTML. Two requests with the same `pageIndex` and the
/// same config can share one cached document. A `nonisolated`, Sendable value type so it can
/// cross into the render cache actor and the preload task.
nonisolated struct MangaPageRenderConfig: Hashable, Sendable {
    let backgroundCssColor: String
    let scanNonJapaneseText: Bool
    let viewportCssWidth: Int
    let viewportCssHeight: Int
    let singleTapLookup: Bool
    let useNotoSansJpFont: Bool
    let showActionButtons: Bool
    let selectionScript: String
    var showCopyButton: Bool = false
    var enlargeSmallText: Bool = true
    var textEnlargementAmount: Int = 50
    var smallTextThreshold: Int = 30
    var showFurigana: Bool = true
    var textSizePreview: Bool = false
}

/// LRU cache of generated manga-page HTML, keyed by current image versions.
actor MangaPageRenderCache {
    private let maxEntries: Int
    private let imageLoader: MangaImageLoader?

    /// Cache key = which page (and, for a two-page spread, which page is paired on its left),
    /// rendered under which config. `leftPageIndex` keeps a spread render from colliding with the
    /// single-page render of the same page.
    private struct Key: Hashable {
        let pageIndex: Int
        let leftPageIndex: Int?
        let config: MangaPageRenderConfig
        let imageURLs: [String]
    }

    /// HTML by key, with an access-order list so the least-recently-used entry is evicted first.
    private var entries: [Key: String] = [:]
    private var entryOrder: [Key] = []

    init(maxEntries: Int = 6, imageLoader: MangaImageLoader? = nil) {
        self.maxEntries = max(maxEntries, 1)
        self.imageLoader = imageLoader
    }

    /// Returns cached HTML for `page` under `config`, building (and caching) it on first miss.
    /// Runs the build on the actor's executor, i.e. off the main actor.
    func htmlFor(page: MokuroPage, leftPage: MokuroPage? = nil, config: MangaPageRenderConfig) async -> String {
        var imageSources: [String: String] = [:]
        for imagePage in [page, leftPage].compactMap({ $0 }) {
            if let source = await imageLoader?.source(relativePath: String(imagePage.imagePath.drop(while: { $0 == "/" }))) {
                imageSources[imagePage.imagePath] = source.url
            }
        }
        let key = Key(pageIndex: page.index, leftPageIndex: leftPage?.index, config: config,
                      imageURLs: [imageSources[page.imagePath] ?? "", leftPage.flatMap { imageSources[$0.imagePath] } ?? ""])
        if let cached = entries[key] {
            touch(key)
            return cached
        }
        let html = MangaPageHtml.build(
            page: page,
            leftPage: leftPage,
            backgroundCssColor: config.backgroundCssColor,
            selectionScript: config.selectionScript,
            scanNonJapaneseText: config.scanNonJapaneseText,
            viewportCssWidth: config.viewportCssWidth,
            viewportCssHeight: config.viewportCssHeight,
            singleTapLookup: config.singleTapLookup,
            useNotoSansJpFont: config.useNotoSansJpFont,
            showActionButtons: config.showActionButtons,
            showCopyButton: config.showCopyButton,
            enlargeSmallText: config.enlargeSmallText,
            textEnlargementAmount: config.textEnlargementAmount,
            smallTextThreshold: config.smallTextThreshold,
            showFurigana: config.showFurigana,
            textSizePreview: config.textSizePreview,
            imageSources: imageSources
        )
        if !Task.isCancelled { insert(html, for: key) }
        return html
    }

    /// Prepares neighbouring documents while the image backend independently prepares bytes.
    func preloadAdjacentPages(
        book: MokuroBook,
        pageIndexes: [Int],
        twoPage: Bool = false,
        config: MangaPageRenderConfig
    ) async {
        var seen = Set<Int>()
        for pageIndex in pageIndexes where seen.insert(pageIndex).inserted {
            if Task.isCancelled { return }
            guard pageIndex >= 0, pageIndex < book.pages.count else { continue }
            let page = book.pages[pageIndex]
            // In a spread the neighbour render pairs this page with the next one on its left, so warm
            // and build with that partner too — otherwise the preloaded HTML wouldn't match the live
            // spread request and the turn would rebuild on the main path.
            let leftPage = (twoPage && pageIndex + 1 < book.pages.count) ? book.pages[pageIndex + 1] : nil
            _ = await htmlFor(page: page, leftPage: leftPage, config: config)
            if Task.isCancelled { return }
        }
    }

    // MARK: LRU bookkeeping

    private func touch(_ key: Key) {
        if let existing = entryOrder.firstIndex(of: key) {
            entryOrder.remove(at: existing)
        }
        entryOrder.append(key)
    }

    private func insert(_ html: String, for key: Key) {
        entries[key] = html
        touch(key)
        while entryOrder.count > maxEntries {
            let evicted = entryOrder.removeFirst()
            entries.removeValue(forKey: evicted)
        }
    }

}
