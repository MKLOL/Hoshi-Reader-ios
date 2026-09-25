//
//  NewsStore.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Coordinates listings, saved articles and their conversion into books. Saving writes a
//  self-contained EPUB directory through `NewsArticleEpubWriter` and registers it through
//  `NewsBookImporter`; from then on the article is an ordinary book that the reader, sync and
//  shelves handle without knowing where it came from.
//

import Foundation
import OSLog

@Observable
@MainActor
final class NewsStore {
    private let log = Logger(subsystem: "com.dragosristache.hoshi", category: "News")
    static let shared = NewsStore()

    private(set) var articles: [NewsArticle] = []
    private(set) var saved: [String: SavedNewsArticle] = [:]
    private(set) var refreshing: Set<String> = []
    private(set) var saving: Set<String> = []
    /// Per-source error from the last refresh, keyed by source id.
    private(set) var sourceErrors: [String: String] = [:]
    private(set) var refreshedAt: [String: Int64] = [:]
    private(set) var loaded = false

    private let feedStore: NewsFeedStore
    private let settings: NewsSettingsStore
    private let extractor: NewsArticleExtracting
    private let http = NewsHttp()
    private var refreshTask: Task<Void, Never>?
    private var saveTasks: [String: Task<SavedNewsArticle, Error>] = [:]

    init(feedStore: NewsFeedStore = .shared, settings: NewsSettingsStore = .shared, extractor: NewsArticleExtracting? = nil) {
        self.feedStore = feedStore
        self.settings = settings
        self.extractor = extractor ?? WebViewNewsExtractor.shared
    }

    func load() {
        let store = feedStore
        articles = store.loadArticles()
        saved = Dictionary(uniqueKeysWithValues: store.loadSaved().map { ($0.articleId, $0) })
        refreshedAt = store.refreshedAt()
        loaded = true
    }

    /// Forgets saved records whose book was deleted from the shelf.
    func reconcileSavedBooks() {
        let records = feedStore.loadSaved()
        guard !records.isEmpty else { return }
        let ids = Set(((try? BookStorage.loadAllBooks()) ?? []).map(\.id))
        for record in records where !ids.contains(record.bookId) {
            feedStore.removeSaved(articleId: record.articleId)
        }
        load()
    }

    /// Refreshes every enabled source, one at a time so the hidden web view is never contended.
    func refreshAll(force: Bool = false) {
        guard refreshTask == nil else { return }
        refreshTask = Task {
            defer { refreshTask = nil }
            let enabled = settings.enabledSources
            let now = nowEpochMillis()
            for source in enabled where force || now - (refreshedAt[source.id] ?? 0) > Self.staleAfterMillis {
                await refreshSource(source)
            }
            let enabledIds = Set(enabled.map(\.id))
            for sourceId in Set(articles.map(\.sourceId)) where !enabledIds.contains(sourceId) {
                feedStore.removeSourceArticles(sourceId: sourceId)
            }
            load()
        }
    }

    func refreshSource(_ source: NewsSource) async {
        refreshing.insert(source.id)
        defer { refreshing.remove(source.id) }
        do {
            let items: [NewsListingItem]
            switch source.listing {
            case .rss(let url):
                let data = try await http.getData(url, maxBytes: 4 * 1024 * 1024)
                items = await Task.detached { RssFeedParser.parse(data) }.value
            case .webPage:
                items = try await extractor.extractListing(source: source)
            case .none:
                return
            }
            guard !items.isEmpty else { throw NewsNoArticlesError(url: source.homepage) }
            let fetchedAt = nowEpochMillis()
            var seen = Set<String>()
            let fresh = items.filter { seen.insert($0.url).inserted }.sorted { ($0.publishedAt ?? Int64.min) > ($1.publishedAt ?? Int64.min) }.prefix(Self.maxArticlesPerSource).map { item in
                NewsArticle(
                    id: NewsArticle.id(for: item.url), sourceId: source.id, url: item.url, title: item.title,
                    publishedAt: item.publishedAt, summary: item.summary, imageUrl: item.imageUrl, fetchedAt: fetchedAt
                )
            }
            feedStore.replaceSourceArticles(sourceId: source.id, articles: Array(fresh), refreshedAt: fetchedAt)
            sourceErrors.removeValue(forKey: source.id)
        } catch is CancellationError {
            return
        } catch let error as NewsNoArticlesError {
            _ = error
            sourceErrors[source.id] = "No articles found."
        } catch {
            sourceErrors[source.id] = "Could not load: \(error.localizedDescription)"
        }
        load()
    }

    /// "Want to read": downloads the article, writes it as a book and puts it on the News shelf.
    /// Returns the saved record; an article saved earlier is returned as-is.
    func saveArticle(_ article: NewsArticle) async throws -> SavedNewsArticle {
        if let inFlight = saveTasks[article.id] { return try await inFlight.value }
        let task = Task { try await performSave(article) }
        saveTasks[article.id] = task
        defer { saveTasks.removeValue(forKey: article.id) }
        return try await task.value
    }

    /// An article the user shared into the app by URL, attributed to the built-in source that owns
    /// the host so its extraction hints apply.
    func saveSharedUrl(_ url: String) async throws -> SavedNewsArticle {
        let source = NewsSourceCatalog.source(forUrl: url)
        return try await saveArticle(NewsArticle(id: NewsArticle.id(for: url), sourceId: source.id, url: url, title: url, fetchedAt: nowEpochMillis()))
    }

    func recordTranslation(articleId: String, record: NewsTranslationRecord) {
        feedStore.updateSaved(articleId: articleId) { saved in
            var updated = saved
            updated.translation = record
            return updated
        }
        load()
    }

    private func performSave(_ article: NewsArticle) async throws -> SavedNewsArticle {
        if let existing = feedStore.saved(articleId: article.id) {
            if NewsBookImporter.bookExists(id: existing.bookId) { return existing }
            feedStore.removeSaved(articleId: article.id)
        }
        let source = settings.sources.first { $0.id == article.sourceId }
            ?? (article.sourceId == NewsSourceCatalog.sharedLinkId ? NewsSourceCatalog.sharedLink : nil)
            ?? NewsSourceCatalog.builtIn(id: article.sourceId)
        guard let source else { throw NewsExtractionError(message: "Unknown source \(article.sourceId)") }
        saving.insert(article.id)
        defer { saving.remove(article.id) }

        let extracted = try await extractor.extractArticle(source: source, url: article.url)
        let body = await Task.detached {
            NewsArticleXhtml.sanitize(extracted.xhtml, fullWidthDigits: source.language == "ja") ?? NewsArticleXhtml.paragraphs(fromText: extracted.text, fullWidthDigits: source.language == "ja")
        }.value
        var cover: Data?
        if let imageUrl = extracted.imageUrl ?? article.imageUrl {
            cover = try? await http.getData(imageUrl, maxBytes: 3 * 1024 * 1024)
        }
        let title = extracted.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? article.title : extracted.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("NewsImport-\(UUID().uuidString)", isDirectory: true)
        let input = NewsArticleEpubWriter.Input(
            title: title, bodyXhtml: body, sourceName: source.name, sourceUrl: article.url,
            language: source.language, publishedAt: extracted.publishedAt ?? article.publishedAt, cover: cover, titleXhtml: extracted.titleXhtml
        )
        try await Task.detached { try NewsArticleEpubWriter.write(to: staging, input: input) }.value
        let book = try NewsBookImporter.register(stagingRoot: staging, folderName: NewsBookImporter.folderName(title: title, url: article.url))
        do {
            try NewsBookImporter.addToNewsShelf(book)
        } catch {
            // The book is registered and readable either way; only its shelf placement failed.
            log.error("Could not place \(book.title ?? book.folder ?? book.id.uuidString, privacy: .public) on the News shelf: \(error.localizedDescription, privacy: .public)")
        }
        let record = SavedNewsArticle(articleId: article.id, bookId: book.id, sourceId: source.id, url: article.url, title: title, savedAt: nowEpochMillis())
        feedStore.upsertSaved(record)
        saved[article.id] = record
        return record
    }

    private static let staleAfterMillis: Int64 = 30 * 60 * 1000
    private static let maxArticlesPerSource = 60
}
