//
//  ReaderViewModel.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  Copyright © 2026 ッツ Reader Authors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import EPUBKit
import SwiftUI
import CHoshiDicts

enum ActiveSheet: Identifiable {
    case appearance
    case chapters
    case highlights
    case statistics
    case sasayaki
    var id: Self { self }
}

struct PopupItem: Identifiable {
    let id: UUID = UUID()
    var showPopup: Bool
    var currentSelection: SelectionData?
    var lookupResults: [LookupResult] = []
    var dictionaryStyles: [String: String] = [:]
    var isVertical: Bool
    var isFullWidth: Bool
    var clearSelection: Bool
    var sasayakiCue: SasayakiMatch?
}

private struct Position {
    var index: Int
    var progress: Double
}

@Observable
@MainActor
class ReaderLoaderViewModel {
    var document: EPUBDocument?
    let book: BookMetadata
    private(set) var reservedSyncId: String?
    private var didAttemptLoad = false
    
    var rootURL: URL? {
        guard let booksFolder = try? BookStorage.getBooksDirectory(),
              let folder = book.folder else {
            return nil
        }
        return booksFolder.appendingPathComponent(folder)
    }
    
    init(book: BookMetadata) {
        self.book = book
    }
    
    func loadBook() async {
        guard !didAttemptLoad else { return }
        didAttemptLoad = true
        reservedSyncId = syncId(for: book)
        HttpSyncActiveBooks.open(reservedSyncId)
        // Keep the loading view non-interactive until map/legacy bookmark migration has applied.
        // ReaderViewModel must never capture a stale sidecar and then timestamp it as a new turn.
        await HttpSyncManager.shared.syncBookmarksBeforeReading(book: book)
        guard let root = rootURL else {
            return
        }
        
        guard let doc = try? BookStorage.loadEpub(root) else {
            return
        }
        
        var bookCopy = self.book
        bookCopy.lastAccess = Date()
        try? BookStorage.save(bookCopy, inside: root, as: FileNames.metadata)
        
        self.document = doc
    }
}

@Observable
@MainActor
class ReaderViewModel {
    let book: BookMetadata
    let document: EPUBDocument
    let rootURL: URL
    var index: Int = 0
    var currentProgress: Double = 0.0
    var activeSheet: ActiveSheet?
    var isLoading = true
    var bookInfo: BookInfo
    let bridge = WebViewBridge()
    
    // lookups
    var popups: [PopupItem] = []
    
    // stats
    var isTracking = false
    var isPaused = false { didSet { usage?.reading(isTracking && !isPaused) } }
    private(set) var usage: ReaderUsageSession?
    private var lastUsagePosition: String?
    var lastTimestamp: Date = .now
    var lastCount: Int = 0
    private var readingTracker: MangaStatisticsTracker?
    var sessionStatistics: Statistics { readingTracker?.session ?? Self.getDefaultStatistic(title: document.title ?? "") }
    var todaysStatistics: Statistics { readingTracker?.today ?? Self.getDefaultStatistic(title: document.title ?? "") }
    var allTimeStatistics: Statistics { readingTracker?.allTime ?? Self.getDefaultStatistic(title: document.title ?? "") }
    let enableStatistics: Bool
    let autostartStatistics: Bool
    
    // sasayaki
    var sasayakiPlayer: SasayakiPlayer!
    var wasPaused = false
    
    // sync
    let autoSyncEnabled: Bool
    let syncStats: Bool
    let statsSyncMode: StatisticsSyncMode
    let syncAudioBook: Bool
    /// Reader setting: show a translate button after each pre-translated sentence.
    var showSentenceTranslations: Bool
    var isSyncing = false
    private var pendingAutoExport = false
    private var debounceTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    
    // highlights
    var highlights: [Highlight] = []
    
    // navigation history
    private var backHistory: [Position] = []
    private var forwardHistory: [Position] = []
    private var currentPosition: Position { Position(index: index, progress: currentProgress) }
    var backTarget: Int? { backHistory.last.map { calculateCharacterProgress(for: $0) } }
    var forwardTarget: Int? { forwardHistory.last.map { calculateCharacterProgress(for: $0) } }
    
    init(
        book: BookMetadata,
        document: EPUBDocument,
        rootURL: URL,
        enableStatistics: Bool,
        autostartStatistics: Bool,
        autoSyncEnabled: Bool,
        syncStats: Bool,
        statsSyncMode: StatisticsSyncMode,
        syncAudioBook: Bool,
        showSentenceTranslations: Bool
    ) {
        self.book = book
        self.document = document
        self.rootURL = rootURL
        self.enableStatistics = enableStatistics
        self.autostartStatistics = autostartStatistics
        self.autoSyncEnabled = autoSyncEnabled
        self.syncStats = syncStats
        self.statsSyncMode = statsSyncMode
        self.syncAudioBook = syncAudioBook
        self.showSentenceTranslations = showSentenceTranslations
        
        if let bookmark = BookStorage.loadBookmark(root: rootURL) {
            index = bookmark.chapterIndex
            currentProgress = bookmark.progress
        } else {
            index = 0
            currentProgress = 0.0
        }
        
        if let b = BookStorage.loadBookInfo(root: rootURL) {
            bookInfo = b
        } else {
            bookInfo = BookInfo(characterCount: 0, chapterInfo: [:])
        }
        
        usage = ReaderUsageSession(book: book)
        if enableStatistics {
            loadStatistics()
        }
        
        if autostartStatistics {
            startTracking()
        }
        
        sasayakiPlayer = SasayakiPlayer(
            rootURL: rootURL,
            bridge: bridge,
            loadChapter: { [weak self] chapterIndex, progress in
                self?.flushStats()
                self?.loadChapter(index: chapterIndex, progress: progress)
                self?.resetTrackingBaseline()
            },
            getCurrentIndex: { [weak self] in
                self?.index ?? 0
            },
            onPlayback: { [weak self] in
                guard self?.syncAudioBook == true else { return }
                self?.scheduleAutoExport()
            }
        )
        
        highlights = BookStorage.loadHighlights(root: rootURL) ?? []

        preloadSentenceTranslationsAndReloadIfNeeded()
    }
    
    var currentChapterCount: Int {
        guard document.spine.items.indices.contains(index),
              let manifestItem = document.manifest.items[document.spine.items[index].idref],
              let chapterInfo = bookInfo.chapterInfo[manifestItem.path] else {
            return 0
        }
        return chapterInfo.currentTotal + chapterInfo.chapterCount
    }
    
    var currentCharacter: Int {
        guard document.spine.items.indices.contains(index),
              let manifestItem = document.manifest.items[document.spine.items[index].idref],
              let chapterInfo = bookInfo.chapterInfo[manifestItem.path] else {
            return 0
        }
        
        // Clamp: a synced/corrupt bookmark can carry an out-of-[0,1] progress; Int(Double) traps on
        // a non-finite or out-of-range product.
        let p = currentProgress.isFinite ? min(max(currentProgress, 0), 1) : 0
        return chapterInfo.currentTotal + Int(Double(chapterInfo.chapterCount) * p)
    }

    var coverURL: URL? {
        if let book = BookStorage.loadMetadata(root: rootURL) {
            return book.coverURL
        }
        return nil
    }
    
    private var currentChapterURL: URL? {
        guard document.spine.items.indices.contains(index) else {
            return nil
        }
        
        let item = document.spine.items[index]
        guard let manifestItem = document.manifest.items[item.idref] else {
            return nil
        }
        return document.contentDirectory.appendingPathComponent(manifestItem.path)
    }
    
    private var chapterRange: (start: Int, end: Int)? {
        guard document.spine.items.indices.contains(index),
              let manifestItem = document.manifest.items[document.spine.items[index].idref],
              let info = bookInfo.chapterInfo[manifestItem.path] else {
            return nil
        }
        return (info.currentTotal, info.currentTotal + info.chapterCount)
    }
    
    func handleRestoreCompleted() {
        if !sasayakiPlayer.hasAudio {
            sasayakiPlayer.restoreAudio()
        }
        isLoading = false
        sasayakiPlayer.handleRestoreCompleted(currentIndex: index)
    }
    
    func importSasayakiAudio(from url: URL) throws {
        try sasayakiPlayer.importAudio(from: url)
    }
    
    func syncOnOpen() async {
        if autoSyncEnabled {
            let result = try? await SyncManager.shared.syncBook(
                book: book,
                direction: nil,
                syncStats: syncStats,
                statsSyncMode: statsSyncMode,
                syncAudioBook: syncAudioBook,
                importOnly: true
            )
            
            if case .imported = result {
                reloadAfterImport()
            }
        }
        loadCurrentChapter()
        resetTrackingBaseline()
    }
    
    func syncAfterForeground() async {
        await HttpSyncManager.shared.syncBookmarksBeforeReading(book: book)
        reloadAfterHttpBookmark()
        guard autoSyncEnabled, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        
        let result = try? await SyncManager.shared.syncBook(
            book: book,
            direction: nil,
            syncStats: syncStats,
            statsSyncMode: statsSyncMode,
            syncAudioBook: syncAudioBook,
            importOnly: true
        )
        
        if case .imported = result {
            reloadAfterImport()
            loadCurrentChapter()
            resetTrackingBaseline()
        }
    }
    
    func flushAutoSync() async {
        debounceTask?.cancel()
        debounceTask = nil
        await HttpSyncManager.shared.flushBookmarkSync()
        await runAutoExport(direction: .exportToTtu)
    }
    
    func updateProgress(_ progress: Double) {
        currentProgress = progress
    }
    
    func saveBookmark(progress: Double) {
        persistBookmark(progress: progress)
        let position = "\(index):\(currentCharacter)"
        if let previous = lastUsagePosition, previous != position { usage?.record(.page, chapter: index + 1, character: currentCharacter) }
        lastUsagePosition = position
        flushStats()
    }
    
    func jumpToCharacter(_ characterCount: Int) {
        guard let result = bookInfo.resolveCharacterPosition(characterCount) else { return }
        recordPosition()
        navigate(to: Position(index: result.spineIndex, progress: result.progress))
    }
    
    func jumpToChapter(index: Int, fragment: String? = nil) {
        recordPosition()
        navigate(to: Position(index: index, progress: 0), fragment: fragment)
    }
    
    func jumpToLink(_ url: URL) -> Bool {
        guard let destination = resolveSpineDestination(for: url) else {
            return false
        }
        
        recordPosition()
        flushStats()
        
        if destination.spineIndex == self.index {
            if let fragment = destination.fragment {
                bridge.send(.jumpToFragment(fragment))
            } else {
                persistBookmark(progress: 0)
                bridge.send(.restoreProgress(0))
                resetTrackingBaseline()
            }
            return true
        }
        
        loadChapter(index: destination.spineIndex, progress: 0, fragment: destination.fragment)
        resetTrackingBaseline()
        return true
    }
    
    func syncProgressAfterLinkJump(_ progress: Double) {
        persistBookmark(progress: progress)
        resetTrackingBaseline()
    }
    
    func nextChapter() -> Bool {
        guard index < document.spine.items.count - 1 else { return false }
        loadChapter(index: index + 1, progress: 0)
        flushStats()
        return true
    }
    
    func previousChapter() -> Bool {
        guard index > 0 else { return false }
        loadChapter(index: index - 1, progress: 1)
        flushStats()
        return true
    }
    
    func handleTextSelection(_ selection: SelectionData, maxResults: Int, scanLength: Int, isVertical: Bool, isFullWidth: Bool, autoPause: Bool) -> Int? {
        let lookupResults = LookupEngine.shared.lookup(selection.text, maxResults: maxResults, scanLength: scanLength)
        usage?.record(.lookup, text: lookupResults.first.map { cxxStringToSwift($0.matched) } ?? selection.text,
            term: lookupResults.first.map { cxxStringToSwift($0.term.expression) },
            source: popups.contains { $0.showPopup } ? "popup" : "page", found: !lookupResults.isEmpty, chapter: index + 1, character: currentCharacter)
        var dictionaryStyles: [String: String] = [:]
        for style in LookupEngine.shared.getStyles() {
            dictionaryStyles[cxxStringToSwift(style.dict_name)] = cxxStringToSwift(style.styles)
        }
        var cue: SasayakiMatch? = nil
        if sasayakiPlayer.hasAudio, let offset = selection.normalizedOffset {
            cue = sasayakiPlayer.findCue(chapterIndex: index, offset: offset)
        }
        let popup = PopupItem(
            showPopup: false,
            currentSelection: selection,
            lookupResults: lookupResults,
            dictionaryStyles: dictionaryStyles,
            isVertical: isVertical,
            isFullWidth: isFullWidth,
            clearSelection: false,
            sasayakiCue: cue
        )
        popups.append(popup)
        
        if let firstResult = lookupResults.first {
            if sasayakiPlayer.isPlaying {
                if autoPause {
                    sasayakiPlayer.togglePlayback()
                    wasPaused = true
                } else {
                    wasPaused = false
                }
            }
            withAnimation(.default.speed(2.2)) {
                popups = popups.map {
                    var p = $0
                    if p.id == popup.id {
                        p.showPopup = true
                    }
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
            for index in popups.indices {
                popups[index].showPopup = false
            }
        } completion: {
            self.popups.removeAll { popupIds.contains($0.id) }
            if self.popups.isEmpty {
                if self.wasPaused, !self.sasayakiPlayer.isPlaying {
                    self.sasayakiPlayer.togglePlayback()
                }
                self.wasPaused = false
            }
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
    
    func clearSelection() {
        bridge.send(.clearSelection)
    }
    
    func startTracking() {
        usage?.reading(true)
        isTracking = true
        lastTimestamp = .now
        lastCount = currentCharacter
        readingTracker?.start(currentPage: currentCharacter)
    }
    
    func stopTracking() {
        guard isTracking else { return }
        flushStats()
        readingTracker?.pause(currentPage: currentCharacter)
        usage?.reading(false)
        isTracking = false
    }
    
    // https://github.com/ttu-ttu/ebook-reader/blob/2703b50ec52b2e4f70afcab725c0f47dd8a66bf4/apps/web/src/lib/components/book-reader/book-reading-tracker/book-reading-tracker.svelte#L72
    func updateStats() {
        guard isTracking, !isPaused else { return }
        readingTracker?.update(currentPage: currentCharacter)
    }

    func resetTrackingBaseline() {
        readingTracker?.resetBaseline(currentPage: currentCharacter)
        lastCount = currentCharacter
        lastTimestamp = .now
    }
    
    func addHighlight(_ color: HighlightColor, _ creation: HighlightData) {
        guard let range = chapterRange else { return }
        let highlight = Highlight(
            id: creation.id,
            character: range.start + creation.start,
            offset: creation.offset,
            text: creation.text,
            color: color,
            createdAt: Date()
        )
        highlights.append(highlight)
        saveHighlights()
        syncHighlights()
    }
    
    func removeHighlight(_ highlight: Highlight) {
        highlights.removeAll { $0.id == highlight.id }
        saveHighlights()
        syncHighlights()
        if let range = chapterRange,
           highlight.character >= range.start,
           highlight.character < range.end {
            bridge.send(.removeHighlight(highlight.id.uuidString))
        }
    }
    
    func navigateBackwards() {
        let target = backHistory.removeLast()
        forwardHistory.append(currentPosition)
        navigate(to: target)
    }
    
    func navigateForwards() {
        let target = forwardHistory.removeLast()
        backHistory.append(currentPosition)
        navigate(to: target)
    }
    
    func clearForwardHistory() {
        if backHistory.isEmpty {
            forwardHistory.removeAll()
        }
    }
    
    private func navigate(to position: Position, fragment: String? = nil) {
        flushStats()
        if position.index == index && fragment == nil {
            persistBookmark(progress: position.progress)
            bridge.send(.restoreProgress(position.progress))
        } else {
            loadChapter(index: position.index, progress: position.progress, fragment: fragment)
        }
        resetTrackingBaseline()
    }
    
    private func persistBookmark(progress: Double) {
        currentProgress = progress
        bridge.updateProgress(progress)
        let bookmark = Bookmark(
            chapterIndex: index,
            progress: progress,
            characterCount: currentCharacter,
            lastModified: Date()
        )
        try? BookStorage.save(bookmark, inside: rootURL, as: FileNames.bookmark)
        scheduleAutoExport()
        HttpSyncManager.shared.onPageTurnPersisted(book: book)
    }

    private func loadChapter(index: Int, progress: Double, fragment: String? = nil) {
        isLoading = true
        sasayakiPlayer.prepareTransition()
        self.index = index
        persistBookmark(progress: progress)
        if let url = currentChapterURL {
            let cues = sasayakiPlayer.hasMatch ? sasayakiPlayer.cues(for: index) : nil
            let highlights = chapterHighlights()
            let anchors = chapterSentenceAnchors()
            bridge.updateState(url: url, progress: progress, sasayakiCues: cues, highlights: highlights, sentenceAnchors: anchors)
            bridge.send(.loadChapter(url: url, progress: progress, fragment: fragment, sasayakiCues: cues, highlights: highlights, sentenceAnchors: anchors))
        }
    }
    
    private func loadCurrentChapter() {
        if let url = currentChapterURL {
            let cues = sasayakiPlayer.hasMatch ? sasayakiPlayer.cues(for: index) : nil
            let highlights = chapterHighlights()
            let anchors = chapterSentenceAnchors()
            bridge.updateState(url: url, progress: currentProgress, sasayakiCues: cues, highlights: highlights, sentenceAnchors: anchors)
            bridge.send(.loadChapter(url: url, progress: currentProgress, fragment: nil, sasayakiCues: cues, highlights: highlights, sentenceAnchors: anchors))
        }
    }
    
    private func reloadAfterImport() {
        if let bookmark = BookStorage.loadBookmark(root: rootURL) {
            index = bookmark.chapterIndex
            currentProgress = bookmark.progress
        }
        if enableStatistics {
            loadStatistics()
        }
        if syncAudioBook {
            sasayakiPlayer.reloadPlayback()
        }
    }

    func reloadAfterHttpBookmark() {
        guard let bookmark = BookStorage.loadBookmark(root: rootURL) else { return }
        index = bookmark.chapterIndex
        currentProgress = bookmark.progress
        loadCurrentChapter()
        resetTrackingBaseline()
    }
    
    private func scheduleAutoExport() {
        guard autoSyncEnabled else { return }
        pendingAutoExport = true
        guard debounceTask == nil else { return }
        debounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                return
            }
            self?.debounceTask = nil
            await self?.runAutoExport(direction: .exportToTtu)
        }
    }
    
    private func runAutoExport(direction: SyncDirection?) async {
        if let existing = exportTask {
            await existing.value
        }
        
        guard pendingAutoExport else { return }
        pendingAutoExport = false
        
        let task = Task { [weak self] in
            guard let self else { return }
            _ = try? await SyncManager.shared.syncBook(
                book: self.book,
                direction: direction,
                syncStats: self.syncStats,
                statsSyncMode: self.statsSyncMode,
                syncAudioBook: self.syncAudioBook
            )
        }
        exportTask = task
        await task.value
        exportTask = nil
    }
    
    private func resolveSpineDestination(for url: URL) -> (spineIndex: Int, fragment: String?)? {
        let targetPath = normalizedFilePath(url)
        
        for (spineIndex, spineItem) in document.spine.items.enumerated() {
            guard let manifestItem = document.manifest.items[spineItem.idref] else {
                continue
            }
            let chapterPath = normalizedFilePath(document.contentDirectory.appendingPathComponent(manifestItem.path))
            if chapterPath == targetPath {
                return (spineIndex, normalizeFragment(url.fragment))
            }
        }
        
        return nil
    }
    
    private func normalizedFilePath(_ url: URL) -> String {
        let normalized = url.standardizedFileURL.resolvingSymlinksInPath().path
        return normalized.removingPercentEncoding ?? normalized
    }
    
    private func normalizeFragment(_ fragment: String?) -> String? {
        guard let fragment, !fragment.isEmpty else {
            return nil
        }
        return fragment.removingPercentEncoding ?? fragment
    }
    
    private func flushStats() {
        guard isTracking, !isPaused else { return }
        updateStats()
        saveStats()
    }
    
    // https://github.com/ttu-ttu/ebook-reader/blob/2703b50ec52b2e4f70afcab725c0f47dd8a66bf4/apps/web/src/lib/components/book-reader/book-reading-tracker/book-reading-tracker.svelte#L722
    private func saveStats() {
        if let rows = readingTracker?.statisticsForPersistence() {
            try? ReadingStatisticsStore.save(rows, root: rootURL)
        }
        scheduleAutoExport()
    }

    private func loadStatistics() {
        // Flush the live session before replacing the tracker after a sync.
        if readingTracker != nil { flushStats() }
        readingTracker = MangaStatisticsTracker(title: document.title ?? "", initialStatistics: ReadingStatisticsStore.reading(root: rootURL), enabled: true, device: .current)
        if isTracking { readingTracker?.start(currentPage: currentCharacter) }
    }

    func persistReadingTime() {
        flushStats()
        HttpReadingStatisticsSync.shared.schedule(root: rootURL, delay: .milliseconds(1500))
    }

    /// The current chapter's pre-translated sentences, as JSON for `hoshiTranslations.apply`.
    ///
    /// `nil` when the book has no blob, when the reader setting is off, or when this chapter has
    /// no translated sentences — all of which mean "place no buttons".
    private func chapterSentenceAnchors() -> String? {
        guard showSentenceTranslations,
              let folder = book.folder,
              let bookSyncId = syncId(for: book) else { return nil }
        let anchors = EpubTranslationStore.shared.anchors(
            folder: folder,
            expectedSyncId: bookSyncId,
            spineCount: document.spine.items.count,
            spine: index
        )
        guard !anchors.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(anchors),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }

    /// Resolves a pressed button to its cached translation. Nil when the blob changed underneath
    /// the rendered page (the reader then does nothing rather than guessing).
    func sentenceTranslation(id: String) -> SentenceTranslation? {
        guard showSentenceTranslations,
              let folder = book.folder,
              let bookSyncId = syncId(for: book) else { return nil }
        return EpubTranslationStore.shared.lookup(
            id: id,
            folder: folder,
            expectedSyncId: bookSyncId,
            spineCount: document.spine.items.count
        )
    }

    /// Applies the appearance toggle to the already-open reader. Reloading at the current progress
    /// also tears down existing buttons immediately when disabled.
    func setSentenceTranslationsEnabled(_ enabled: Bool) {
        guard showSentenceTranslations != enabled else { return }
        showSentenceTranslations = enabled
        if enabled {
            preloadSentenceTranslationsAndReloadIfNeeded()
        } else {
            loadCurrentChapter()
        }
    }

    private func preloadSentenceTranslationsAndReloadIfNeeded() {
        guard showSentenceTranslations,
              let folder = book.folder,
              let bookSyncId = syncId(for: book) else { return }
        let spineCount = document.spine.items.count
        Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) {
                EpubTranslationStore.shared.preload(
                    folder: folder,
                    expectedSyncId: bookSyncId,
                    spineCount: spineCount
                )
            }.value
            guard loaded, let self, self.showSentenceTranslations else { return }
            self.loadCurrentChapter()
        }
    }

    private func chapterHighlights() -> String? {
        guard let range = chapterRange else { return nil }
        let list = highlights.filter { $0.character >= range.start && $0.character < range.end }
        if list.isEmpty {
            return nil
        }
        guard let data = try? JSONEncoder().encode(list),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }
    
    private func saveHighlights() {
        try? BookStorage.save(highlights, inside: rootURL, as: FileNames.highlights)
    }
    
    private func syncHighlights() {
        bridge.updateHighlights(chapterHighlights())
    }
    
    private func recordPosition() {
        backHistory.append(currentPosition)
        forwardHistory.removeAll()
    }
    
    private func calculateCharacterProgress(for position: Position) -> Int {
        // A Position can be stale (e.g. a bookmark synced from a different EPUB build) or reference
        // a chapter whose info isn't populated yet; degrade to 0 instead of trapping.
        guard document.spine.items.indices.contains(position.index) else { return 0 }
        let spineItem = document.spine.items[position.index]
        guard let manifestItem = document.manifest.items[spineItem.idref],
              let chapterInfo = bookInfo.chapterInfo[manifestItem.path] else { return 0 }
        let p = position.progress.isFinite ? min(max(position.progress, 0), 1) : 0
        return chapterInfo.currentTotal + Int(Double(chapterInfo.chapterCount) * p)
    }
    
    private static func getDefaultStatistic(title: String) -> Statistics {
        return Statistics(title: title, dateKey: Self.formattedDate(date: .now), charactersRead: 0, readingTime: 0, minReadingSpeed: 0, altMinReadingSpeed: 0, lastReadingSpeed: 0, maxReadingSpeed: 0, lastStatisticModified: 0)
    }
    
    private static func deduplicateStatistics(_ statistics: [Statistics]) -> [Statistics] {
        var grouped: [String: Statistics] = [:]
        for statistic in statistics {
            if let existing = grouped[statistic.dateKey] {
                if statistic.lastStatisticModified > existing.lastStatisticModified {
                    grouped[statistic.dateKey] = statistic
                }
            } else {
                grouped[statistic.dateKey] = statistic
            }
        }
        return Array(grouped.values)
    }
    
    private static func formattedDate(date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone.current
        formatter.formatOptions = [.withFullDate]
        return formatter.string(from: date)
    }
}
