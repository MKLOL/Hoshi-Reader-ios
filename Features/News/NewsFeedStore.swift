//
//  NewsFeedStore.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  On-device cache of the news listings and the articles the user kept. Lives in its own `News/`
//  directory next to `Books/`, so nothing here is visible to the EPUB or manga code paths or to
//  sync. Saved articles reference their book by id; the book itself is an ordinary EPUB directory.
//

import Foundation

nonisolated final class NewsFeedStore: @unchecked Sendable {
    static let shared = NewsFeedStore()

    private let lock = NSLock()
    private let directoryOverride: URL?

    init(directory: URL? = nil) {
        directoryOverride = directory
    }

    private struct FeedFile: Codable {
        var version: Int = 1
        var articles: [NewsArticle] = []
        var refreshedAt: [String: Int64] = [:]
    }

    private struct SavedFile: Codable {
        var version: Int = 1
        var saved: [SavedNewsArticle] = []
    }

    private var directory: URL {
        get throws {
            if let directoryOverride { return directoryOverride }
            // Same location BookStorage uses (Application Support), resolved here because this
            // store is read off the main actor.
            guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw NewsHttpError(message: "Application Support directory not found")
            }
            return appSupport.appendingPathComponent("News", isDirectory: true)
        }
    }

    func loadArticles() -> [NewsArticle] { readFeed().articles.sorted(by: Self.newestFirst) }

    static func newestFirst(_ lhs: NewsArticle, _ rhs: NewsArticle) -> Bool {
        let l = lhs.publishedAt ?? Int64.min
        let r = rhs.publishedAt ?? Int64.min
        return l != r ? l > r : lhs.id < rhs.id
    }

    func refreshedAt() -> [String: Int64] { readFeed().refreshedAt }

    /// Replaces the cached listing of one source, keeping other sources' entries untouched.
    func replaceSourceArticles(sourceId: String, articles: [NewsArticle], refreshedAt: Int64) {
        lock.withLock {
            var feed = readFeed()
            let kept = feed.articles.filter { $0.sourceId != sourceId }
            let merged = (kept + articles.filter { $0.sourceId == sourceId })
                .sorted(by: Self.newestFirst)
            feed.articles = Array(merged.prefix(Self.maxCachedArticles))
            feed.refreshedAt[sourceId] = refreshedAt
            writeFeed(feed)
        }
    }

    func removeSourceArticles(sourceId: String) {
        lock.withLock {
            var feed = readFeed()
            feed.articles.removeAll { $0.sourceId == sourceId }
            feed.refreshedAt.removeValue(forKey: sourceId)
            writeFeed(feed)
        }
    }

    func loadSaved() -> [SavedNewsArticle] { readSaved().saved }

    func saved(articleId: String) -> SavedNewsArticle? { loadSaved().first { $0.articleId == articleId } }

    func upsertSaved(_ saved: SavedNewsArticle) {
        lock.withLock {
            var file = readSaved()
            file.saved.removeAll { $0.articleId == saved.articleId }
            file.saved.append(saved)
            writeSaved(file)
        }
    }

    func updateSaved(articleId: String, transform: (SavedNewsArticle) -> SavedNewsArticle) {
        lock.withLock {
            var file = readSaved()
            file.saved = file.saved.map { $0.articleId == articleId ? transform($0) : $0 }
            writeSaved(file)
        }
    }

    func removeSaved(articleId: String) {
        lock.withLock {
            var file = readSaved()
            file.saved.removeAll { $0.articleId == articleId }
            writeSaved(file)
        }
    }

    private func readFeed() -> FeedFile { read(FeedFile.self, name: Self.feedFile) ?? FeedFile() }
    private func readSaved() -> SavedFile { read(SavedFile.self, name: Self.savedFile) ?? SavedFile() }
    private func writeFeed(_ feed: FeedFile) { write(feed, name: Self.feedFile) }
    private func writeSaved(_ file: SavedFile) { write(file, name: Self.savedFile) }

    private func read<T: Decodable>(_ type: T.Type, name: String) -> T? {
        guard let url = try? directory.appendingPathComponent(name), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, name: String) {
        guard let directory = try? directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    private static let feedFile = "feed.json"
    private static let savedFile = "saved.json"
    private static let maxCachedArticles = 600
}
