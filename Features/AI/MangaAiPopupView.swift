//
//  MangaAiPopupView.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  The manga AI popup: shows the speech-bubble text, the model's reply (rendered as GitHub-flavored
//  Markdown by Textual), loading + error states, an optional screenshot thumbnail, and a per-book
//  history browser.
//
//  The card is an opaque system-background surface with primary-colored text (matching Android's
//  `surface`/`onSurface` popup). A translucent material over a mostly-white manga page washed the
//  reply out to near-invisible, whichever colour scheme was active.
//
//  Ported from Android features/ai/AiChatPopup.kt (AiChatPopupView + AiChatHistoryView). The
//  caller presents this as a full-screen overlay above the manga page.
//

import SwiftUI
import UIKit
import Textual

struct MangaAiPopupView: View {
    @Bindable var controller: MangaAiController
    let book: BookMetadata
    let userConfig: UserConfig
    var coverURL: URL?

    @State private var settings = AiChatSettingsStore.shared
    @State private var showHistory = false
    @State private var historyEntries: [AiChatEntry] = []
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
                Color.black.opacity(0.45)
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
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.primary.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
        // Swallow taps so they don't fall through to the dismiss backdrop.
        .contentShape(Rectangle())
        .onTapGesture { }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(headerTitle)
                .font(.headline)
            Spacer()
            // Selection in the reply is off (see `responseText`), so offer a one-tap copy.
            if !showHistory, case .result(let entry) = controller.state {
                Button {
                    UIPasteboard.general.string = AiThinkingTextSanitizer.strip(entry.response)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy reply")
                .accessibilityLabel("Copy reply")
            }
            Button {
                settings.setUseUniformMarkdownTextSize(!settings.useUniformMarkdownTextSize)
            } label: {
                Image(systemName: "textformat.size")
                    .foregroundStyle(settings.useUniformMarkdownTextSize ? Color.accentColor : Color.primary)
            }
            .help(settings.useUniformMarkdownTextSize
                  ? "Use Markdown heading sizes"
                  : "Use default text size")
            .accessibilityLabel(settings.useUniformMarkdownTextSize
                                ? "Use Markdown heading sizes"
                                : "Use default text size")
            Button {
                guard controller.state != .browsingHistory else {
                    showHistory = true
                    reloadHistory()
                    return
                }
                showHistory.toggle()
                if showHistory { reloadHistory() }
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
            .accessibilityLabel("Close translation")
        }
        .padding(16)
    }

    /// The card title reflects the actual backend selected for this request.
    private var headerTitle: String {
        if showHistory || controller.state == .browsingHistory { return "Translation history" }
        return controller.state.isOnDevice ? "On-device translation" : controller.activeBackendName
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
            // A pre-translated reply is instant and free, so it is what a tap shows. Offer the
            // live model for the times it isn't enough.
            if controller.isShowingPretranslation {
                Button {
                    controller.askLive()
                } label: {
                    Label("Ask ChatGPT instead", systemImage: "sparkles")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .padding(.top, 4)
            }
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
    /// cloud path names the provider actually receiving the request.
    @ViewBuilder
    private func loadingBody(onDevice: Bool) -> some View {
        let progress = onDevice ? OfflineLlmManager.shared.generationProgress : nil
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                ProgressView()
                VStack(alignment: .leading, spacing: 2) {
                    Text(onDevice ? "Translating on-device…" : "Asking \(controller.activeBackendName)…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    // Live tok/s while the on-device model generates, including hidden thinking
                    // tokens so private reasoning progress is visible without showing its text.
                    if let progress, progress.totalTokens > 0 {
                        Text(String(format: "⚡ %.1f tok/s · %d answer tokens · %d thinking tokens",
                                    progress.tokensPerSecond, progress.tokens, progress.thinkingTokens))
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
        if !(message.lowercased().hasPrefix("set your ") && message.lowercased().contains("api key")) {
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
            Text("No translation history for this manga yet.")
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

    // MARK: - Response rendering

    /// Textual owns all Markdown parsing and rendering, including headings, lists, tables, links,
    /// block quotes, inline emphasis, and code blocks.
    @ViewBuilder
    private func responseText(_ response: String) -> some View {
        let visible = AiThinkingTextSanitizer.strip(response)
        StructuredText(markdown: visible)
            .textual.structuredTextStyle(
                HoshiMarkdownStyle(useUniformTextSize: settings.useUniformMarkdownTextSize)
            )
            .textual.highlighterTheme(.init(
                foregroundColor: DynamicColor(.primary),
                backgroundColor: DynamicColor(Color.primary.opacity(0.06))
            ))
            // Text selection is deliberately off. Textual's own `textual.textSelection` bridge
            // traps on iOS: UIKit's edit menu replays a boxed text position into a rebuilt layout
            // collection and the library hits "Index out of range" (gonzalezreal/textual#87,
            // unfixed as of 0.5.0) — that was the crash on long-pressing a word in the reply.
            // SwiftUI's native selection can't stand in: Textual covers every fragment with its
            // link-tap overlay, so the `Text` never sees the long press. The header's
            // "Copy reply" button covers getting the text out.
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Helpers

    private func reloadHistory() {
        guard let folder = book.folder else { return }
        historyEntries = AiChatHistoryStore.shared.load(folder: folder).entries
    }

    private func dismiss() {
        controller.dismiss()
    }

    private func decodeImage(_ image: AiChatImage) -> UIImage? {
        guard let data = Data(base64Encoded: image.base64Data) else { return nil }
        return UIImage(data: data)
    }

}

/// Textual library theme for AI replies on the opaque card: primary text in every node so it
/// stays legible in both colour schemes. This styles Textual's parsed nodes; it does not parse or
/// rewrite Markdown.
private struct HoshiMarkdownStyle: StructuredText.Style {
    let useUniformTextSize: Bool

    var inlineStyle: InlineStyle {
        let codeScale: CGFloat = useUniformTextSize ? 1 : 0.85
        return InlineStyle()
            .code(
                .monospaced,
                .fontScale(codeScale),
                .foregroundColor(.primary),
                .backgroundColor(Color.primary.opacity(0.08))
            )
            .emphasis(.italic, .foregroundColor(.primary))
            .link(.foregroundColor(.accentColor))
            .strong(.fontWeight(.semibold), .foregroundColor(.primary))
            .strikethrough(.strikethroughStyle(.single), .foregroundColor(.primary))
    }

    var headingStyle: HoshiMarkdownHeadingStyle {
        HoshiMarkdownHeadingStyle(useUniformTextSize: useUniformTextSize)
    }
    let paragraphStyle: StructuredText.GitHubParagraphStyle = .gitHub
    let blockQuoteStyle = HoshiMarkdownBlockQuoteStyle()
    let codeBlockStyle: StructuredText.GitHubCodeBlockStyle = .gitHub
    let listItemStyle: StructuredText.DefaultListItemStyle = .default
    let unorderedListMarker: StructuredText.HierarchicalSymbolListMarker = .hierarchical(
        .disc, .circle, .square
    )
    let orderedListMarker: StructuredText.DecimalListMarker = .decimal
    let tableStyle: StructuredText.GitHubTableStyle = .gitHub
    let tableCellStyle: StructuredText.GitHubTableCellStyle = .gitHub
    let thematicBreakStyle: StructuredText.GitHubThematicBreakStyle = .gitHub
}

private struct HoshiMarkdownHeadingStyle: StructuredText.HeadingStyle {
    let useUniformTextSize: Bool
    private static let markdownScales: [CGFloat] = [2, 1.5, 1.25, 1, 0.875, 0.85]

    func makeBody(configuration: Configuration) -> some View {
        let level = min(max(configuration.headingLevel, 1), 6)
        let scale = useUniformTextSize ? 1 : Self.markdownScales[level - 1]
        configuration.label
            .foregroundStyle(.primary)
            .textual.fontScale(scale)
            .fontWeight(.semibold)
            .textual.blockSpacing(.fontScaled(top: 1.2, bottom: 0.5))
    }
}

private struct HoshiMarkdownBlockQuoteStyle: StructuredText.BlockQuoteStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.primary.opacity(0.35))
                .textual.frame(width: .fontScaled(0.2))
            configuration.label
                .foregroundStyle(.primary)
                .textual.padding(.horizontal, .fontScaled(1))
        }
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
