//
//  MangaAiPopupView.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  The manga ChatGPT popup: shows the speech-bubble text, the model's reply (rendered as basic
//  markdown), loading + error states, an optional screenshot thumbnail, and a per-book history
//  browser. Tapping a Japanese word in the reply or in a history entry runs a dictionary lookup
//  through the existing LookupEngine + PopupView, matching the in-reader dictionary popup.
//
//  Ported from Android features/ai/AiChatPopup.kt (AiChatPopupView + AiChatHistoryView). The
//  caller presents this as a full-screen overlay above the manga page.
//

import SwiftUI
import UIKit
import CHoshiDicts

struct MangaAiPopupView: View {
    @Bindable var controller: MangaAiController
    let book: BookMetadata
    let userConfig: UserConfig
    var coverURL: URL?

    @State private var showHistory = false
    @State private var historyEntries: [AiChatEntry] = []
    /// The currently open dictionary lookup (from tapping a Japanese word), if any.
    @State private var wordLookup: WordLookupState?
    /// Screenshot opened in the fullscreen pinch-zoom viewer, if any.
    @State private var zoomedScreenshot: UIImage?

    var body: some View {
        GeometryReader { geometry in
            let isPad = UIDevice.current.userInterfaceIdiom == .pad
            let sideMargin: CGFloat = isPad ? 36 : 16
            let maxCardWidth: CGFloat = isPad ? 680 : 520
            let width = min(maxCardWidth, max(1, geometry.size.width - sideMargin * 2))
            let availableHeight = max(
                1,
                geometry.size.height - geometry.safeAreaInsets.top - geometry.safeAreaInsets.bottom - sideMargin * 2
            )
            let targetHeight = max(isPad ? 520 : 320, geometry.size.height * (isPad ? 0.84 : 0.78))
            let height = min(availableHeight, targetHeight)

            ZStack {
                // Dim + tap-to-dismiss backdrop.
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss() }

                card
                    .frame(width: width, height: height)

                // Fullscreen pinch-zoom viewer for a tapped screenshot, above everything.
                if let zoomed = zoomedScreenshot {
                    ZoomableScreenshotViewer(image: zoomed) { zoomedScreenshot = nil }
                        .transition(.opacity)
                        .zIndex(50)
                }

                // The dictionary lookup popup, layered above the card.
                if let lookup = wordLookup {
                    PopupView(
                        userConfig: userConfig,
                        isVisible: .constant(true),
                        selectionData: SelectionData(text: lookup.word, sentence: lookup.sentence, rect: lookup.rect, normalizedOffset: nil),
                        lookupResults: lookup.results,
                        dictionaryStyles: lookup.styles,
                        screenSize: geometry.size,
                        isVertical: false,
                        isFullWidth: false,
                        coverURL: coverURL,
                        documentTitle: book.title,
                        clearSelection: false,
                        onTextSelected: nil,
                        onTapOutside: { wordLookup = nil },
                        onSwipeDismiss: { wordLookup = nil }
                    )
                }
            }
        }
        .onAppear {
            // Opened from the reader's "Chat history" menu item → start in the history list.
            if controller.state == .browsingHistory { showHistory = true }
            reloadHistory()
        }
    }

    // MARK: - Card

    @ViewBuilder
    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if showHistory || controller.state == .browsingHistory {
                        historyBody
                    } else {
                        currentBody
                    }
                }
                .padding(16)
            }
            .scrollIndicators(.visible)
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.primary.opacity(0.15), lineWidth: 1))
        // Swallow taps so they don't fall through to the dismiss backdrop.
        .contentShape(Rectangle())
        .onTapGesture { wordLookup = nil }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(headerTitle)
                .font(.headline)
            Spacer()
            Button {
                guard controller.state != .browsingHistory else {
                    showHistory = true
                    reloadHistory()
                    wordLookup = nil
                    return
                }
                showHistory.toggle()
                if showHistory { reloadHistory() }
                wordLookup = nil
            } label: {
                Image(systemName: showHistory ? "bubble.left.and.bubble.right" : "clock.arrow.circlepath")
            }
            .help(showHistory ? "Back to chat" : "History")
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    /// The card title, reflecting the active backend while a request is in flight (an on-device
    /// translation reads "On-device translation"; the cloud path keeps "ChatGPT"). Mirrors Android
    /// `AiChatPopupView`'s `if (state.onDevice) "On-device translation" else "ChatGPT"`.
    private var headerTitle: String {
        if showHistory || controller.state == .browsingHistory { return "ChatGPT history" }
        return controller.state.isOnDevice ? "On-device translation" : "ChatGPT"
    }

    // MARK: - Current exchange

    @ViewBuilder
    private var currentBody: some View {
        switch controller.state {
        case .idle:
            EmptyView()
        case .loading(let bubbleText, let onDevice):
            bubbleHeader(bubbleText)
            loadingBody(onDevice: onDevice)
        case .result(let entry):
            entryView(entry)
        case .error(let message):
            errorBody(message)
        case .browsingHistory:
            // Opened straight into history (from the reader menu); the history list is shown via
            // `showHistory`, so there's no "current" exchange to render here.
            EmptyView()
        }
    }

    /// Loading state. For the on-device path it shows "Translating on-device…" plus the live reply
    /// forming + a live tok/s counter (observed from `OfflineLlmManager.generationProgress`). The
    /// cloud path keeps the plain "Asking ChatGPT…" spinner. Mirrors Android `LoadingBody`.
    @ViewBuilder
    private func loadingBody(onDevice: Bool) -> some View {
        let progress = onDevice ? OfflineLlmManager.shared.generationProgress : nil
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                ProgressView()
                VStack(alignment: .leading, spacing: 2) {
                    Text(onDevice ? "Translating on-device…" : "Asking ChatGPT…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    // Live tok/s while the on-device model generates, so a slow reply shows progress.
                    if let progress, progress.tokens > 0 {
                        Text(String(format: "⚡ %.1f tok/s · %d tokens",
                                    progress.tokensPerSecond, progress.tokens))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            // Stream the partial reply as it forms (rendered like the final response so tapping a
            // Japanese word still works once it lands).
            if let progress, !progress.partialText.isEmpty {
                responseText(progress.partialText)
            }
        }
    }

    @ViewBuilder
    private func entryView(_ entry: AiChatEntry) -> some View {
        if let image = entry.screenshotImage, let uiImage = decodeImage(image) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 160)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption2)
                        .padding(5)
                        .background(.ultraThinMaterial, in: Circle())
                        .padding(6)
                }
                .contentShape(Rectangle())
                // Tap to open fullscreen with pinch-zoom + pan (parity ask from Android).
                .onTapGesture { zoomedScreenshot = uiImage }
        }
        if !entry.bubbleText.isEmpty {
            bubbleHeader(entry.bubbleText)
        }
        responseText(entry.response)
        if let debug = entry.debugInfo, !debug.isEmpty {
            Text(debug)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func errorBody(_ message: String) -> some View {
        Text(message)
            .font(.subheadline)
            .foregroundStyle(.red)
        // The "missing API key" failure already points at Settings; retrying would fail the same
        // way, so only offer Retry for other errors.
        if !message.lowercased().hasPrefix("set your openai api key") {
            Button("Retry") { controller.retry() }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func bubbleHeader(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - History

    @ViewBuilder
    private var historyBody: some View {
        if historyEntries.isEmpty {
            Text("No ChatGPT chats for this manga yet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
        } else {
            ForEach(historyEntries.reversed()) { entry in
                VStack(alignment: .leading, spacing: 8) {
                    entryView(entry)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    // MARK: - Response rendering (tappable Japanese words)

    /// Renders the response. Japanese spans become tap targets that run a dictionary lookup; other
    /// text renders as basic markdown.
    @ViewBuilder
    private func responseText(_ response: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(response.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, lineSub in
                let line = String(lineSub)
                if line.isEmpty {
                    Spacer().frame(height: 4)
                } else {
                    lineView(line)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func lineView(_ line: String) -> some View {
        // Fine-grained tokens so the flow layout can wrap ANY line: Japanese characters are
        // individual tokens (CJK wraps anywhere; each is a tap target that scans forward from
        // itself, Yomitan-style), non-Japanese text breaks per word with markdown attributes
        // preserved across the split. Whole-run tokens used to clip — a long run was one
        // unbreakable element wider than the card.
        let tokens = Self.tokenize(line)
        WrapHStack(runs: tokens) { token in
            if let scanText = token.scanText {
                Text(token.attributed)
                    .foregroundStyle(.primary)
                    .background(
                        GeometryReader { proxy in
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture { lookUp(word: scanText, sentence: line, frame: proxy.frame(in: .global)) }
                        }
                    )
            } else {
                Text(token.attributed)
                    .foregroundStyle(.primary)
            }
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }

    // MARK: - Dictionary lookup

    private func lookUp(word: String, sentence: String, frame: CGRect) {
        let results = LookupEngine.shared.lookup(word, maxResults: userConfig.maxResults, scanLength: userConfig.scanLength)
        guard !results.isEmpty else { return }
        var styles: [String: String] = [:]
        for style in LookupEngine.shared.getStyles() {
            styles[String(style.dict_name)] = String(style.styles)
        }
        wordLookup = WordLookupState(word: word, sentence: sentence, rect: frame, results: results, styles: styles)
    }

    // MARK: - Helpers

    private func reloadHistory() {
        guard let folder = book.folder else { return }
        historyEntries = AiChatHistoryStore.shared.load(folder: folder).entries
    }

    private func dismiss() {
        wordLookup = nil
        controller.dismiss()
    }

    private func decodeImage(_ image: AiChatImage) -> UIImage? {
        guard let data = Data(base64Encoded: image.base64Data) else { return nil }
        return UIImage(data: data)
    }

    // MARK: - Run splitting

    struct TextRun: Identifiable {
        let id = UUID()
        let text: String
        let isJapanese: Bool
    }

    private struct WordLookupState {
        let word: String
        let sentence: String
        let rect: CGRect
        let results: [LookupResult]
        let styles: [String: String]
    }

    /// One layout token: an attributed fragment plus, for Japanese characters, the text to
    /// scan from that character on tap (the rest of its run, clipped to a sane scan window).
    struct Token: Identifiable {
        let id = UUID()
        let attributed: AttributedString
        let scanText: String?
    }

    /// Tokenizes a line for the wrapping layout. Japanese runs become per-character tokens
    /// (tap target each, scanning forward); other runs are markdown-parsed once and split into
    /// word tokens, so attributes like **bold** survive wrapping.
    static func tokenize(_ line: String) -> [Token] {
        var tokens: [Token] = []
        for run in splitRuns(line) {
            if run.isJapanese {
                let chars = Array(run.text)
                for (index, ch) in chars.enumerated() {
                    let scan = String(chars[index..<min(chars.count, index + 16)])
                    tokens.append(Token(attributed: AttributedString(String(ch)), scanText: scan))
                }
            } else {
                let attributed = (try? AttributedString(markdown: run.text)) ?? AttributedString(run.text)
                // Split into word tokens at spaces, preserving attributes. Very long words
                // (URLs, hashes, code) are chunked so no single token can out-measure the card.
                var index = attributed.characters.startIndex
                var wordStart = index
                while index < attributed.characters.endIndex {
                    let ch = attributed.characters[index]
                    let next = attributed.characters.index(after: index)
                    if ch == " " {
                        let word = AttributedString(attributed[wordStart..<next])
                        appendWrappedNonJapanese(word, to: &tokens)
                        wordStart = next
                    }
                    index = next
                }
                if wordStart < attributed.characters.endIndex {
                    appendWrappedNonJapanese(AttributedString(attributed[wordStart...]), to: &tokens)
                }
            }
        }
        return tokens
    }

    private static func appendWrappedNonJapanese(_ text: AttributedString, to tokens: inout [Token]) {
        let maxCharactersPerToken = 8
        var start = text.characters.startIndex
        while start < text.characters.endIndex {
            var end = start
            var count = 0
            while end < text.characters.endIndex, count < maxCharactersPerToken {
                end = text.characters.index(after: end)
                count += 1
            }
            let fragment = AttributedString(text[start..<end])
            if !fragment.characters.isEmpty {
                tokens.append(Token(attributed: fragment, scanText: nil))
            }
            start = end
        }
    }

    /// Splits a line into maximal Japanese / non-Japanese runs in order.
    static func splitRuns(_ line: String) -> [TextRun] {
        var runs: [TextRun] = []
        var current = ""
        var currentIsJapanese: Bool? = nil
        for ch in line {
            let isJp = ch.isMangaAiJapanese
            if currentIsJapanese == nil {
                currentIsJapanese = isJp
                current = String(ch)
            } else if isJp == currentIsJapanese {
                current.append(ch)
            } else {
                runs.append(TextRun(text: current, isJapanese: currentIsJapanese!))
                current = String(ch)
                currentIsJapanese = isJp
            }
        }
        if let flag = currentIsJapanese, !current.isEmpty {
            runs.append(TextRun(text: current, isJapanese: flag))
        }
        return runs
    }
}

/// A simple wrapping horizontal layout for the per-line text runs.
private struct WrapHStack<Run: Identifiable, Content: View>: View {
    let runs: [Run]
    @ViewBuilder let content: (Run) -> Content

    var body: some View {
        // SwiftUI's native flow layout (iOS 16+ via Layout). Falls back to a simple HStack wrap.
        FlowLayout(spacing: 0) {
            ForEach(runs) { run in
                content(run)
            }
        }
    }
}

/// Minimal flow layout that wraps subviews to the available width.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : x, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

private extension Character {
    /// Hiragana, katakana, CJK ideographs, and Japanese iteration/long-vowel marks.
    var isMangaAiJapanese: Bool {
        if self == "ー" || self == "々" || self == "〆" || self == "〤" { return true }
        for scalar in unicodeScalars {
            let v = scalar.value
            let isJapanese =
                (0x3040...0x309F).contains(v) ||
                (0x30A0...0x30FF).contains(v) ||
                (0x31F0...0x31FF).contains(v) ||
                (0x3400...0x4DBF).contains(v) ||
                (0x4E00...0x9FFF).contains(v) ||
                (0xF900...0xFAFF).contains(v) ||
                (0x20000...0x2A6DF).contains(v)
            if !isJapanese { return false }
        }
        return true
    }
}


// MARK: - Fullscreen zoomable screenshot viewer

/// Fullscreen overlay showing one screenshot with native pinch-zoom + pan (UIScrollView-backed,
/// 1x-6x, double-tap toggles 1x/3x). Tap the close button or the dimmed border to dismiss.
struct ZoomableScreenshotViewer: View {
    let image: UIImage
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.85).ignoresSafeArea()
            ZoomableImageScrollView(image: image)
                .ignoresSafeArea()
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .padding(.top, max(UIApplication.topSafeArea, 12))
            .padding(.trailing, 16)
        }
    }
}

private struct ZoomableImageScrollView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> ZoomingImageScrollView {
        let scroll = ZoomingImageScrollView()
        scroll.setImage(image)
        return scroll
    }

    func updateUIView(_ uiView: ZoomingImageScrollView, context: Context) {
        uiView.setImage(image)
    }
}

private final class ZoomingImageScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var currentImage: UIImage?
    private var lastLayoutSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func setImage(_ image: UIImage) {
        guard currentImage !== image else { return }
        currentImage = image
        imageView.image = image
        lastLayoutSize = .zero
        setZoomScale(1, animated: false)
        setNeedsLayout()
    }

    private func setup() {
        backgroundColor = .clear
        minimumZoomScale = 1
        maximumZoomScale = 6
        bouncesZoom = true
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        delegate = self

        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size.width > 0, bounds.size.height > 0 else { return }
        if bounds.size != lastLayoutSize || imageView.frame == .zero {
            lastLayoutSize = bounds.size
            layoutImage(resetZoom: true)
        }
        centerImage()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
    }

    private func layoutImage(resetZoom: Bool) {
        guard let image = currentImage, image.size.width > 0, image.size.height > 0 else { return }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let fittedSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        if resetZoom {
            minimumZoomScale = 1
            maximumZoomScale = 6
            zoomScale = 1
        }
        imageView.frame = CGRect(origin: .zero, size: fittedSize)
        contentSize = fittedSize
    }

    private func centerImage() {
        let horizontalInset = max((bounds.width - contentSize.width) / 2, 0)
        let verticalInset = max((bounds.height - contentSize.height) / 2, 0)
        contentInset = UIEdgeInsets(
            top: verticalInset,
            left: horizontalInset,
            bottom: verticalInset,
            right: horizontalInset
        )
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale + 0.01 {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let targetScale = min(maximumZoomScale, 3)
            let point = gesture.location(in: imageView)
            let rectSize = CGSize(width: bounds.width / targetScale, height: bounds.height / targetScale)
            let rect = CGRect(
                x: point.x - rectSize.width / 2,
                y: point.y - rectSize.height / 2,
                width: rectSize.width,
                height: rectSize.height
            )
            zoom(to: rect, animated: true)
        }
    }
}
