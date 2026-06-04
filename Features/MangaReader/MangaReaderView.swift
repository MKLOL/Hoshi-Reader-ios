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
//  focus toggle, go-to-page dialog, statistics sheet), RTL paging with a directional page-turn
//  slide (the outgoing page snapshot slides off while the new page slides in), debounced
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

    // MARK: Directional page-turn slide
    //
    // On a page change the outgoing page is snapshotted and slid off-screen in the swipe
    // direction while the WebView — already reloading to the new page underneath — slides in from
    // the opposite edge. Mirrors Android `MangaReaderScreen`'s filmstrip slide (a forward turn in
    // a right-to-left manga slides the outgoing page off to the *right*; backward to the left).
    //
    /// The frozen outgoing page, drawn on top of the reloading WebView. Non-nil only mid-slide.
    @State private var slideSnapshot: UIImage?
    /// Which way the outgoing page leaves. `forward` → off to the right (RTL), `backward` → left.
    @State private var slideDirection: NavigationDirection = .forward
    /// 0 = slide just started (snapshot centred, WebView fully off the opposite edge); 1 = settled
    /// (WebView centred, snapshot fully off-screen). Read by the offset modifiers each frame.
    @State private var slideProgress: CGFloat = 0
    /// The page index whose `onPageReady` should kick off the slide — the incoming page must finish
    /// its first draw before the slide starts, or the artwork would visibly resize mid-slide.
    @State private var pendingSlideIndex: Int?
    /// Bumped per page change so a stale snapshot task for a superseded turn is discarded.
    @State private var slideGeneration = 0

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
        .onChange(of: model.pageIndex) { oldIndex, newIndex in
            beginPageTurn(from: oldIndex, to: newIndex)
        }
        .onChange(of: userConfig.enableStatistics) { _, enabled in
            // Apply the stats toggle live (e.g. the sheet's "Enable" button) instead of only on
            // the next reader open.
            model.updateStatisticsEnabled(
                enabled,
                title: model.title ?? "",
                autostartMode: userConfig.statisticsAutostartMode
            )
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
        // RTL filmstrip: a forward turn (page 1 at the right) slides the outgoing page off to the
        // right and pulls the incoming WebView in from the left; backward is the reverse. The
        // outgoing snapshot and the WebView stay edge-to-edge, so there is never a gap or a flash
        // of the reloading page. While a turn is in flight (`slideSnapshot != nil`) the WebView is
        // held off-screen until its `onPageReady` starts the slide; otherwise it sits at offset 0.
        let width = geometry.size.width
        let leavingSign: CGFloat = slideDirection == .backward ? -1 : 1
        let webViewOffset = slideSnapshot == nil ? 0 : -leavingSign * width * (1 - slideProgress)
        let snapshotOffset = leavingSign * width * slideProgress

        ZStack {
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
                onPageReady: { onPageReady() }
            )
            // One reused WebView (matches the Android single-WebView model).
            .offset(x: webViewOffset)
            .opacity(pageOpacity)

            if let snapshot = slideSnapshot {
                Image(uiImage: snapshot)
                    .resizable()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .offset(x: snapshotOffset)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
        // Keep the sliding pages contained to the page area so they never bleed into the chrome.
        .clipped()
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

    // MARK: Page-turn slide

    /// Duration of the directional page-turn slide. Long enough to read as a page turn, not a jump.
    private let slideDuration = 0.32

    /// Starts a page turn: snapshots the outgoing page, then reloads to the new page. The slide
    /// itself only begins once the incoming page reports ready (`onPageReady`). Robust to fast
    /// repeat turns via `slideGeneration`, and to snapshot failure (falls back to an instant swap
    /// with a brief opacity dip — never a stuck state).
    private func beginPageTurn(from oldIndex: Int, to newIndex: Int) {
        model.closePopups()
        slideGeneration += 1
        let generation = slideGeneration
        let direction: NavigationDirection = newIndex >= oldIndex ? .forward : .backward

        // No laid-out size yet (first render) — just swap.
        guard lastSize.width > 0, lastSize.height > 0 else {
            clearSlide()
            model.renderCurrentPage(controller: controller, screenSize: lastSize, userConfig: userConfig)
            return
        }

        Task {
            // Snapshot the page *before* the reload swaps the HTML underneath.
            let snapshot = await controller.snapshotCurrentPage()
            // A newer turn superseded this one while we were snapshotting — abandon it.
            guard generation == slideGeneration else { return }

            if let snapshot {
                slideDirection = direction
                slideProgress = 0
                slideSnapshot = snapshot
                pendingSlideIndex = newIndex
                pageOpacity = 1
                // Reload underneath the snapshot; the slide starts on the new page's onPageReady.
                model.renderCurrentPage(controller: controller, screenSize: lastSize, userConfig: userConfig)
            } else {
                // No snapshot: instant swap with a brief opacity dip as a graceful fallback.
                clearSlide()
                withAnimation(.easeInOut(duration: 0.12)) { pageOpacity = 0 }
                model.renderCurrentPage(controller: controller, screenSize: lastSize, userConfig: userConfig)
            }
        }
    }

    /// Invoked when the WebView finishes rendering a page. Drives the slide for a pending turn, or
    /// restores opacity for the no-snapshot fallback path.
    private func onPageReady() {
        if let pending = pendingSlideIndex, slideSnapshot != nil {
            // The slide only starts once the page it is waiting on has actually drawn.
            guard pending == model.pageIndex else { return }
            pendingSlideIndex = nil
            let generation = slideGeneration
            // Animate the WebView in / snapshot out, then drop the snapshot.
            withAnimation(.easeOut(duration: slideDuration)) {
                slideProgress = 1
            } completion: {
                // Only tear down if no newer turn has taken over since this slide started.
                if generation == slideGeneration { clearSlide() }
            }
        } else if slideSnapshot == nil {
            // Fallback path (or first load): restore full opacity.
            withAnimation(.easeInOut(duration: 0.18)) { pageOpacity = 1 }
        }
        // If a snapshot is present but no pending index (slide already running), do nothing here;
        // the running slide's completion owns teardown.
    }

    /// Tears down all slide state and restores the page to a clean, centred, opaque resting state.
    private func clearSlide() {
        slideSnapshot = nil
        slideProgress = 0
        pendingSlideIndex = nil
        pageOpacity = 1
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
