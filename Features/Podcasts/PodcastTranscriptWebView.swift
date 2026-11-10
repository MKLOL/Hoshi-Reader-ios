import SwiftUI
import WebKit

/// A single scrolling document uses the EPUB reader's font service, CSS, ruby and selection engine.
struct PodcastTranscriptWebView: UIViewRepresentable {
    let transcript: PodcastTranscript
    let config: UserConfig
    let current: Int?
    let showEnglish: Bool
    let following: Bool
    let selectionRevision: Int
    var onPlay: (Int) -> Void
    var onSelect: (Int, SelectionData) async -> Int?
    var onScroll: () -> Void
    var onTapOutside: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(ReaderFontHandler(), forURLScheme: "hoshi-font")
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        for name in Coordinator.messages {
            configuration.userContentController.add(context.coordinator, name: name)
        }
        for name in ["selection", "furigana", "podcast-transcript"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "js"),
               let source = try? String(contentsOf: url, encoding: .utf8) {
                configuration.userContentController.addUserScript(WKUserScript(
                    source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
            }
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.delegate = context.coordinator
        webView.navigationDelegate = context.coordinator
        webView.accessibilityIdentifier = "podcast-transcript-lines"
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        tap.cancelsTouchesInView = false
        tap.delaysTouchesEnded = false
        webView.addGestureRecognizer(tap)
        context.coordinator.webView = webView
        webView.loadHTMLString(Self.skeleton, baseURL: nil)
        return webView
    }

    fileprivate static let skeleton = """
        <!doctype html><html lang="ja"><head>
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
        <style id="reader-style"></style>
        </head><body><main id="transcript"></main></body></html>
        """

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update()
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.cancel()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.scrollView.delegate = nil
        for name in Coordinator.messages { webView.configuration.userContentController.removeScriptMessageHandler(forName: name) }
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        static let messages = ["textSelected", "podcastPlay", "podcastOutside"]
        var parent: PodcastTranscriptWebView
        weak var webView: WKWebView?
        private var ready = false
        private var document: PodcastTranscript?
        private var style = ""
        private var revision = 0
        private var selectionTask: Task<Void, Never>?
        private var readingTask: Task<Void, Never>?
        private var epoch = 0
        private var selectionEpoch = 0
        private var stateSignature = ""

        private let recovery = LostPageRecovery()

        init(_ parent: PodcastTranscriptWebView) {
            self.parent = parent
            super.init()
            LostPageRecovery.observeBecomingVisible(self, selector: #selector(transcriptBecameVisible))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            update()
        }

        /// iOS can discard the page's process during long background listening. The page came
        /// from a string, so WebKit's own reload would leave a blank `about:blank`; load the
        /// skeleton again and let `update()` resend the document, style and playback state.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            cancel()
            ready = false; document = nil; style = ""; styleInputs = nil; stateSignature = ""
            let visible = LostPageRecovery.isVisible(webView), reload = recovery.shouldReload(visible: visible)
            DiagnosticsCollector.shared.pageProcessEnded("Podcast transcript", visible: visible, reloaded: reload)
            guard reload else { return }
            webView.loadHTMLString(PodcastTranscriptWebView.skeleton, baseURL: nil)
        }

        @objc private func transcriptBecameVisible() {
            guard let webView, LostPageRecovery.isVisible(webView), recovery.becameVisible() else { return }
            webView.loadHTMLString(PodcastTranscriptWebView.skeleton, baseURL: nil)
        }

        func update() {
            guard ready, let webView else { return }
            if document != parent.transcript {
                cancel()
                document = parent.transcript
                stateSignature = ""
                let lines: [[String: Any]] = parent.transcript.lines.map { line in
                    let time = StatisticsMath.duration(line.start)
                    return ["text": line.text, "english": line.english ?? "", "time": time,
                            "playLabel": String(localized: "Play from \(time)")]
                }
                webView.callAsyncJavaScript("window.hoshiTranscript.setDocument(lines)", arguments: ["lines": lines], in: nil, in: .page) { _ in }
                let texts = parent.transcript.lines.map(\.text)
                let documentEpoch = epoch
                readingTask = Task { [weak self] in
                    let work = Task.detached(priority: .userInitiated) {
                        try texts.map { try JapaneseFurigana.annotations(for: $0) }
                    }
                    let result = try? await withTaskCancellationHandler {
                        try await work.value
                    } onCancel: { work.cancel() }
                    guard let self, !Task.isCancelled, documentEpoch == self.epoch, let result else { return }
                    let readings = result.map { $0.map { ["start": $0.start, "length": $0.length, "reading": $0.reading] as [String: Any] } }
                    // DOM replacement invalidates any base ranges selected while readings were loading.
                    self.clearSelection()
                    self.parent.onTapOutside()
                    self.webView?.callAsyncJavaScript("window.hoshiTranscript.setReadings(readings)", arguments: ["readings": readings], in: nil, in: .page) { _ in }
                }
            }
            // Playback redraws this view five times a second. Build the stylesheet, which checks
            // the font file on disk, only when one of its inputs changed.
            let inputs = StyleInputs(config: parent.config, color: UIColor.label.resolvedColor(with: webView.traitCollection).hexString)
            let css = inputs == styleInputs && !awaitingFontFile ? style : stylesheet(inputs)
            styleInputs = inputs
            if style != css {
                style = css
                clearSelection()
                webView.callAsyncJavaScript("""
                    const revision = ++window.hoshiTranscript.layoutRevision;
                    const anchor = window.hoshiTranscript.visibleAnchor();
                    document.getElementById('reader-style').textContent = css;
                    await document.fonts.ready;
                    if (revision === window.hoshiTranscript.layoutRevision) window.hoshiTranscript.restoreAnchor(anchor);
                    """, arguments: ["css": css], in: nil, in: .page) { _ in }
            }
            if revision != parent.selectionRevision {
                revision = parent.selectionRevision
                clearSelection()
            }
            let signature = "\(parent.current ?? -1)|\(parent.following)|\(parent.showEnglish)"
            if stateSignature != signature {
                stateSignature = signature
                let state: [String: Any] = ["current": parent.current.map { $0 as Any } ?? NSNull(),
                    "following": parent.following, "showEnglish": parent.showEnglish]
                webView.callAsyncJavaScript("window.hoshiTranscript.update(state)", arguments: ["state": state], in: nil, in: .page) { _ in }
            }
        }

        /// Everything the stylesheet is built from.
        private struct StyleInputs: Equatable {
            let font: String
            let size: Int
            let lineHeight: Double?
            let characterSpacing: Double?
            let hideFurigana: Bool
            let color: String

            init(config: UserConfig, color: String) {
                font = config.selectedFont; size = config.fontSize
                lineHeight = config.layoutAdvanced ? config.lineHeight : nil
                characterSpacing = config.layoutAdvanced ? config.characterSpacing : nil
                hideFurigana = config.readerHideFurigana
                self.color = color
            }
        }
        private var styleInputs: StyleInputs?
        /// A selected font that is still downloading has no file yet; keep looking until it arrives.
        private var awaitingFontFile = false

        private func stylesheet(_ inputs: StyleInputs) -> String {
            let fontFace = ReaderTextStyle.fontFaceCSS(font: inputs.font, verticalWriting: false)
            awaitingFontFile = fontFace.isEmpty && !FontManager.defaultFonts.contains(inputs.font)
            // The negative margin gives the timestamp a comfortable touch height without
            // moving the sentence below it.
            return """
                \(fontFace)
                \(ReaderTextStyle.lineBoxCSS)
                body {
                    \(ReaderTextStyle.typographyDeclarations(font: inputs.font, size: inputs.size,
                        lineHeight: inputs.lineHeight, characterSpacing: inputs.characterSpacing, color: inputs.color))
                    margin: 0; padding: 16px; writing-mode: horizontal-tb; overflow-wrap: break-word;
                }
                article { padding: 12px; margin-bottom: 12px; border-radius: 12px; background: rgba(128,128,128,.06); }
                article.current { background: rgba(0,122,255,.12); }
                p.japanese { margin: 8px 0 0; }
                button { border: 0; background: none; padding: 12px 12px 12px 0; margin: -12px 0; color: #007aff; font: 13px -apple-system; }
                .english { display: none; margin-top: 8px; font: 17px -apple-system; opacity: .65; }
                .show-english .english { display: block; }
                ::highlight(hoshi-selection) { background-color: rgba(160,160,160,.4); color: inherit; }
                \(ReaderTextStyle.rubyCSS(hidden: inputs.hideFurigana))
                """
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let webView, ready, !webView.scrollView.isDecelerating else { return }
            let point = gesture.location(in: webView)
            webView.callAsyncJavaScript("window.hoshiTranscript.selectAt(x, y, maxLength)", arguments: ["x": point.x, "y": point.y, "maxLength": max(1, parent.config.scanLength)], in: nil, in: .page) { _ in }
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            webView?.evaluateJavaScript("window.hoshiTranscript.userScrolled()") { _, _ in }
            clearSelection()
            parent.onScroll()
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame else { return }
            if message.name == "podcastPlay", let index = message.body as? Int,
               parent.transcript.lines.indices.contains(index) {
                clearSelection()
                parent.onPlay(index)
            } else if message.name == "podcastOutside" {
                clearSelection()
                parent.onTapOutside()
            } else if message.name == "textSelected",
                      let body = message.body as? [String: Any],
                      let paragraph = body["paragraphId"] as? String, paragraph.hasPrefix("podcast-text-"),
                      let index = Int(paragraph.dropFirst("podcast-text-".count)),
                      parent.transcript.lines.indices.contains(index),
                      let text = body["text"] as? String, let sentence = body["sentence"] as? String,
                      let rect = body["rect"] as? [String: CGFloat],
                      let x = rect["x"], let y = rect["y"], let width = rect["width"], let height = rect["height"] {
                selectionTask?.cancel()
                selectionEpoch += 1
                let request = selectionEpoch
                selectionTask = Task { [weak self] in
                    guard let self, let webView = self.webView, request == self.selectionEpoch else { return }
                    let selection = SelectionData(text: text, sentence: sentence, rect: CGRect(x: x, y: y, width: width, height: height))
                    let matched = await self.parent.onSelect(index, selection)
                    guard !Task.isCancelled, request == self.selectionEpoch else { return }
                    if let matched {
                        _ = try? await webView.evaluateJavaScript("window.hoshiSelection.highlightSelection(\(matched))")
                    }
                }
            }
        }

        func clearSelection() {
            selectionEpoch += 1
            selectionTask?.cancel()
            webView?.evaluateJavaScript("window.hoshiTranscript?.clearSelection()") { _, _ in }
        }
        func cancel() {
            epoch += 1
            readingTask?.cancel()
            clearSelection()
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
        }
    }
}
