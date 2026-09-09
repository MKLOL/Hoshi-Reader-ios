//
//  NewsSourceCatalog.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Built-in easy-Japanese news sources. Users can disable any of them and add their own RSS feeds
/// through `NewsSettingsStore`; those custom sources carry `builtIn = false`.
nonisolated enum NewsSourceCatalog {
    static let nhkEasyId = "nhk-easy"
    static let watanocId = "watanoc"
    static let matchaEasyId = "matcha-easy"
    static let sharedLinkId = "shared-link"

    /// NHK NEWS WEB EASY moved to a client-rendered site (NHK ONE) whose news API needs a session
    /// token and which serves the article list only inside Japan. Outside Japan it shows an access
    /// notice; the extractor clicks it, but the listing has not been reachable from abroad in
    /// testing, so the source starts disabled and says so in its name.
    static let nhkEasy = NewsSource(
        id: nhkEasyId,
        name: "NHK NEWS WEB EASY (Japan only)",
        homepage: "https://news.web.nhk/news/easy/",
        listing: .webPage(
            url: "https://news.web.nhk/news/easy/",
            articleUrlPattern: #"https://news\.web\.nhk/news/easy/(ne\d+)/\1\.html"#
        ),
        hints: NewsExtractionHints(
            articleSelectors: ["article", "main"],
            titleSelectors: ["h1"],
            removeSelectors: ["nav", "header", "footer", "aside", "video", "audio", "button"],
            readySelector: "article p, main p",
            acknowledgeSelector: "button[data-erpccontent-start-button-abroad]"
        ),
        enabledByDefault: false
    )

    static let watanoc = NewsSource(
        id: watanocId,
        name: "Watanoc",
        homepage: "https://watanoc.com/",
        listing: .rss(url: "https://watanoc.com/feed"),
        hints: NewsExtractionHints(
            articleSelectors: [".entry-content", "article"],
            titleSelectors: ["h1.entry-title", "h1"],
            removeSelectors: [".sharedaddy", ".jp-relatedposts", ".wp-block-buttons", "nav", "footer", "aside"]
        )
    )

    static let matchaEasy = NewsSource(
        id: matchaEasyId,
        name: "MATCHA Easy Japanese",
        homepage: "https://matcha-jp.com/easy",
        listing: .webPage(url: "https://matcha-jp.com/easy", articleUrlPattern: #"https://matcha-jp\.com/easy/\d+"#),
        hints: NewsExtractionHints(
            articleSelectors: [".article-body", ".p-article__body", "article", "main"],
            titleSelectors: ["h1"],
            removeSelectors: [
                "nav", "header", "footer", "aside", ".c-ad", ".ad", "[class*=\"share\"]",
                "[class*=\"breadcrumb\"]", "[class*=\"tagList\"]", "[class*=\"tag-list\"]", ".tags", "[class*=\"related\"]",
            ]
        )
    )

    static let builtIn: [NewsSource] = [nhkEasy, watanoc, matchaEasy]

    static func builtIn(id: String) -> NewsSource? { builtIn.first { $0.id == id } }

    /// Pseudo-source for article URLs shared into the app from a browser; never listed.
    static let sharedLink = NewsSource(
        id: sharedLinkId,
        name: "Shared link",
        homepage: "",
        listing: .none,
        builtIn: true,
        enabledByDefault: true
    )

    /// A user-added RSS feed. The id is derived from the URL so re-adding the same feed is idempotent.
    static func customRss(name: String, url: String) -> NewsSource {
        let trimmedUrl = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return NewsSource(
            id: "rss-" + String(sha256Hex(trimmedUrl).prefix(16)),
            name: trimmedName.isEmpty ? trimmedUrl : trimmedName,
            homepage: trimmedUrl,
            listing: .rss(url: trimmedUrl),
            builtIn: false
        )
    }

    /// The built-in source that owns `url`, or `sharedLink` when none matches.
    static func source(forUrl url: String) -> NewsSource {
        builtIn.first { source in
            guard let host = URL(string: source.homepage)?.host?.replacingOccurrences(of: "www.", with: ""), !host.isEmpty else { return false }
            return url.contains(host)
        } ?? sharedLink
    }
}
