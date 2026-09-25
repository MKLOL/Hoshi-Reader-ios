//
//  NewsModels.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Models for the News tab. Mirrors the Android `features/news` models so the two apps agree on
//  source ids, article ids (sha256 of the URL) and the saved-article record.
//

import CryptoKit
import Foundation

/// Where a source's article list comes from.
nonisolated enum NewsListing: Codable, Hashable, Sendable {
    /// Fetched with a plain GET and parsed by `RssFeedParser`.
    case rss(url: String)
    /// Rendered in a hidden web view; anchors matching `articleUrlPattern` are the articles.
    case webPage(url: String, articleUrlPattern: String)
    /// No listing: the source only describes how to extract articles the user shares by URL.
    case none
}

/// Selectors the article extractor tries first for a source before falling back to heuristics.
nonisolated struct NewsExtractionHints: Codable, Hashable, Sendable {
    var articleSelectors: [String] = []
    var titleSelectors: [String] = []
    var removeSelectors: [String] = []
    /// Selector that must exist before a client-rendered article is considered loaded.
    var readySelector: String? = nil
    /// Selector of a one-time access-notice button the extractor may click once per page load
    /// (NHK ONE's "For users abroad — I understand"). Nil for every other source.
    var acknowledgeSelector: String? = nil
}

nonisolated struct NewsSource: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let homepage: String
    let listing: NewsListing
    var hints: NewsExtractionHints = NewsExtractionHints()
    /// ISO 639-1 language of the articles; written into the generated EPUB.
    var language: String = "ja"
    var builtIn: Bool = true
    /// Built-ins that cannot work for most users (geo-restricted) start switched off.
    var enabledByDefault: Bool = true
}

/// One entry of a source's listing before it is saved.
nonisolated struct NewsArticle: Codable, Hashable, Identifiable, Sendable {
    /// Stable id derived from the URL, see `NewsArticle.id(for:)`.
    let id: String
    let sourceId: String
    let url: String
    var title: String
    /// Epoch milliseconds, or nil when the listing carried no date.
    var publishedAt: Int64? = nil
    var summary: String? = nil
    var imageUrl: String? = nil
    /// Epoch milliseconds when the entry was last seen in a listing.
    var fetchedAt: Int64

    static func id(for url: String) -> String {
        String(sha256Hex(url.trimmingCharacters(in: .whitespacesAndNewlines)).prefix(24))
    }

    var publishedDate: Date? { publishedAt.map { Date(timeIntervalSince1970: Double($0) / 1000) } }
}

/// State of an article the user asked to keep.
nonisolated struct SavedNewsArticle: Codable, Hashable, Sendable {
    let articleId: String
    let bookId: UUID
    let sourceId: String
    let url: String
    let title: String
    let savedAt: Int64
    var translation: NewsTranslationRecord? = nil
}

/// Outcome of the last pre-translation run for a saved article.
nonisolated struct NewsTranslationRecord: Codable, Hashable, Sendable {
    let model: String
    let sentenceCount: Int
    let translatedCount: Int
    let completedAt: Int64
    let uploaded: Bool
}

/// Everything the article extractor returns for one page.
nonisolated struct ExtractedNewsArticle: Sendable {
    let url: String
    let title: String
    /// Well-formed XHTML fragment (the article container serialized by XMLSerializer).
    let xhtml: String
    /// Plain text fallback used when `xhtml` cannot be parsed.
    let text: String
    var publishedAt: Int64? = nil
    var imageUrl: String? = nil
    var titleXhtml: String? = nil
}

/// One entry read from a listing page or feed before it becomes a `NewsArticle`.
nonisolated struct NewsListingItem: Equatable, Sendable {
    let url: String
    let title: String
    var publishedAt: Int64? = nil
    var summary: String? = nil
    var imageUrl: String? = nil
}

nonisolated func sha256Hex(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

nonisolated func nowEpochMillis() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
