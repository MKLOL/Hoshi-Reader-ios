//
//  NewsArticleExtractor.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Renders a page in an off-screen WKWebView and runs `news-extract.js` (shared verbatim with the
//  Android app) against its DOM. Client-rendered sites finish long after the navigation completes,
//  so the script is polled until it reports the listing or article as ready.
//

import Foundation
import WebKit

struct NewsExtractionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A listing rendered but contained no article links; shown to the user as "No articles found".
struct NewsNoArticlesError: LocalizedError {
    let url: String
    var errorDescription: String? { "No articles found on \(url)" }
}

protocol NewsArticleExtracting {
    func extractListing(source: NewsSource) async throws -> [NewsListingItem]
    func extractArticle(source: NewsSource, url: String) async throws -> ExtractedNewsArticle
}

@MainActor
final class WebViewNewsExtractor: NSObject, NewsArticleExtracting, WKNavigationDelegate {
    static let shared = WebViewNewsExtractor()

    private let pageTimeout: TimeInterval = 25
    private let pollInterval: TimeInterval = 0.4
    private var webView: WKWebView?
    private var pageFinished: CheckedContinuation<Void, Error>?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private lazy var script: String = {
        guard let url = Bundle.main.url(forResource: "news-extract", withExtension: "js"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }()

    func extractListing(source: NewsSource) async throws -> [NewsListingItem] {
        guard case .webPage(let url, let pattern) = source.listing else {
            throw NewsExtractionError(message: "\(source.name) is not a web listing")
        }
        let result = try await run(url: url, mode: "listing", hints: source.hints, pattern: pattern)
        let items = (result["items"] as? [[String: Any]]) ?? []
        if items.isEmpty {
            NSLog("[HoshiNews] No articles found on %@: %@", url, String(describing: result["debug"] ?? result["error"] ?? "no diagnostics"))
            throw NewsNoArticlesError(url: url)
        }
        var seen = Set<String>()
        return items.compactMap { item in
            guard let itemUrl = item["url"] as? String, !seen.contains(itemUrl) else { return nil }
            seen.insert(itemUrl)
            let title = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return NewsListingItem(
                url: itemUrl,
                title: (title?.isEmpty == false) ? title! : itemUrl,
                publishedAt: (item["publishedAt"] as? NSNumber)?.int64Value,
                imageUrl: item["imageUrl"] as? String
            )
        }
    }

    func extractArticle(source: NewsSource, url: String) async throws -> ExtractedNewsArticle {
        let result = try await run(url: url, mode: "article", hints: source.hints, pattern: nil)
        let text = ((result["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= Self.minArticleChars else { throw NewsExtractionError(message: "No article text found at \(url)") }
        let title = (result["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ExtractedNewsArticle(
            url: (result["url"] as? String) ?? url,
            title: (title?.isEmpty == false) ? title! : url,
            xhtml: (result["xhtml"] as? String) ?? "",
            text: text,
            publishedAt: (result["publishedAt"] as? NSNumber)?.int64Value,
            imageUrl: result["imageUrl"] as? String
        )
    }

    // MARK: - Serialized page runs

    private func run(url: String, mode: String, hints: NewsExtractionHints, pattern: String?) async throws -> [String: Any] {
        await acquire()
        defer { release() }
        guard let target = URL(string: url) else { throw NewsExtractionError(message: "Invalid URL: \(url)") }
        let view = obtainWebView()
        // Wait for onPageFinished, or give up after the page timeout. Everything here is on the
        // main actor, so the timeout task and the navigation delegate hand over the same field.
        let timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(self?.pageTimeout ?? 25))
            guard let self, let pending = self.pageFinished else { return }
            self.pageFinished = nil
            pending.resume(throwing: NewsExtractionError(message: "Timed out loading \(url)"))
        }
        defer { timeout.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.pageFinished = continuation
            view.stopLoading()
            view.load(URLRequest(url: target))
        }
        pageFinished = nil

        let options = try optionsJson(mode: mode, hints: hints, pattern: pattern)
        var deadline = Date().addingTimeInterval(pageTimeout)
        var gateExtended = false
        var last: [String: Any]?
        while Date() < deadline {
            guard webView === view else { throw NewsExtractionError(message: "The page renderer crashed while loading \(url)") }
            if let parsed = await evaluate(view, "\(script)\n;window.hoshiNewsExtract(\(options));") {
                last = parsed
                if parsed["ready"] as? Bool == true { break }
                // Acknowledging an access notice navigates through a sign-in redirect and reloads
                // the page; give that round trip its own budget once.
                if !gateExtended, parsed["gate"] as? Bool == true {
                    gateExtended = true
                    deadline = Date().addingTimeInterval(pageTimeout)
                }
            }
            try await Task.sleep(for: .seconds(pollInterval))
        }
        view.stopLoading()
        view.load(URLRequest(url: URL(string: "about:blank")!))
        guard let last else { throw NewsExtractionError(message: "Extraction script produced no result for \(url)") }
        return last
    }

    private func optionsJson(mode: String, hints: NewsExtractionHints, pattern: String?) throws -> String {
        let encoder = JSONEncoder()
        let hintsJson = String(decoding: try encoder.encode(hints), as: UTF8.self)
        let modeJson = String(decoding: try encoder.encode(mode), as: UTF8.self)
        let patternJson = try pattern.map { String(decoding: try encoder.encode($0), as: UTF8.self) } ?? "null"
        return "{\"mode\":\(modeJson),\"articleUrlPattern\":\(patternJson),\"hints\":\(hintsJson)}"
    }

    /// The script returns JSON text; nil when the page produced no value or the renderer never answered.
    private func evaluate(_ view: WKWebView, _ code: String) async -> [String: Any]? {
        let box = OnceBox()
        let text: String? = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let timeout = Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                if box.claim() { continuation.resume(returning: nil) }
            }
            view.evaluateJavaScript(code) { value, _ in
                timeout.cancel()
                if box.claim() { continuation.resume(returning: value as? String) }
            }
        }
        guard let text, let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Guards a continuation that two main-actor callbacks race to resume.
    private final class OnceBox {
        private var done = false
        func claim() -> Bool {
            if done { return false }
            done = true
            return true
        }
    }

    private func obtainWebView() -> WKWebView {
        if let webView { return webView }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.mediaTypesRequiringUserActionForPlayback = .all
        // Never attached to a window: give it a phone-sized frame so lazy layouts still render.
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        view.customUserAgent = NewsHttp.userAgent
        view.navigationDelegate = self
        webView = view
        return view
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            busy = false
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView.url?.absoluteString == "about:blank" { return }
        pageFinished?.resume()
        pageFinished = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        pageFinished?.resume(throwing: error)
        pageFinished = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        pageFinished?.resume(throwing: error)
        pageFinished = nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Untrusted pages render here; a crashed content process must fail the caller, not the app.
        pageFinished?.resume(throwing: NewsExtractionError(message: "The page renderer crashed"))
        pageFinished = nil
        if self.webView === webView { self.webView = nil }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(.allow)
    }

    private static let minArticleChars = 40
}
