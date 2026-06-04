//
//  MangaPageRenderCache.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Ported from Android `features/mangareader/MangaPageRenderCache.kt`. A small LRU cache of
//  generated manga-page HTML plus a bounded set of "warmed" image files, used to make page
//  turns instant:
//   - The live page reuses HTML the adjacent-page preloader already built on a background turn,
//     so a flick never pays the cost of generating a (potentially large) OCR-overlay document on
//     the main actor.
//   - Adjacent page image files are read/memory-mapped into the OS file cache ahead of time so
//     the scheme handler's `Data(contentsOf:)` for the next page is served warm.
//
//  An `actor` so all of this runs off the main actor: `preloadAdjacentPages` builds HTML and
//  warms bytes on a background executor, and the live render path hops onto the actor only to
//  read/insert a cache entry. `MangaPageHtml.build` is `nonisolated`, so it is the actor that
//  drives the build off the main thread.
//

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
    let selectionScript: String
}

/// LRU cache of generated manga-page HTML + a bounded set of warmed image files.
actor MangaPageRenderCache {
    private let maxEntries: Int
    private let maxWarmedImages: Int

    /// Cache key = which page, rendered under which config.
    private struct Key: Hashable {
        let pageIndex: Int
        let config: MangaPageRenderConfig
    }

    /// HTML by key, with an access-order list so the least-recently-used entry is evicted first.
    private var entries: [Key: String] = [:]
    private var entryOrder: [Key] = []

    /// Canonical paths already warmed, with an access-order list (same LRU policy).
    private var warmedImages: Set<String> = []
    private var warmedOrder: [String] = []

    init(maxEntries: Int = 5, maxWarmedImages: Int = 12) {
        self.maxEntries = max(maxEntries, 1)
        self.maxWarmedImages = max(maxWarmedImages, 1)
    }

    /// Returns cached HTML for `page` under `config`, building (and caching) it on first miss.
    /// Runs the build on the actor's executor, i.e. off the main actor.
    func htmlFor(page: MokuroPage, config: MangaPageRenderConfig) -> String {
        let key = Key(pageIndex: page.index, config: config)
        if let cached = entries[key] {
            touch(key)
            return cached
        }
        let html = MangaPageHtml.build(
            page: page,
            backgroundCssColor: config.backgroundCssColor,
            selectionScript: config.selectionScript,
            scanNonJapaneseText: config.scanNonJapaneseText,
            viewportCssWidth: config.viewportCssWidth,
            viewportCssHeight: config.viewportCssHeight,
            singleTapLookup: config.singleTapLookup,
            useNotoSansJpFont: config.useNotoSansJpFont
        )
        insert(html, for: key)
        return html
    }

    /// Builds + caches the HTML for each page in `pageIndexes` and warms its image file. Cheaply
    /// re-entrant: already-cached pages and already-warmed images are skipped. `imageFiles` maps a
    /// page index to its on-disk image URL, resolved on the main actor by the caller (it needs the
    /// book root + containment guard) and handed in as sendable values.
    func preloadAdjacentPages(
        book: MokuroBook,
        pageIndexes: [Int],
        config: MangaPageRenderConfig,
        imageFiles: [Int: URL]
    ) {
        var seen = Set<Int>()
        for pageIndex in pageIndexes where seen.insert(pageIndex).inserted {
            if Task.isCancelled { return }
            guard pageIndex >= 0, pageIndex < book.pages.count else { continue }
            let page = book.pages[pageIndex]
            _ = htmlFor(page: page, config: config)
            if Task.isCancelled { return }
            if let file = imageFiles[pageIndex] {
                warmImageFileIfNeeded(file)
            }
        }
    }

    /// Reads/memory-maps `file`'s bytes (capped) so the OS file cache is primed for the next
    /// page's scheme-handler read. No-op when already warmed or unreadable.
    private func warmImageFileIfNeeded(_ file: URL) {
        let canonical = file.standardizedFileURL.resolvingSymlinksInPath().path
        guard !warmedImages.contains(canonical) else { return }
        markWarmed(canonical)
        Self.warmMangaImageFile(file)
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

    private func markWarmed(_ canonical: String) {
        warmedImages.insert(canonical)
        if let existing = warmedOrder.firstIndex(of: canonical) {
            warmedOrder.remove(at: existing)
        }
        warmedOrder.append(canonical)
        while warmedOrder.count > maxWarmedImages {
            let evicted = warmedOrder.removeFirst()
            warmedImages.remove(evicted)
        }
    }

    // MARK: Image warming

    /// Reads up to `maxBytes` of `file` into a throwaway buffer, priming the OS file cache so the
    /// scheme handler's later read is served from memory. Mirrors Android `warmMangaImageFile`.
    nonisolated static func warmMangaImageFile(_ file: URL, maxBytes: Int = 8 * 1024 * 1024) {
        guard maxBytes > 0,
              let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        let chunkSize = 64 * 1024
        var total = 0
        while total < maxBytes {
            let toRead = min(chunkSize, maxBytes - total)
            guard let data = try? handle.read(upToCount: toRead), !data.isEmpty else { break }
            total += data.count
            if data.count < toRead { break }
        }
    }
}

/// The neighbour page indexes to preload around `currentIndex`: a small ±1 window, clamped to
/// the volume. Mirrors Android `mangaAdjacentPreloadIndexes` (next page first, then previous).
nonisolated func mangaAdjacentPreloadIndexes(currentIndex: Int, pageCount: Int) -> [Int] {
    guard pageCount > 0 else { return [] }
    return [currentIndex + 1, currentIndex - 1].filter { $0 >= 0 && $0 < pageCount }
}
