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
//  focus toggle, e-ink toggle, go-to-page dialog), RTL paging with a crossfade, debounced
//  bookmark persistence, the shared dictionary PopupView (the same one the EPUB reader uses),
//  and the screenshot-crop overlay.
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
    @State private var eInkMode = false
    @State private var showGoToPageDialog = false
    @State private var screenshotCropMode = false
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

    private var backgroundColor: Color {
        eInkMode ? .white : .black
    }

    private var pageIndicator: String {
        guard model.pageCount > 0 else { return "" }
        return "\(model.pageIndex + 1) / \(model.pageCount)"
    }

    var body: some View {
        ZStack {
            backgroundColor.ignoresSafeArea()

            if model.isReady {
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
                                darkInterface: !eInkMode,
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
            } else if let error = model.errorMessage {
                Text(error)
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                ProgressView().tint(.secondary)
            }

            chrome
        }
        .overlay {
            if showGoToPageDialog {
                goToPageDialog
            }
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
        .task { await model.load(controller: controller) }
        .onChange(of: model.pageIndex) { _, _ in
            model.closePopups()
            withAnimation(.easeInOut(duration: 0.12)) { pageOpacity = 0 }
            model.renderCurrentPage(controller: controller, eInkMode: eInkMode, screenSize: lastSize, userConfig: userConfig)
        }
        .onChange(of: eInkMode) { _, _ in
            model.renderCurrentPage(controller: controller, eInkMode: eInkMode, screenSize: lastSize, userConfig: userConfig)
        }
        .onDisappear { model.flushPendingBookmark() }
    }

    @State private var lastSize: CGSize = .zero

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
            model.renderCurrentPage(controller: controller, eInkMode: eInkMode, screenSize: geometry.size, userConfig: userConfig)
        }
        .onChange(of: geometry.size) { _, newSize in
            lastSize = newSize
            model.viewportSize = newSize
            model.renderCurrentPage(controller: controller, eInkMode: eInkMode, screenSize: newSize, userConfig: userConfig)
        }
    }

    // MARK: Chrome

    @ViewBuilder
    private var chrome: some View {
        VStack(spacing: 0) {
            if !focusMode {
                topBar
                    .background(backgroundColor.opacity(0.001))
            }
            Spacer(minLength: 0)
                // The central spacer toggles focus mode without covering OCR taps: it sits
                // above the WebView only as a thin transparent strip used for the gesture, but
                // because it is in a VStack with the bars it does overlap the page. Disable hit
                // testing on it so taps fall through to the WebView; focus toggles from the
                // bottom bar's empty area instead.
                .allowsHitTesting(false)
            if !focusMode {
                bottomBar
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.default.speed(2)) { focusMode.toggle() }
                    }
            } else {
                // In focus mode, a tap anywhere on the bottom strip restores the chrome.
                Color.clear
                    .frame(height: max(UIApplication.bottomSafeArea, 44))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.default.speed(2)) { focusMode.toggle() }
                    }
            }
        }
        .allowsHitTesting(!screenshotCropMode)
    }

    private var topBar: some View {
        HStack {
            Button {
                model.flushPendingBookmark()
                dismissReader?()
            } label: {
                CircleButton(systemName: "chevron.left")
            }
            .buttonStyle(.plain)

            Spacer()

            if let title = model.title, userConfig.readerShowTitle {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }

            Menu {
                Button {
                    showGoToPageDialog = true
                    goToPageText = "\(model.pageIndex + 1)"
                } label: {
                    Label("Go to page", systemImage: "arrow.right.to.line")
                }
                Button {
                    eInkMode.toggle()
                } label: {
                    Label(eInkMode ? "Disable e-ink mode" : "E-ink mode",
                          systemImage: eInkMode ? "sun.max" : "moon")
                }
                Button {
                    model.closePopups()
                    screenshotCropMode = true
                } label: {
                    Label("Screenshot translate", systemImage: "camera.viewfinder")
                }
            } label: {
                CircleButton(systemName: "slider.horizontal.3")
            }
            .tint(.primary)
        }
        .padding(.horizontal, 20)
        .padding(.top, max(UIApplication.topSafeArea, 8))
        .padding(.bottom, 8)
    }

    private var bottomBar: some View {
        HStack {
            Spacer()
            if !pageIndicator.isEmpty {
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
        .padding(.bottom, max(UIApplication.bottomSafeArea, 12))
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
