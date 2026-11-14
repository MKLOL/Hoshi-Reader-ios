//
//  ReaderWebView.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import WebKit
import SwiftUI
import UIKit

enum NavigationDirection {
    case forward
    case backward
}

struct SelectionData {
    let text: String
    let sentence: String
    let rect: CGRect
    var normalizedOffset: Int?
    /// The tapped OCR block's true writing orientation (manga only, from the mokuro data).
    /// `nil` when the source can't report it — callers fall back to the rect-aspect heuristic.
    var verticalBlock: Bool?
}

struct HighlightData {
    let id: UUID
    let start: Int
    let offset: Int
    let text: String
}

enum WebViewCommand {
    case loadChapter(url: URL, progress: Double, fragment: String?, sasayakiCues: String? = nil, highlights: String? = nil, sentenceAnchors: String? = nil)
    case restoreProgress(Double)
    case jumpToFragment(String)
    case clearSelection
    case updateTextColor(String?)
    case updateSasayakiColors(textHex: String, backgroundHex: String)
    case applySasayakiCues(String, completion: (() -> Void)? = nil)
    case highlightSasayakiCue(id: String, reveal: Bool)
    case clearSasayakiCue
    case removeHighlight(String)
}

@Observable
@MainActor
class WebViewBridge {
    private(set) var chapterURL: URL?
    private(set) var progress: Double = 0
    private(set) var sasayakiCues: String?
    private(set) var highlights: String?
    /// JSON `[{id, start, len, text}]` for the current chapter's pre-translated sentences.
    private(set) var sentenceAnchors: String?
    var pendingCommands: [WebViewCommand] = []
    
    func send(_ command: WebViewCommand) {
        pendingCommands.append(command)
    }
    
    func updateState(url: URL, progress: Double, sasayakiCues: String? = nil, highlights: String? = nil, sentenceAnchors: String? = nil) {
        self.chapterURL = url
        self.progress = progress
        self.sasayakiCues = sasayakiCues
        self.highlights = highlights
        self.sentenceAnchors = sentenceAnchors
    }
    
    func updateProgress(_ progress: Double) {
        self.progress = progress
    }
    
    func updateHighlights(_ highlights: String?) {
        self.highlights = highlights
    }
}

final class HoshiWKWebView: WKWebView {
    var onHighlightCreated: ((HighlightColor, HighlightData) -> Void)?
    var hasSelection: Bool = false
    
    // https://stackoverflow.com/a/78488754
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard hasSelection else { return }
        let children = HighlightColor.allCases.map { color in
            let swatch = UIImage(systemName: "circle.fill")?.withTintColor(UIColor(color.swatch), renderingMode: .alwaysOriginal)
            return UIAction(title: color.rawValue.capitalized, image: swatch) { [weak self] _ in
                self?.createHighlight(color: color)
            }
        }
        let menu = UIMenu(
            title: "Highlight",
            image: UIImage(systemName: "highlighter"),
            options: [.displayAsPalette],
            preferredElementSize: .medium,
            children: children
        )
        builder.remove(menu: .learn)
        builder.insertSibling(menu, beforeMenu: .standardEdit)
    }
    
    private func createHighlight(color: HighlightColor) {
        let id = UUID()
        let script = "window.hoshiHighlights.createHighlight('\(color.rawValue)', '\(id.uuidString)')"
        evaluateJavaScript(script) { [weak self] result, _ in
            guard let body = result as? [String: Any],
                  let start = body["start"] as? Int,
                  let offset = body["offset"] as? Int,
                  let text = body["text"] as? String else {
                return
            }
            self?.onHighlightCreated?(color, HighlightData(
                id: id,
                start: start,
                offset: offset,
                text: text
            ))
        }
    }
}

/// Fonts live outside a book. Serve only font-manager entries so a publication never needs
/// permission to read the rest of Application Support (tokens, dictionaries and other books).
final class ReaderFontHandler: NSObject, WKURLSchemeHandler {
    static func url(name: String, verticalWriting: Bool) -> URL? {
        var parts = URLComponents()
        parts.scheme = "hoshi-font"
        parts.host = "font"
        parts.queryItems = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "vertical", value: verticalWriting ? "1" : "0")]
        return parts.url
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let request = task.request.url,
              let parts = URLComponents(url: request, resolvingAgainstBaseURL: false),
              let name = parts.queryItems?.first(where: { $0.name == "name" })?.value,
              let font = try? FontManager.shared.fontUrl(name: name, verticalWriting: parts.queryItems?.first(where: { $0.name == "vertical" })?.value != "0"),
              let directory = try? BookStorage.getAppDirectory().appendingPathComponent("Fonts").standardizedFileURL.resolvingSymlinksInPath(),
              font.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(directory.path + "/"),
              let data = try? Data(contentsOf: font, options: .mappedIfSafe) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(url: request, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "font/otf", "Access-Control-Allow-Origin": "*"])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

struct ReaderWebView: UIViewRepresentable {
    let userConfig: UserConfig
    let viewSize: CGSize
    let bridge: WebViewBridge
    let readAccessRoot: URL
    let textColor: String?
    let sasayakiTextColor: Color
    let sasayakiBackgroundColor: Color
    var onNextChapter: () -> Bool
    var onPreviousChapter: () -> Bool
    var onSaveBookmark: (Double) -> Void
    var onInternalLink: (URL) -> Bool
    var onInternalJump: (Double) -> Void
    var onTextSelected: ((SelectionData) async -> Int?)
    var onTapOutside: (() -> Void)
    var onPageTurn: (() -> Void)
    var onRestoreCompleted: (() -> Void)
    var onHighlightCreated: (HighlightColor, HighlightData) -> Void
    /// A pre-translated sentence's button was pressed; the payload is its `c{spine}s{start}` id.
    var onSentenceTranslate: (String) -> Void = { _ in }
    /// A picture in the chapter was tapped; the payload is its file.
    var onImageTapped: (URL) -> Void = { _ in }
    let maxSelectionLength: Int = 16
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(ReaderFontHandler(), forURLScheme: "hoshi-font")
        config.userContentController.add(context.coordinator, name: "textSelected")
        config.userContentController.add(context.coordinator, name: "restoreCompleted")
        config.userContentController.add(context.coordinator, name: "selectionState")
        config.userContentController.add(context.coordinator, name: "sentenceTranslate")
        config.userContentController.add(context.coordinator, name: "imageTapped")
        config.defaultWebpagePreferences.preferredContentMode = .mobile

        let webView = HoshiWKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.navigationDelegate = context.coordinator
        
        let coordinator = context.coordinator
        webView.onHighlightCreated = { [weak coordinator] color, creation in
            coordinator?.parent.onHighlightCreated(color, creation)
        }
        
        let swipeLeft = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSwipeLeft(_:)))
        swipeLeft.direction = .left
        swipeLeft.delegate = context.coordinator
        swipeLeft.cancelsTouchesInView = false
        swipeLeft.delaysTouchesEnded = false
        webView.addGestureRecognizer(swipeLeft)
        
        let swipeRight = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSwipeRight(_:)))
        swipeRight.direction = .right
        swipeRight.delegate = context.coordinator
        swipeRight.cancelsTouchesInView = false
        swipeRight.delaysTouchesEnded = false
        webView.addGestureRecognizer(swipeRight)
        
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        tap.require(toFail: swipeLeft)
        tap.require(toFail: swipeRight)
        tap.cancelsTouchesInView = false
        tap.delaysTouchesEnded = false
        webView.addGestureRecognizer(tap)
        
        context.coordinator.webView = webView
        
        webView.alpha = 0
        
        WebViewPreloader.shared.close()
        
        return webView
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        
        if !bridge.pendingCommands.isEmpty {
            let commands = bridge.pendingCommands
            bridge.pendingCommands.removeAll()
            for command in commands {
                switch command {
                case .loadChapter(let url, let progress, let fragment, let sasayakiCues, let highlights, let sentenceAnchors):
                    context.coordinator.currentURL = url
                    context.coordinator.pendingProgress = progress
                    context.coordinator.pendingFragment = fragment
                    context.coordinator.pendingSasayakiCues = sasayakiCues
                    context.coordinator.pendingHighlights = highlights
                    context.coordinator.pendingSentenceAnchors = sentenceAnchors
                    webView.alpha = 0
                    webView.loadFileURL(url, allowingReadAccessTo: readAccessRoot)
                case .restoreProgress(let progress):
                    context.coordinator.pendingProgress = progress
                    context.coordinator.pendingFragment = nil
                    context.coordinator.shouldSyncProgressAfterRestore = false
                    webView.evaluateJavaScript("window.hoshiReader.restoreProgress(\(progress))") { _, _ in }
                case .jumpToFragment(let fragment):
                    context.coordinator.jumpToFragment(fragment)
                case .clearSelection:
                    context.coordinator.clearSelection()
                case .updateTextColor(let hex):
                    if let hex {
                        webView.evaluateJavaScript("document.documentElement.style.setProperty('--hoshi-text-color', '\(hex)')") { _, _ in }
                    } else {
                        webView.evaluateJavaScript("document.documentElement.style.removeProperty('--hoshi-text-color')") { _, _ in }
                    }
                case .updateSasayakiColors(let textHex, let backgroundHex):
                    webView.evaluateJavaScript("""
                        document.documentElement.style.setProperty('--hoshi-sasayaki-text-color', '\(textHex)');
                        document.documentElement.style.setProperty('--hoshi-sasayaki-background-color', '\(backgroundHex)');
                    """) { _, _ in }
                case .applySasayakiCues(let cues, let completion):
                    webView.evaluateJavaScript("window.hoshiReader.applySasayakiCues(\(cues))") { _, _ in completion?() }
                case .highlightSasayakiCue(let id, let reveal):
                    let revealFlag = reveal ? "true" : "false"
                    let cue = context.coordinator.javaScriptStringLiteral(id)
                    webView.evaluateJavaScript("window.hoshiReader.highlightSasayakiCue(\(cue), \(revealFlag))") { result, _ in
                        if let progress = result as? Double {
                            onPageTurn()
                            onSaveBookmark(progress)
                        }
                    }
                case .clearSasayakiCue:
                    webView.evaluateJavaScript("window.hoshiReader.clearSasayakiCue()") { _, _ in }
                case .removeHighlight(let id):
                    let literal = context.coordinator.javaScriptStringLiteral(id)
                    webView.evaluateJavaScript("window.hoshiHighlights.removeHighlight(\(literal))") { _, _ in }
                }
            }
            return
        }
        
        if context.coordinator.currentURL == nil, let url = bridge.chapterURL {
            context.coordinator.currentURL = url
            context.coordinator.pendingProgress = bridge.progress
            context.coordinator.pendingFragment = nil
            context.coordinator.pendingSasayakiCues = bridge.sasayakiCues
            context.coordinator.pendingHighlights = bridge.highlights
            context.coordinator.pendingSentenceAnchors = bridge.sentenceAnchors
            webView.alpha = 0
            webView.loadFileURL(url, allowingReadAccessTo: readAccessRoot)
        }
    }
    
    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.selectionTask?.cancel()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "textSelected")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "restoreCompleted")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "selectionState")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "sentenceTranslate")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "imageTapped")
    }
    
    class Coordinator: NSObject, WKNavigationDelegate, UIGestureRecognizerDelegate, WKScriptMessageHandler {
        var selectionTask: Task<Void, Never>?
        var parent: ReaderWebView
        weak var webView: WKWebView?
        var currentURL: URL?
        var pendingProgress: Double = 0
        var pendingFragment: String?
        var pendingSentenceAnchors: String?
        var pendingSasayakiCues: String?
        var pendingHighlights: String?
        var shouldSyncProgressAfterRestore = false
        let recovery = LostPageRecovery()
        
        init(_ parent: ReaderWebView) {
            self.parent = parent
            super.init()
            LostPageRecovery.observeBecomingVisible(self, selector: #selector(readerBecameVisible))
        }
        
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "sentenceTranslate" {
                if let body = message.body as? [String: Any],
                   let id = body["id"] as? String, !id.isEmpty {
                    parent.onSentenceTranslate(id)
                }
                return
            }
            if message.name == "selectionState" {
                if let hasSelection = message.body as? Bool, let hv = message.webView as? HoshiWKWebView {
                    hv.hasSelection = hasSelection
                }
                return
            }
            if message.name == "imageTapped" {
                // Only a picture stored in the book can be opened; one drawn from inline data has no file.
                if let src = message.body as? String, let url = URL(string: src), url.isFileURL {
                    parent.onImageTapped(url)
                }
                return
            }
            if message.name == "restoreCompleted" {
                if shouldSyncProgressAfterRestore {
                    shouldSyncProgressAfterRestore = false
                    syncLinkJumpProgress()
                }
                UIView.animate(withDuration: parent.userConfig.disablePageTurnAnimation ? 0 : 0.25) {
                    message.webView?.alpha = 1
                }
                parent.onRestoreCompleted()
            }
            if message.name == "textSelected" {
                guard let body = message.body as? [String: Any],
                      let text = body["text"] as? String,
                      let sentence = body["sentence"] as? String,
                      let rectData = body["rect"] as? [String: Any],
                      let x = rectData["x"] as? CGFloat,
                      let y = rectData["y"] as? CGFloat,
                      let w = rectData["width"] as? CGFloat,
                      let h = rectData["height"] as? CGFloat else {
                    return
                }
                let rect = CGRect(x: x, y: y, width: w, height: h)
                let normalizedOffset = body["normalizedOffset"] as? Int
                let selectionData = SelectionData(text: text, sentence: sentence, rect: rect, normalizedOffset: normalizedOffset)
                
                selectionTask?.cancel()
                selectionTask = Task {
                    if let count = await parent.onTextSelected(selectionData), !Task.isCancelled { highlightSelection(count: count) }
                }
            }
        }
        
        @MainActor
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            if handleInternalLink(url: url) {
                decisionHandler(.cancel)
                return
            }
            
            decisionHandler(.allow)
        }
        
        private var selectionJs: String {
            guard let url = Bundle.main.url(forResource: "selection", withExtension: "js"),
                  let js = try? String(contentsOf: url, encoding: String.Encoding.utf8) else {
                return ""
            }
            return js
        }
        
        private var readerJs: String {
            guard let url = Bundle.main.url(forResource: "reader", withExtension: "js"),
                  let js = try? String(contentsOf: url, encoding: String.Encoding.utf8) else {
                return ""
            }
            return js
        }
        
        private var translationsJs: String {
            guard let url = Bundle.main.url(forResource: "translations", withExtension: "js"),
                  let js = try? String(contentsOf: url, encoding: String.Encoding.utf8) else {
                return ""
            }
            return js
        }

        private var highlightsJs: String {
            guard let url = Bundle.main.url(forResource: "highlights", withExtension: "js"),
                  let js = try? String(contentsOf: url, encoding: String.Encoding.utf8) else {
                return ""
            }
            return js
        }
        
        /// iOS can discard the page's process while the app is in the background, leaving a blank
        /// page that answers nothing. Load the chapter again at the reader's last saved place.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            let visible = LostPageRecovery.isVisible(webView), reload = recovery.shouldReload(visible: visible)
            DiagnosticsCollector.shared.pageProcessEnded("EPUB", visible: visible, reloaded: reload)
            guard reload else { return }
            reloadLostPage(webView)
        }
        
        @objc private func readerBecameVisible() {
            guard let webView, LostPageRecovery.isVisible(webView), recovery.becameVisible() else { return }
            reloadLostPage(webView)
        }
        
        private func reloadLostPage(_ webView: WKWebView) {
            guard let url = currentURL else { return }
            pendingProgress = parent.bridge.progress
            pendingFragment = nil
            pendingSasayakiCues = parent.bridge.sasayakiCues
            pendingHighlights = parent.bridge.highlights
            pendingSentenceAnchors = parent.bridge.sentenceAnchors
            webView.alpha = 0
            webView.loadFileURL(url, allowingReadAccessTo: parent.readAccessRoot)
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let bottomOverlap = parent.userConfig.verticalWriting ? parent.userConfig.fontSize : 0
            let pageHeight = Int(parent.viewSize.height)
            let pageWidth = Int(parent.viewSize.width)
            
            let verticalPadding = Double(parent.userConfig.verticalPadding)
            let horizontalPadding = Double(parent.userConfig.horizontalPadding)
            
            let writingMode = parent.userConfig.verticalWriting ? "vertical-rl" : "horizontal-tb"
            let columnGapUnit = parent.userConfig.verticalWriting ? "vh" : "vw"
            let columnGapValue = parent.userConfig.verticalWriting
            ? verticalPadding
            : horizontalPadding
            
            let columnGap = parent.userConfig.verticalWriting
            ? "calc(\(columnGapValue)\(columnGapUnit) + \(bottomOverlap)px)"
            : "\(columnGapValue)\(columnGapUnit)"
            
            let bottomPaddingCss = parent.userConfig.verticalWriting && bottomOverlap > 0
            ? "padding-bottom: calc(\(verticalPadding / 2)vh + \(bottomOverlap)px) !important;"
            : ""
            
            let imgWidth = "\(100 - horizontalPadding)vw"
            let imgHeight = parent.userConfig.verticalWriting
            ? "calc(\(100 - verticalPadding)vh - \(Double(bottomOverlap) * (100 - verticalPadding) / 100)px)"
            : "\(100 - verticalPadding)vh"
            
            let textColorCss = """
            @media (prefers-color-scheme: light) { :root { --hoshi-text-color: #000; } }
            @media (prefers-color-scheme: dark) { :root { --hoshi-text-color: #fff; } }
            html, body { color: var(--hoshi-text-color) !important; }
            """
            
            let textColorOverrideJs: String = {
                guard let hex = parent.textColor else { return "" }
                return "document.documentElement.style.setProperty('--hoshi-text-color', '\(hex)');"
            }()
            
            let fontFaceCss = ReaderTextStyle.fontFaceCSS(
                font: parent.userConfig.selectedFont, verticalWriting: parent.userConfig.verticalWriting
            )
            
            var pageBreakCss = ""
            if parent.userConfig.avoidPageBreak {
                pageBreakCss = """
                p {
                    break-inside: avoid !important;
                    -webkit-column-break-inside: avoid !important;
                }
                """
            }
            
            let typographyCss = ReaderTextStyle.typographyDeclarations(
                font: parent.userConfig.selectedFont, size: parent.userConfig.fontSize,
                lineHeight: parent.userConfig.layoutAdvanced ? parent.userConfig.lineHeight : nil,
                characterSpacing: parent.userConfig.layoutAdvanced ? parent.userConfig.characterSpacing : nil
            )
            let paragraphSpacingCss = ReaderTextStyle.paragraphSpacingCSS(
                parent.userConfig.layoutAdvanced ? parent.userConfig.paragraphSpacing : nil,
                verticalWriting: parent.userConfig.verticalWriting
            )
            
            var gridCss = ""
            if !parent.userConfig.justifyText {
                gridCss = """
                text-align: start !important;
                hanging-punctuation: allow-end !important;
                line-break: strict !important;
                """
            }
            
            let css = """
            \(fontFaceCss)
            \(ReaderTextStyle.wordLayoutCSS)
            :root {
                --hoshi-sasayaki-text-color: \(UIColor(parent.sasayakiTextColor).hexString);
                --hoshi-sasayaki-background-color: \(UIColor(parent.sasayakiBackgroundColor).hexString);
            }
            \(ReaderTextStyle.lineBoxCSS)
            html, body {
                overflow: hidden !important;
                height: var(--page-height, 100vh) !important;
                width: var(--page-width, 100vw) !important;
                margin: 0 !important;
                padding: 0 !important;
                writing-mode: \(writingMode) !important;
            }
            body {
                \(typographyCss)
                box-sizing: border-box !important;
                column-width: var(--page-width, 100vw) !important;
                column-gap: \(columnGap);
                padding: \(verticalPadding / 2)vh \(horizontalPadding / 2)vw !important;
                \(bottomPaddingCss)
                \(gridCss)
            }
            body * {
                column-count: auto !important;
                -webkit-column-count: auto !important;
            }
            img.block-img {
                max-width: \(imgWidth) !important;
                max-height: \(imgHeight) !important;
                width: auto !important;
                height: auto !important;
                display: block !important;
                margin: auto !important;
                break-inside: avoid !important;
                -webkit-column-break-inside: avoid !important;
                object-fit: contain !important;
            }
            svg {
                max-width: \(imgWidth) !important;
                max-height: \(imgHeight) !important;
                width: 100% !important;
                height: 100% !important;
                display: block !important;
                margin: auto !important;
                break-inside: avoid !important;
                -webkit-column-break-inside: avoid !important;
            }
            .blur-wrapper {
                display: table;
                margin: auto;
                line-height: 0;
                overflow: hidden;
            }
            img.block-img.blurred,
            svg.blurred {
                filter: blur(24px) !important;
                clip-path: inset(0);
            }
            ::highlight(hoshi-selection) {
                background-color: rgba(160, 160, 160, 0.4) !important;
                color: inherit;
            }
            a {
                color: rgba(66, 108, 245, 1) !important;
            }
            \(ReaderTextStyle.rubyCSS(hidden: parent.userConfig.readerHideFurigana))
            \(sentenceButtonCss)
            ::highlight(hoshi-sasayaki) {
                color: var(--hoshi-sasayaki-text-color) !important;
                background-color: var(--hoshi-sasayaki-background-color) !important;
            }
            ruby.hoshi-sasayaki-ruby-active, ruby.hoshi-sasayaki-ruby-active * {
                color: var(--hoshi-sasayaki-text-color) !important;
                background-color: var(--hoshi-sasayaki-background-color) !important;
            }
            .hoshi-sasayaki-cue.hoshi-sasayaki-active {
                color: var(--hoshi-sasayaki-text-color) !important;
                background-color: var(--hoshi-sasayaki-background-color) !important;
            }
            \(HighlightColor.css)
            \(pageBreakCss)
            \(paragraphSpacingCss)
            \(textColorCss)
            """
            
            let spacerJs: String = {
                if parent.userConfig.verticalWriting {
                    guard verticalPadding > 0 || bottomOverlap > 0 else { return "" }
                    return """
                    var spacer = document.createElement('div');
                    spacer.style.height = 'calc(\(verticalPadding / 2)vh + \(bottomOverlap)px)';
                    spacer.style.width = '100%';
                    spacer.style.display = 'block';
                    spacer.style.breakInside = 'avoid';
                    document.body.appendChild(spacer);
                    """
                } else {
                    guard horizontalPadding > 0 else { return "" }
                    return """
                    var spacer = document.createElement('div');
                    spacer.style.height = '100%';
                    spacer.style.width = '\(horizontalPadding / 2)vw';
                    spacer.style.display = 'block';
                    spacer.style.breakInside = 'avoid';
                    document.body.appendChild(spacer);
                    """
                }
            }()
            
            let sasayakiSetupScript: String = {
                if let cues = pendingSasayakiCues {
                    return """
                    window.hoshiReader.applySasayakiCues(\(cues));
                    """
                }
                return ""
            }()
            pendingSasayakiCues = nil
            
            let highlightsSetupScript: String = {
                if let highlights = pendingHighlights {
                    return "window.hoshiHighlights.applyHighlights(\(highlights));"
                }
                return ""
            }()
            pendingHighlights = nil
            
            // Runs after the cue and highlight wrapping above, both of which split text nodes and
            // rebuild the offset map. Placing buttons first would leave them at stale positions.
            let translationsSetupScript: String = {
                if let anchors = pendingSentenceAnchors {
                    return "window.hoshiTranslations.apply(\(anchors));"
                }
                return ""
            }()
            pendingSentenceAnchors = nil

            let initialRestoreScript: String = {
                if let fragment = pendingFragment {
                    shouldSyncProgressAfterRestore = true
                    return "window.hoshiReader.jumpToFragment(\(javaScriptStringLiteral(fragment)));"
                }
                shouldSyncProgressAfterRestore = false
                return "window.hoshiReader.restoreProgress(\(self.pendingProgress));"
            }()
            pendingFragment = nil
            
            let script = """
            (function() {
                // A spine item that is not an HTML document, such as a bare SVG image, has no
                // head or body to prepare. It is shown as it is, without the reader's scripts,
                // and marked so that a swipe leaves it.
                if (!document.head || !document.body) {
                    window.hoshiPlainDocument = true;
                    window.webkit?.messageHandlers?.restoreCompleted?.postMessage(null);
                    return;
                }
                var viewport = document.querySelector('meta[name="viewport"]');
                if (viewport) { viewport.remove(); }
                
                var newViewport = document.createElement('meta');
                newViewport.name = 'viewport';
                newViewport.content = 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no';
                document.head.appendChild(newViewport);
                
                document.documentElement.style.setProperty('--page-height', '\(pageHeight)px');
                document.documentElement.style.setProperty('--page-width', '\(pageWidth)px');
                
                var style = document.createElement('style');
                style.textContent = \(javaScriptStringLiteral(css));
                document.head.appendChild(style);
                \(textColorOverrideJs)
                
                \(spacerJs)
                \(selectionJs)
                \(readerJs)
                \(ReaderTextStyle.textLayoutScript)
                \(highlightsJs)
                \(translationsJs)
                window.hoshiReader.pageHeight = \(pageHeight);
                window.hoshiReader.pageWidth = \(pageWidth);
                window.hoshiReader.registerCopyText();
                
                if (\(parent.userConfig.readerHideFurigana)) {
                    document.querySelectorAll('rt').forEach(rt => rt.remove());
                }
                
                // wrap text not in spans inside ruby elements in spans to fix highlighting
                document.querySelectorAll('ruby').forEach(ruby => {
                    ruby.childNodes.forEach(node => {
                        if (node.nodeType === Node.TEXT_NODE && node.textContent.trim()) {
                            const span = document.createElement('span');
                            span.textContent = node.textContent;
                            node.replaceWith(span);
                        }
                    });
                });
                
                function setupImage(element, src, wrap) {
                    var target = element;
                    if (\(parent.userConfig.blurImages)) {
                        element.classList.add('blurred');
                        if (wrap) {
                            target = document.createElement('div');
                            target.className = 'blur-wrapper';
                            element.before(target);
                            target.append(element);
                        }
                    }
                    target.onclick = event => {
                        event.preventDefault();
                        event.stopPropagation();
                        if (element.classList.contains('blurred')) {
                            element.classList.remove('blurred');
                            return;
                        }
                        webkit.messageHandlers.imageTapped.postMessage(new URL(src, document.baseURI).href);
                    };
                }
                
                document.querySelectorAll('svg').forEach(svg => {
                    var svgImage = svg.querySelector('image');
                    if (!svgImage) {
                        return;
                    }
                    setupImage(svg, svgImage.href.baseVal, false);
                });
                
                // apply style to big images only, some epubs have inline pictures as "text"
                var images = document.querySelectorAll('img');
                var imagePromises = Array.from(images).map(img => {
                    return new Promise(resolve => {
                        function processImg() {
                            var isGaiji = img.classList.contains('gaiji') || img.classList.contains('gaiji-line');
                            if (!isGaiji && (img.naturalWidth > 256 || img.naturalHeight > 256)) {
                                img.classList.add('block-img');
                                setupImage(img, img.src, true);
                            }
                            resolve();
                        }
                        // complete covers a failed load too: its error event fired before this ran.
                        if (img.complete) {
                            processImg();
                        } else {
                            img.onload = processImg;
                            img.onerror = () => resolve();
                            // A remote image that stalls must not keep the page from opening.
                            setTimeout(resolve, 10000);
                        }
                    });
                });
                
                if (document.fonts) imagePromises.push(document.fonts.ready);
                Promise.all(imagePromises).then(() => {
                    return new Promise(resolve => setTimeout(resolve, 50));
                }).then(() => {
                    try { window.hoshiTextLayout?.prepare(window.hoshiReader, true); }
                    catch (error) { console.error('hoshiTextLayout', error); }
                    window.hoshiReader.buildNodeOffsets();
                    \(highlightsSetupScript)
                    \(translationsSetupScript)
                    \(sasayakiSetupScript)
                    \(initialRestoreScript)
                });
            })();
            """
            
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
        
        private func navigate(_ direction: NavigationDirection) {
            guard let webView = webView else { return }
            
            clearSelection()
            parent.onPageTurn()
            
            let script = paginationScript(direction: direction)
            
            webView.evaluateJavaScript(script) { [weak self] result, _ in
                guard let self = self else { return }
                
                switch result as? String {
                case "scrolled":
                    self.saveBookmark()
                case "limit":
                    let chapterChanged = direction == .forward ? self.parent.onNextChapter() : self.parent.onPreviousChapter()
                    if chapterChanged {
                        webView.alpha = 0
                    }
                default:
                    // No answer: the page's process is gone or the chapter is still loading.
                    // Turning the chapter here would save a place the reader never chose.
                    break
                }
            }
        }
        
        private func paginationScript(direction: NavigationDirection) -> String {
            let jsDirection = direction == .forward ? "forward" : "backward"
            return """
            (function() {
                // A document shown as it is has no pages of its own: every swipe leaves it. A
                // chapter that is still loading, or a page that cannot answer, gives no result.
                if (window.hoshiReader) return window.hoshiReader.paginate('\(jsDirection)');
                return window.hoshiPlainDocument ? 'limit' : null;
            })()
            """
        }
        
        @objc func handleSwipeLeft(_ gesture: UISwipeGestureRecognizer) {
            navigate(parent.userConfig.verticalWriting ? .backward : .forward)
        }
        
        @objc func handleSwipeRight(_ gesture: UISwipeGestureRecognizer) {
            navigate(parent.userConfig.verticalWriting ? .forward : .backward)
        }
        
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let webView = webView else {
                return
            }
            
            let point = gesture.location(in: webView)
            let maxLength = parent.maxSelectionLength
            
            let script = "window.hoshiSelection.selectText(\(point.x), \(point.y), \(maxLength))"
            
            webView.evaluateJavaScript(script) { result, _ in
                if result is NSNull || result == nil {
                    self.parent.onTapOutside()
                }
            }
        }
        
        func saveBookmark() {
            fetchCurrentProgress { [weak self] progress in
                guard let self else { return }
                self.parent.onSaveBookmark(progress)
            }
        }
        
        func jumpToFragment(_ fragment: String) {
            guard let webView = webView else {
                return
            }
            shouldSyncProgressAfterRestore = true
            let script = "window.hoshiReader.jumpToFragment(\(javaScriptStringLiteral(fragment)))"
            webView.evaluateJavaScript(script) { _, _ in }
        }
        
        private func syncLinkJumpProgress() {
            fetchCurrentProgress { [weak self] progress in
                guard let self else { return }
                self.parent.onInternalJump(progress)
            }
        }
        
        private func fetchCurrentProgress(_ completion: @escaping (Double) -> Void) {
            guard let webView = webView else {
                return
            }
            
            webView.evaluateJavaScript("window.hoshiReader.calculateProgress()") { result, _ in
                guard let progress = result as? Double else {
                    return
                }
                completion(progress)
            }
        }
        
        func javaScriptStringLiteral(_ value: String) -> String {
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
            return "'\(escaped)'"
        }
        
        @discardableResult
        private func handleInternalLink(url: URL) -> Bool {
            if url.isFileURL {
                return parent.onInternalLink(url)
            }
            
            guard let scheme = url.scheme?.lowercased() else {
                return false
            }
            if scheme == "http" || scheme == "https" {
                UIApplication.shared.open(url)
                return true
            }
            return false
        }
        
        func highlightSelection(count: Int) {
            guard let webView = webView else {
                return
            }
            
            webView.evaluateJavaScript("window.hoshiSelection.highlightSelection(\(count))") { _, _ in }
        }
        
        func clearSelection() {
            selectionTask?.cancel()
            guard let webView = webView else {
                return
            }
            webView.evaluateJavaScript("window.hoshiSelection.clearSelection()") { _, _ in }
        }
        
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            if otherGestureRecognizer is UILongPressGestureRecognizer {
                return false
            }
            return true
        }
    }
}
