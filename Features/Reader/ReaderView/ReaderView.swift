//
//  ReaderView.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import EPUBKit

struct WebViewState: Hashable {
    var verticalWriting: Bool
    var fontSize: Int
    var selectedFont: String
    var hideFurigana: Bool
    var horizontalPadding: Int
    var verticalPadding: Int
    var avoidPageBreak: Bool
    var justifyText: Bool
    var blurImages: Bool
    var layoutAdvanced: Bool
    var lineHeight: Double
    var characterSpacing: Double
    var paragraphSpacing: Double
    var size: CGSize
}

struct ReaderLoader: View {
    @Environment(UserConfig.self) private var userConfig
    @Environment(\.dismissReader) private var dismissReader
    @State private var viewModel: ReaderLoaderViewModel
    private let isMokuro: Bool

    init(book: BookMetadata, usageLog: UsageLog = .shared) {
        // Detect the on-disk content type (mokuro.json sidecar) as the source of truth, falling
        // back to the stored metadata hint for books whose directory can't be resolved yet.
        let detectedIsMokuro: Bool
        if let booksFolder = try? BookStorage.getBooksDirectory(), let folder = book.folder {
            detectedIsMokuro = ContentType.detect(
                bookDir: booksFolder.appendingPathComponent(folder)
            ) == .mokuro
        } else {
            detectedIsMokuro = book.resolvedContentType == .mokuro
        }
        self.isMokuro = detectedIsMokuro
        _viewModel = State(initialValue: ReaderLoaderViewModel(book: book, usageLog: usageLog))
    }

    var body: some View {
        Group {
            if isMokuro {
                MangaReaderView(metadata: viewModel.book)
            } else if let readerModel = viewModel.readerModel {
                ReaderView(viewModel: readerModel)
            } else if viewModel.loadFailed {
                // The reader covers the whole screen and has no controls of its own yet.
                ContentUnavailableView {
                    Label("This book could not be opened", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("Its files may be missing or damaged. Importing the book again usually fixes this.")
                } actions: {
                    Button("Close") { dismissReader?() }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground))
            } else {
                ProgressView()
            }
        }
        .task {
            if !isMokuro { await viewModel.loadBook(userConfig: userConfig) }
        }
        .onDisappear {
            // A parse failure never creates ReaderView, so release its reservation here. A
            // successful EPUB is released by ReaderView after its final bookmark flush.
            if !isMokuro, viewModel.document == nil {
                HttpSyncActiveBooks.close(viewModel.reservedSyncId)
            }
        }
    }
}

struct ReaderView: View {
    @Environment(\.dismissReader) private var dismissReader
    @Environment(\.readerWindowLifetime) private var readerWindowLifetime
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(UserConfig.self) private var userConfig
    @State private var viewModel: ReaderViewModel
    @State private var topSafeArea: CGFloat = UIApplication.topSafeArea
    /// Shared with the manga reader: the same tutor reply, the same popup, the same offline-first
    /// ordering. Only the cache it reads differs (sentences rather than bubbles).
    @State private var aiController = MangaAiController()
    @State private var focusMode = false
    /// Sentence mode is a whole reading mode rather than a settings sheet, so it gets its own
    /// full-screen presentation instead of a case in `ActiveSheet`.
    @State private var showSentenceMode = false
    @State private var inactiveSince: Date?
    @State private var topBarLeftWidth: CGFloat = 0
    @State private var topBarRightWidth: CGFloat = 0
    @State private var topBarTotalWidth: CGFloat = 0
    @State private var titleNaturalWidth: CGFloat = 0
    
    private let webViewPadding: CGFloat = 4
    private let lineHeight: CGFloat = 16
    
    private var sepiaInverted: Bool {
        userConfig.theme == .sepia && userConfig.sepiaInvertInDark && systemColorScheme == .dark
    }
    
    private var readerBackgroundColor: Color {
        if sepiaInverted {
            return Color(red: 0.094, green: 0.082, blue: 0.047)
        }
        if userConfig.theme == .sepia || (userConfig.theme == .system && userConfig.systemLightSepia && systemColorScheme == .light) {
            return Color(red: 0.949, green: 0.886, blue: 0.788)
        }
        return userConfig.theme == .custom ? userConfig.customBackgroundColor : Color(.systemBackground)
    }
    
    private var readerTextColor: String? {
        if sepiaInverted {
            return "#F2E2C9"
        }
        if userConfig.theme == .sepia || (userConfig.theme == .system && userConfig.systemLightSepia && systemColorScheme == .light) {
            return "#332A1B"
        }
        return userConfig.theme == .custom ? UIColor(userConfig.customTextColor).hexString : nil
    }
    
    /// The same colour as `readerTextColor`, for the parts of the reader drawn natively rather
    /// than in the web view. `nil` there means "leave it to the stylesheet", which natively is the
    /// system label colour.
    private var readerForegroundColor: Color {
        if sepiaInverted {
            return Color(red: 0.949, green: 0.886, blue: 0.788)
        }
        if userConfig.theme == .sepia || (userConfig.theme == .system && userConfig.systemLightSepia && systemColorScheme == .light) {
            return Color(red: 0.200, green: 0.165, blue: 0.106)
        }
        return userConfig.theme == .custom ? userConfig.customTextColor : Color(.label)
    }
    
    private var readerTheme: ColorScheme {
        if userConfig.theme == .custom {
            return userConfig.uiTheme.colorScheme ?? systemColorScheme
        }
        if userConfig.theme == .sepia && userConfig.sepiaInvertInDark {
            return systemColorScheme
        }
        return userConfig.theme.colorScheme ?? systemColorScheme
    }
    
    private var sasayakiTextColor: Color {
        readerTheme == .dark ? userConfig.sasayakiDarkTextColor : userConfig.sasayakiTextColor
    }
    
    private var sasayakiBackgroundColor: Color {
        readerTheme == .dark ? userConfig.sasayakiDarkBackgroundColor : userConfig.sasayakiBackgroundColor
    }
    
    private func updateSasayakiColors() {
        viewModel.bridge.send(.updateSasayakiColors(
            textHex: UIColor(sasayakiTextColor).hexString,
            backgroundHex: UIColor(sasayakiBackgroundColor).hexString
        ))
    }
    
    private func flushAutoSyncInBackground() {
        var task: UIBackgroundTaskIdentifier = .invalid
        task = UIApplication.shared.beginBackgroundTask {
            UIApplication.shared.endBackgroundTask(task)
            task = .invalid
        }
        
        Task {
            await viewModel.flushAutoSync()
            UIApplication.shared.endBackgroundTask(task)
            task = .invalid
        }
    }
    
    init(viewModel: ReaderViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    private func finishReading() {
        guard viewModel.finish() else { return }
        aiController.dismiss()
        Task {
            await viewModel.flushAutoSync()
            HttpSyncActiveBooks.close(syncId(for: viewModel.book))
            HttpSyncManager.shared.syncInBackground()
        }
    }
    
    private var progressString: String {
        var result: [String] = []
        if userConfig.readerShowCharacters {
            result.append("\(viewModel.currentCharacter) / \(viewModel.bookInfo.characterCount)")
        }
        if userConfig.readerShowPercentage {
            let percent = viewModel.bookInfo.characterCount > 0 ? (Double(viewModel.currentCharacter) / Double(viewModel.bookInfo.characterCount) * 100) : 0
            result.append("\(String(format: "%.2f%%", percent))")
        }
        return result.joined(separator: " ")
    }
    
    private var statisticsString: String {
        var result: [String] = []
        if userConfig.readerShowReadingSpeed {
            result.append("\(viewModel.sessionStatistics.lastReadingSpeed.formatted(.number.grouping(.never))) / h")
        }
        if userConfig.readerShowReadingTime {
            result.append("\(StatisticsNumbers.safeDuration(viewModel.sessionStatistics.readingTime).formatted(.time(pattern: .hourMinute)))")
        }
        return result.joined(separator: " ")
    }
    
    var body: some View {
        // on ipad on first load, the geometry reader includes the safearea at the top
        // if you tab out and tab back in, the area recalculates causing the reader to be misaligned
        VStack(spacing: 0) {
            Color.clear
                .frame(height: max(topSafeArea, 25) + webViewPadding
                       + (userConfig.readerShowProgressTop && !progressString.isEmpty ? lineHeight : 0)
                       + ((userConfig.readerShowTitle
                           || (userConfig.enableStatistics && userConfig.readerShowStatisticsToggle)
                           || (userConfig.enableSasayaki && userConfig.readerShowSasayakiToggle && viewModel.sasayakiPlayer.hasAudio)
                           || viewModel.backTarget != nil || viewModel.forwardTarget != nil) ? lineHeight : 0))
                .contentShape(Rectangle())
            
            GeometryReader { geometry in
                ZStack {
                    let viewSize = CGSize(width: geometry.size.width.rounded(), height: (geometry.size.height + (userConfig.verticalWriting ? CGFloat(userConfig.fontSize) : 0)).rounded())
                    if userConfig.continuousMode {
                        ScrollReaderWebView(
                            userConfig: userConfig,
                            bridge: viewModel.bridge,
                            readAccessRoot: viewModel.document.directory,
                            textColor: readerTextColor,
                            sasayakiTextColor: sasayakiTextColor,
                            sasayakiBackgroundColor: sasayakiBackgroundColor,
                            onNextChapter: viewModel.nextChapter,
                            onPreviousChapter: viewModel.previousChapter,
                            onSaveBookmark: viewModel.saveBookmark,
                            onInternalLink: viewModel.jumpToLink,
                            onInternalJump: viewModel.syncProgressAfterLinkJump,
                            onTextSelected: {
                                viewModel.closePopups()
                                return await viewModel.handleTextSelection($0, maxResults: userConfig.maxResults, scanLength: userConfig.scanLength, isVertical: userConfig.verticalWriting, isFullWidth: userConfig.popupFullWidth, autoPause: userConfig.sasayakiAutoPause)
                            },
                            onTapOutside: viewModel.closePopups,
                            onScroll: {
                                viewModel.beginPageTurn()
                                viewModel.closePopups()
                                if userConfig.statisticsAutostartMode == .pageturn && !viewModel.isTracking {
                                    viewModel.startTracking()
                                }
                            },
                            onProgressChanged: {
                                viewModel.updateProgress($0)
                                viewModel.clearForwardHistory()
                            },
                            onRestoreCompleted: {
                                viewModel.handleRestoreCompleted()
                            },
                            onHighlightCreated: viewModel.addHighlight,
                            onSentenceTranslate: { id in
                                viewModel.closePopups()
                                guard let cached = viewModel.sentenceTranslation(id: id) else { return }
                                aiController.ask(bubbleText: cached.sentenceText, sentenceId: id, book: viewModel.book)
                            }
                        )
                        .id(WebViewState(
                            verticalWriting: userConfig.verticalWriting,
                            fontSize: userConfig.fontSize,
                            selectedFont: userConfig.selectedFont,
                            hideFurigana: userConfig.readerHideFurigana,
                            horizontalPadding: userConfig.horizontalPadding,
                            verticalPadding: userConfig.verticalPadding,
                            avoidPageBreak: userConfig.avoidPageBreak,
                            justifyText: userConfig.justifyText,
                            blurImages: userConfig.blurImages,
                            layoutAdvanced: userConfig.layoutAdvanced,
                            lineHeight: userConfig.lineHeight,
                            characterSpacing: userConfig.characterSpacing,
                            paragraphSpacing: userConfig.paragraphSpacing,
                            size: geometry.size,
                        ))
                        .frame(width: viewSize.width, height: viewSize.height)
                    } else {
                        ReaderWebView(
                            userConfig: userConfig,
                            viewSize: viewSize,
                            bridge: viewModel.bridge,
                            readAccessRoot: viewModel.document.directory,
                            textColor: readerTextColor,
                            sasayakiTextColor: sasayakiTextColor,
                            sasayakiBackgroundColor: sasayakiBackgroundColor,
                            onNextChapter: viewModel.nextChapter,
                            onPreviousChapter: viewModel.previousChapter,
                            onSaveBookmark: viewModel.saveBookmark,
                            onInternalLink: viewModel.jumpToLink,
                            onInternalJump: viewModel.syncProgressAfterLinkJump,
                            onTextSelected: {
                                viewModel.closePopups()
                                return await viewModel.handleTextSelection($0, maxResults: userConfig.maxResults, scanLength: userConfig.scanLength, isVertical: userConfig.verticalWriting, isFullWidth: userConfig.popupFullWidth, autoPause: userConfig.sasayakiAutoPause)
                            },
                            onTapOutside: viewModel.closePopups,
                            onPageTurn: {
                                viewModel.beginPageTurn()
                                viewModel.clearForwardHistory()
                                viewModel.closePopups()
                                if userConfig.statisticsAutostartMode == .pageturn && !viewModel.isTracking {
                                    viewModel.startTracking()
                                }
                            },
                            onRestoreCompleted: {
                                viewModel.handleRestoreCompleted()
                            },
                            onHighlightCreated: viewModel.addHighlight,
                            onSentenceTranslate: { id in
                                viewModel.closePopups()
                                guard let cached = viewModel.sentenceTranslation(id: id) else { return }
                                aiController.ask(bubbleText: cached.sentenceText, sentenceId: id, book: viewModel.book)
                            }
                        )
                        .id(WebViewState(
                            verticalWriting: userConfig.verticalWriting,
                            fontSize: userConfig.fontSize,
                            selectedFont: userConfig.selectedFont,
                            hideFurigana: userConfig.readerHideFurigana,
                            horizontalPadding: userConfig.horizontalPadding,
                            verticalPadding: userConfig.verticalPadding,
                            avoidPageBreak: userConfig.avoidPageBreak,
                            justifyText: userConfig.justifyText,
                            blurImages: userConfig.blurImages,
                            layoutAdvanced: userConfig.layoutAdvanced,
                            lineHeight: userConfig.lineHeight,
                            characterSpacing: userConfig.characterSpacing,
                            paragraphSpacing: userConfig.paragraphSpacing,
                            size: geometry.size,
                        ))
                        .frame(width: viewSize.width, height: viewSize.height)
                    }
                    
                    ForEach($viewModel.popups) { $popup in
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
                            coverURL: viewModel.coverURL,
                            documentTitle: viewModel.document.title,
                            clearSelection: popup.clearSelection,
                            onTextSelected: {
                                if let index = viewModel.popups.firstIndex(where: { $0.id == popupId }) {
                                    viewModel.closeChildPopups(parent: index)
                                }
                                return await viewModel.handleTextSelection($0, maxResults: userConfig.maxResults, scanLength: userConfig.scanLength, isVertical: false, isFullWidth: false, autoPause: userConfig.sasayakiAutoPause)
                            },
                            onTapOutside: {
                                if let index = viewModel.popups.firstIndex(where: { $0.id == popupId }) {
                                    viewModel.closeChildPopups(parent: index)
                                }
                            },
                            onSwipeDismiss: {
                                guard let index = viewModel.popups.firstIndex(where: { $0.id == popupId }),
                                      viewModel.popups.indices.contains(index) else {
                                    return
                                }
                                if index == 0 {
                                    viewModel.clearSelection()
                                    viewModel.closePopups()
                                } else if viewModel.popups.indices.contains(index - 1) {
                                    viewModel.popups[index - 1].clearSelection.toggle()
                                    viewModel.closeChildPopups(parent: index - 1)
                                }
                            },
                            onPause: {
                                viewModel.wasPaused = false
                            },
                            sasayakiCue: popup.sasayakiCue,
                            sasayakiPlayer: viewModel.sasayakiPlayer,
                            wasPaused: viewModel.wasPaused
                        )
                        .zIndex(Double(100 + (viewModel.popups.firstIndex(where: { $0.id == popupId }) ?? 0)))
                    }
                    
                    if viewModel.isLoading {
                        ProgressView()
                            .controlSize(.regular)
                            .tint(.secondary)
                    }
                }
            }
            
            HStack {
                CircleButton(systemName: "chevron.left")
                    .onTapGesture {
                        if viewModel.isTracking {
                            viewModel.stopTracking()
                        }
                        dismissReader?()
                    }
                    .opacity(focusMode ? 0 : 1)
                
                Spacer()
                
                TranslationHistoryButton(book: viewModel.book) { aiController.browseHistory() }
                    .foregroundStyle(.primary)
                    .opacity(focusMode ? 0 : 1)
                Menu {
                    Button {
                        viewModel.activeSheet = .appearance
                    } label: {
                        Label("EPUB", systemImage: "paintpalette")
                    }
                    
                    Button {
                        viewModel.activeSheet = .chapters
                    } label: {
                        Label("Chapters", systemImage: "list.bullet")
                    }
                    
                    Button {
                        viewModel.activeSheet = .highlights
                    } label: {
                        Label("Highlights", systemImage: "highlighter")
                    }
                    
                    Button {
                        viewModel.beginSentenceMode()
                        showSentenceMode = true
                    } label: {
                        Label("Sentence mode", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                    
                    if userConfig.enableStatistics {
                        Button {
                            viewModel.activeSheet = .statistics
                        } label: {
                            Label("Statistics", systemImage: "chart.xyaxis.line")
                        }
                    }
                    
                    if userConfig.enableSasayaki && viewModel.sasayakiPlayer.hasMatch {
                        Button {
                            viewModel.activeSheet = .sasayaki
                        } label: {
                            Label("Sasayaki", systemImage: "waveform")
                        }
                    }
                } label: {
                    CircleButton(systemName: "slider.horizontal.3")
                }
                .tint(.primary)
                .opacity(focusMode ? 0 : 1)
            }
            .padding(.horizontal, 20)
            .frame(height: (UIApplication.bottomSafeArea > 25 ? UIApplication.bottomSafeArea : 44) + 10, alignment: .top)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.default.speed(2)) {
                    focusMode.toggle()
                }
            }
        }
        .background(readerBackgroundColor)
        .overlay(alignment: .top) {
            VStack(spacing: 1) {
                ZStack(alignment: .leading) {
                    HStack {
                        HStack(spacing: 2) {
                            if userConfig.enableStatistics && userConfig.readerShowStatisticsToggle {
                                Button {
                                    if viewModel.isTracking {
                                        viewModel.stopTracking()
                                    } else {
                                        viewModel.startTracking()
                                    }
                                } label: {
                                    Image(systemName: viewModel.isTracking ? "timer" : "chart.xyaxis.line")
                                        .font(.subheadline)
                                        .frame(width: 24, height: lineHeight)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(userConfig.theme == .custom ? AnyShapeStyle(userConfig.customInfoColor) : AnyShapeStyle(.secondary))
                            }
                            
                            if let character = viewModel.backTarget {
                                Button {
                                    viewModel.navigateBackwards()
                                } label: {
                                    HStack(spacing: 2) {
                                        Image(systemName: "arrow.uturn.backward.circle")
                                        Text(character.formatted(.number.grouping(.never)))
                                    }
                                    .font(.caption)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(userConfig.theme == .custom ? AnyShapeStyle(userConfig.customInfoColor) : AnyShapeStyle(.secondary))
                                .opacity(focusMode ? 0 : 1)
                            }
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { topBarLeftWidth = $0 }
                        
                        Spacer(minLength: 0)
                        
                        HStack(spacing: 2) {
                            if let character = viewModel.forwardTarget {
                                Button {
                                    viewModel.navigateForwards()
                                } label: {
                                    HStack(spacing: 2) {
                                        Text(character.formatted(.number.grouping(.never)))
                                        Image(systemName: "arrow.uturn.right.circle")
                                    }
                                    .font(.caption)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(userConfig.theme == .custom ? AnyShapeStyle(userConfig.customInfoColor) : AnyShapeStyle(.secondary))
                                .opacity(focusMode ? 0 : 1)
                            }
                            
                            if userConfig.enableSasayaki && userConfig.readerShowSasayakiToggle && viewModel.sasayakiPlayer.hasAudio {
                                Button {
                                    if viewModel.wasPaused {
                                        viewModel.wasPaused = false
                                    } else {
                                        viewModel.sasayakiPlayer.togglePlayback()
                                    }
                                } label: {
                                    Image(systemName: viewModel.sasayakiPlayer.isPlaying || viewModel.wasPaused ? "pause.fill" : "waveform")
                                        .font(.subheadline)
                                        .frame(width: 24, height: lineHeight)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(userConfig.theme == .custom ? AnyShapeStyle(userConfig.customInfoColor) : AnyShapeStyle(.secondary))
                            }
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { topBarRightWidth = $0 }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { topBarTotalWidth = $0 }
                    
                    if userConfig.readerShowTitle, let title = viewModel.document.title {
                        let gap: CGFloat = 2
                        let leftEdge = topBarLeftWidth + gap
                        let rightEdge = topBarTotalWidth - topBarRightWidth - gap
                        let availableSpace = max(0, rightEdge - leftEdge)
                        let displayWidth = min(titleNaturalWidth, availableSpace)
                        let titleLeading = max(leftEdge, min(rightEdge - displayWidth, (topBarTotalWidth - displayWidth) / 2))
                        
                        Text(title)
                            .font(.subheadline)
                            .foregroundStyle(userConfig.theme == .custom ? AnyShapeStyle(userConfig.customInfoColor.opacity(0.5)) : AnyShapeStyle(.tertiary))
                            .lineLimit(1)
                            .frame(width: min(titleNaturalWidth, availableSpace), alignment: .center)
                            .offset(x: titleLeading)
                            .opacity(focusMode ? 0 : 1)
                    }
                }
                .overlay {
                    if userConfig.readerShowTitle, let title = viewModel.document.title {
                        Text(title)
                            .font(.subheadline)
                            .lineLimit(1)
                            .fixedSize()
                            .hidden()
                            .allowsHitTesting(false)
                            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { titleNaturalWidth = $0 }
                    }
                }
                .padding(.horizontal, 15)
                
                if userConfig.readerShowProgressTop && !progressString.isEmpty {
                    Text(progressString)
                        .font(.caption)
                        .foregroundStyle(userConfig.theme == .custom ? AnyShapeStyle(userConfig.customInfoColor) : AnyShapeStyle(.secondary))
                        .monospacedDigit()
                        .tracking(-0.4)
                        .opacity(focusMode ? 0 : 1)
                }
            }
            .padding(.top, max(topSafeArea, 25))
        }
        .overlay(alignment: .bottom) {
            VStack {
                if !focusMode {
                    if userConfig.enableStatistics && !statisticsString.isEmpty {
                        Text(statisticsString)
                            .font(.caption)
                            .foregroundStyle(userConfig.theme == .custom ? AnyShapeStyle(userConfig.customInfoColor) : AnyShapeStyle(.secondary))
                    }
                    if !userConfig.readerShowProgressTop && !progressString.isEmpty {
                        Text(progressString)
                            .font(.caption)
                            .foregroundStyle(userConfig.theme == .custom ? AnyShapeStyle(userConfig.customInfoColor) : AnyShapeStyle(.secondary))
                    }
                }
            }
            .monospacedDigit()
            .tracking(-0.4)
        }
        .consumesOutsideLookupTouches(isActive: viewModel.isLookingUp || viewModel.popups.contains(where: \.showPopup)) {
            viewModel.clearSelection()
            viewModel.closePopups()
        }
        .overlay {
            if viewModel.isSyncing {
                ZStack {
                    Color.clear
                        .contentShape(Rectangle())
                    
                    ProgressView()
                        .controlSize(.regular)
                        .tint(.secondary)
                }
            }
        }
        .overlay {
            // Same popup the manga reader uses — a cached sentence reply is the same shape as a
            // cached bubble reply, including the "Get a fresh translation" escape hatch.
            if aiController.isPresented {
                MangaAiPopupView(
                    controller: aiController,
                    book: viewModel.book,
                    userConfig: userConfig,
                    coverURL: viewModel.book.coverURL
                )
            }
        }
        .fullScreenCover(isPresented: $showSentenceMode, onDismiss: { viewModel.endSentenceMode() }) {
            SentenceReaderView(
                book: viewModel.book,
                document: viewModel.document,
                coverURL: viewModel.coverURL,
                bookmark: SentenceBookmarkAnchor(
                    chapterIndex: viewModel.index,
                    progress: viewModel.currentProgress
                ),
                backgroundColor: readerBackgroundColor,
                foregroundColor: readerForegroundColor,
                usage: viewModel.usage,
                readerModel: viewModel
            )
            .environment(userConfig)
            .preferredColorScheme(readerTheme)
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                guard viewModel.isTracking else { return }
                viewModel.persistReadingTime()
                viewModel.isPaused = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                guard viewModel.isTracking else { return }
                viewModel.resetTrackingBaseline()
                viewModel.isPaused = false
            }
        }
        .sheet(item: $viewModel.activeSheet) { item in
            switch item {
            case .appearance:
                AppearanceView(userConfig: userConfig, showDismiss: true)
                    .presentationDetents([.medium])
                    .preferredColorScheme(readerTheme)
            case .chapters:
                ChapterListView(document: viewModel.document, bookInfo: viewModel.bookInfo, currentIndex: viewModel.index, currentCharacter: viewModel.currentCharacter, coverURL: viewModel.coverURL) { spineIndex, fragment in
                    viewModel.jumpToChapter(index: spineIndex, fragment: fragment)
                    viewModel.activeSheet = nil
                    viewModel.clearSelection()
                    viewModel.closePopups()
                } onJumpToCharacter: { count in
                    viewModel.jumpToCharacter(count)
                    viewModel.activeSheet = nil
                    viewModel.clearSelection()
                    viewModel.closePopups()
                }
            case .highlights:
                HighlightListView(
                    document: viewModel.document,
                    bookInfo: viewModel.bookInfo,
                    highlights: viewModel.highlights,
                    onJump: { highlight in
                        viewModel.jumpToCharacter(highlight.character)
                        viewModel.activeSheet = nil
                        viewModel.clearSelection()
                        viewModel.closePopups()
                    },
                    onDelete: { highlight in
                        viewModel.removeHighlight(highlight)
                    }
                )
                .presentationDetents([.medium, .large])
            case .statistics:
                StatisticsView(viewModel: viewModel)
                    .presentationDetents([.medium, .large])
            case .sasayaki:
                SasayakiSheet(player: viewModel.sasayakiPlayer, onImportAudio: { url in
                    try viewModel.importSasayakiAudio(from: url)
                }) {
                    viewModel.activeSheet = nil
                }
                .presentationDetents([.medium])
            }
        }
        .onAppear {
            if let lifetime = readerWindowLifetime, !lifetime.isClosed { lifetime.onDismiss = finishReading }
        }
        .task {
            viewModel.start()
            await viewModel.syncOnOpen()
        }
        .onChange(of: readerTextColor) { _, hex in viewModel.bridge.send(.updateTextColor(hex)) }
        .onChange(of: sasayakiTextColor) { _, _ in updateSasayakiColors() }
        .onChange(of: sasayakiBackgroundColor) { _, _ in updateSasayakiColors() }
        .onChange(of: userConfig.sasayakiAutoScroll) { _, _ in viewModel.sasayakiPlayer.updateIdleTimerDisabled() }
        .onChange(of: userConfig.readerShowSentenceTranslations) { _, enabled in
            viewModel.setSentenceTranslationsEnabled(enabled)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            let shouldResync = inactiveSince.map { Date.now.timeIntervalSince($0) >= 600 } ?? false
            inactiveSince = nil
            if shouldResync {
                Task {
                    await viewModel.syncAfterForeground()
                }
            }
            guard viewModel.isTracking else {
                return
            }
            viewModel.resetTrackingBaseline()
            viewModel.isPaused = false
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            inactiveSince = .now
            flushAutoSyncInBackground()
            guard viewModel.isTracking else {
                return
            }
            viewModel.persistReadingTime()
            viewModel.isPaused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .readingStatisticsChanged)) { note in
            guard let changed = note.object as? URL, changed.standardizedFileURL == viewModel.rootURL.standardizedFileURL,
                  note.userInfo?["origin"] as? UUID != viewModel.statisticsOrigin else { return }
            viewModel.reloadStatistics()
        }
        .onReceive(NotificationCenter.default.publisher(for: .httpSyncBookmarkApplied)) { note in
            // A playing audiobook drives this device's position; another device's must not move it.
            guard note.userInfo?["syncId"] as? String == syncId(for: viewModel.book), !viewModel.audiobookDrivesPosition else { return }
            viewModel.reloadAfterHttpBookmark()
        }
        .onDisappear {
            // A full-screen sentence reader only hides this view. ReaderWindow owns dismissal.
            if readerWindowLifetime == nil, !showSentenceMode { finishReading() }
        }
        .ignoresSafeArea(edges: .top)
        .ignoresSafeArea(.keyboard)
        .statusBarHidden(focusMode)
        .persistentSystemOverlays(focusMode ? .hidden : .automatic)
        .preferredColorScheme(readerTheme)
    }
}
