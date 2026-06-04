//
//  MangaReaderView.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  The mokuro manga reader screen. Ported from Android `features/mangareader/
//  MangaReaderScreen.kt`, adapted to SwiftUI + WKWebView. Owns the current page index and the
//  parsed MokuroBook, hosts the OCR-overlay WebView, the reader chrome (title, page X/Y, back,
//  focus toggle, go-to-page dialog, statistics sheet), RTL paging with a crossfade, debounced
//  bookmark persistence, manga reading statistics, the shared dictionary PopupView (the same one
//  the EPUB reader uses), and the screenshot-crop overlay.
//
//  Phase 2 seams (wired by the orchestrator):
//   - `onAskAi`: invoked with a bubble's OCR text when the sparkles button is tapped.
//   - `onTranslateCrop`: invoked with an `AiChatImage` PNG when a screenshot crop is confirmed.
//

import SwiftUI

struct MangaReaderView: View {
    @Environment(\.dismissReader) private var dismissReader
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(UserConfig.self) private var userConfig

    let metadata: BookMetadata
    /// Phase 2: hand the bubble's OCR text to the AI controller (sparkles button).
    var onAskAi: ((String) -> Void)?
    /// Phase 2: hand a screenshot crop PNG to the AI controller (translate selection).
    var onTranslateCrop: ((AiChatImage) -> Void)?

    @State private var model: MangaReaderViewModel
    @State private var controller = MangaWebViewController()
    /// Drives the ChatGPT popup (bubble translate + screenshot translate). Used when the host
    /// doesn't override `onAskAi`/`onTranslateCrop`.
    @State private var aiController = MangaAiController()
    @State private var focusMode = false
    @State private var showGoToPageDialog = false
    @State private var showOverflowMenu = false
    @State private var screenshotCropMode = false
    @State private var showStatisticsSheet = false
    @State private var goToPageText = ""
    @State private var pageOpacity: Double = 1

    init(
        metadata: BookMetadata,
        onAskAi: ((String) -> Void)? = nil,
        onTranslateCrop: ((AiChatImage) -> Void)? = nil
    ) {
        self.metadata = metadata
        self.onAskAi = onAskAi
        self.onTranslateCrop = onTranslateCrop
        _model = State(initialValue: MangaReaderViewModel(metadata: metadata))
    }

    private let backgroundColor: Color = .black

    private var pageIndicator: String {
        guard model.pageCount > 0 else { return "" }
        return "\(model.pageIndex + 1) / \(model.pageCount)"
    }

    var body: some View {
        ZStack {
            backgroundColor.ignoresSafeArea()

            if model.isReady {
                // Reserve bands for the top/bottom chrome so the WebView never sits underneath
                // them — a full-screen WKWebView swallows taps over its frame, which would make
                // the chrome buttons unresponsive (mirrors the EPUB reader's layout). The manga
                // page is letterboxed, so the reserved bands only trim empty space.
                VStack(spacing: 0) {
                    Color.clear
                        .frame(height: topChromeHeight)
                        .allowsHitTesting(false)
                    pageContent
                    Color.clear
                        .frame(height: bottomChromeHeight)
                        .allowsHitTesting(false)
                }
            } else if let error = model.errorMessage {
                Text(error)
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                ProgressView().tint(.secondary)
            }
        }
        .overlay(alignment: .top) {
            if !focusMode && !screenshotCropMode { topBar }
        }
        .overlay(alignment: .bottom) {
            if !screenshotCropMode { bottomBar }
        }
        .overlay {
            if showGoToPageDialog {
                goToPageDialog
            }
        }
        .sheet(isPresented: $showStatisticsSheet) {
            MangaStatisticsView(model: model, userConfig: userConfig)
        }
        .overlay {
            if aiController.isPresented {
                MangaAiPopupView(
                    controller: aiController,
                    book: metadata,
                    userConfig: userConfig,
                    coverURL: metadata.coverURL
                )
            }
        }
        .onAppear {
            // Push new ChatGPT replies to the HTTP KV sync server (no-op unless sync is enabled).
            aiController.onEntryPersisted = { book, entry in
                HttpSyncManager.shared.onChatEntryPersisted(book: book, entry: entry)
            }
        }
        .statusBarHidden(focusMode)
        .persistentSystemOverlays(focusMode ? .hidden : .automatic)
        .task { await model.load(controller: controller, userConfig: userConfig) }
        .onChange(of: model.pageIndex) { _, _ in
            model.closePopups()
            withAnimation(.easeInOut(duration: 0.12)) { pageOpacity = 0 }
            model.renderCurrentPage(controller: controller, screenSize: lastSize, userConfig: userConfig)
        }
        .onDisappear {
            model.flushPendingBookmark()
            model.persistStatistics()
            aiController.dismiss() // cancel any in-flight OpenAI request when leaving the reader
        }
    }

    /// Height reserved (within the safe area) for the top bar content; reclaimed by the page in
    /// focus mode and while cropping (the crop overlay needs the full screen).
    private var topChromeHeight: CGFloat {
        (focusMode || screenshotCropMode) ? 0 : 52
    }

    /// Height reserved (within the safe area) for the page indicator / focus-toggle strip.
    private var bottomChromeHeight: CGFloat {
        screenshotCropMode ? 0 : 42
    }

    @State private var lastSize: CGSize = .zero

    @ViewBuilder
    private var pageContent: some View {
        GeometryReader { geometry in
            ZStack {
                readerSurface(geometry: geometry)

                        // Shared dictionary popups — identical presentation to the EPUB reader.
                        ForEach($model.popups) { $popup in
                            let popupId = popup.id
                            PopupView(
                                userConfig: userConfig,
                                isVisible: $popup.showPopup,
                                selectionData: popup.currentSelection,
                                lookupResults: popup.lookupResults,
                                dictionaryStyles: popup.dictionaryStyles,
                                screenSize: geometry.size,
                                isVertical: popup.isVertical,
                                isFullWidth: popup.isFullWidth,
                                coverURL: metadata.coverURL,
                                documentTitle: model.title,
                                clearSelection: popup.clearSelection,
                                onTextSelected: { selection in
                                    if let index = model.popups.firstIndex(where: { $0.id == popupId }) {
                                        model.closeChildPopups(parent: index)
                                    }
                                    return model.handleTextSelection(
                                        selection,
                                        maxResults: userConfig.maxResults,
                                        scanLength: userConfig.scanLength,
                                        isVertical: false,
                                        isFullWidth: false
                                    )
                                },
                                onTapOutside: {
                                    if let index = model.popups.firstIndex(where: { $0.id == popupId }) {
                                        model.closeChildPopups(parent: index)
                                    }
                                },
                                onSwipeDismiss: {
                                    guard let index = model.popups.firstIndex(where: { $0.id == popupId }),
                                          model.popups.indices.contains(index) else { return }
                                    if index == 0 {
                                        model.clearSelection(in: controller)
                                        model.closePopups()
                                    } else if model.popups.indices.contains(index - 1) {
                                        model.popups[index - 1].clearSelection.toggle()
                                        model.closeChildPopups(parent: index - 1)
                                    }
                                }
                            )
                            .zIndex(Double(100 + (model.popups.firstIndex(where: { $0.id == popupId }) ?? 0)))
                        }

                        if screenshotCropMode {
                            MangaScreenshotCropOverlay(
                                containerSize: geometry.size,
                                onCancel: { screenshotCropMode = false },
                                onConfirm: { rect in
                                    screenshotCropMode = false
                                    Task { await translateCrop(rect) }
                                }
                            )
                            .zIndex(500)
                        }
                    }
                }
    }

    @ViewBuilder
    private func readerSurface(geometry: GeometryProxy) -> some View {
        MangaReaderWebView(
            controller: controller,
            backgroundColor: UIColor(backgroundColor),
            onNavigate: { direction in
                model.navigate(direction)
            },
            onTextSelected: { selection in
                model.closePopups()
                return model.handleTextSelection(
                    selection,
                    maxResults: userConfig.maxResults,
                    scanLength: userConfig.scanLength,
                    isVertical: selection.rect.height > selection.rect.width,
                    isFullWidth: userConfig.popupFullWidth
                )
            },
            onTapOutside: { model.closePopups() },
            onAskAi: { text in
                if let onAskAi { onAskAi(text) }
                else { aiController.ask(bubbleText: text, book: metadata) }
            },
            onCopy: { text in UIPasteboard.general.string = text },
            onPageReady: {
                // Page finished rendering — fade it back in (the crossfade for v1).
                withAnimation(.easeInOut(duration: 0.18)) { pageOpacity = 1 }
            }
        )
        // One reused WebView (matches the Android single-WebView model). The crossfade for v1
        // is a brief opacity dip on page change, restored when the new page reports ready.
        .opacity(pageOpacity)
        .onAppear {
            lastSize = geometry.size
            model.viewportSize = geometry.size
            model.renderCurrentPage(controller: controller, screenSize: geometry.size, userConfig: userConfig)
        }
        .onChange(of: geometry.size) { _, newSize in
            lastSize = newSize
            model.viewportSize = newSize
            model.renderCurrentPage(controller: controller, screenSize: newSize, userConfig: userConfig)
        }
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack {
            CircleButton(systemName: "chevron.left")
                .contentShape(Circle())
                .onTapGesture {
                    model.flushPendingBookmark()
                    model.persistStatistics()
                    dismissReader?()
                }

            Spacer()

            if let title = model.title, userConfig.readerShowTitle {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }

            CircleButton(systemName: "slider.horizontal.3")
                .contentShape(Circle())
                .onTapGesture {
                    model.closePopups()
                    showOverflowMenu = true
                }
        }
        .padding(.horizontal, 20)
        // The inset region already starts at the safe-area edge; a small gap hugs the status bar.
        .padding(.top, 4)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(backgroundColor.opacity(0.001))
        .confirmationDialog("", isPresented: $showOverflowMenu, titleVisibility: .hidden) {
            Button("Go to page") {
                goToPageText = "\(model.pageIndex + 1)"
                showGoToPageDialog = true
            }
            Button("Screenshot translate") {
                model.closePopups()
                screenshotCropMode = true
            }
            Button("Statistics") {
                model.closePopups()
                showStatisticsSheet = true
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var bottomBar: some View {
        HStack {
            Spacer()
            if !focusMode, !pageIndicator.isEmpty {
                Text(pageIndicator)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 36)
        // A small gap hugs the home indicator.
        .padding(.bottom, 6)
        .background(backgroundColor.opacity(0.001))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.default.speed(2)) { focusMode.toggle() }
        }
    }

    private var goToPageDialog: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { showGoToPageDialog = false }

            VStack(spacing: 16) {
                Text("Go to page")
                    .font(.headline)
                TextField("Page (1 - \(model.pageCount))", text: $goToPageText)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                HStack {
                    Button("Cancel", role: .cancel) { showGoToPageDialog = false }
                    Spacer()
                    Button("Go") {
                        if let page = Int(goToPageText), page >= 1, page <= model.pageCount {
                            showGoToPageDialog = false
                            model.goToPage(page - 1)
                        }
                    }
                    .disabled(Int(goToPageText).map { $0 < 1 || $0 > model.pageCount } ?? true)
                }
                .frame(width: 200)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: Screenshot crop

    private func translateCrop(_ rect: MangaScreenshotCropRect) async {
        controller.clearRevealedBubbles()
        guard let crop = await controller.imageCropRect(for: rect),
              let imageFile = model.imageFile(forPageIndex: crop.pageIndex) else {
            return
        }
        let png = await Task.detached(priority: .userInitiated) {
            cropMangaImageFilePng(imageFile: imageFile, crop: crop)
        }.value
        guard let png else { return }
        let image = mangaScreenshotAiImage(pngData: png)
        if let onTranslateCrop { onTranslateCrop(image) }
        else { aiController.translateCrop(image: image, book: metadata) }
    }
}
