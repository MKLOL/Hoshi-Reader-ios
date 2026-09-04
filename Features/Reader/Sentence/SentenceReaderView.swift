//
//  SentenceReaderView.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Sentence mode: one sentence of an EPUB at a time, laid out horizontally, with its stored
//  pre-translation folded away underneath. Swipe or use the arrows to move a sentence at a time;
//  tap a word to open the same dictionary popup the reader uses, recursive lookups included.
//
//  Ported from Android's features/reader/sentence/SentenceReaderScreen.kt.
//

import CHoshiDicts
import EPUBKit
import SwiftUI
import Textual

struct SentenceReaderView: View {
    let book: BookMetadata
    let document: EPUBDocument
    let coverURL: URL?
    /// Where the reader is now, used when sentence mode has no saved position for this book.
    let bookmark: SentenceBookmarkAnchor?
    let backgroundColor: Color
    let foregroundColor: Color

    @Environment(\.dismiss) private var dismiss
    @Environment(UserConfig.self) private var userConfig

    @State private var state: LoadState = .loading
    @State private var position: SentencePosition?
    @State private var translations: SentenceTranslationSource?
    @State private var translation: SentenceTranslation?
    @State private var translationExpanded = false
    @State private var showAppearance = false
    @State private var popups: [PopupItem] = []
    @State private var highlight: NSRange?
    @State private var textFrame: CGRect = .zero

    /// Longest query handed to the dictionary from a tap; `scanLength` trims it further.
    private static let maxTapQueryChars = 32
    private static let fontSizeStep = 2
    private static let fontSizeRange = 10...60
    private static let rootSpace = "sentenceReaderRoot"

    private enum LoadState {
        case loading
        case ready(SentenceBook)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                backgroundColor.ignoresSafeArea()
                content
                popupStack(screenSize: geometry.size)
            }
            .coordinateSpace(name: Self.rootSpace)
        }
        .task { await load() }
        .onChange(of: position) { _, new in
            translationExpanded = false
            highlight = nil
            closePopups()
            translation = new.flatMap { current in
                guard case let .ready(book) = state, let sentence = book.sentence(at: current) else { return nil }
                return translations?.translation(for: sentence)
            }
            if let new { SentenceReaderPositionStore.save(new, bookKey: bookKey) }
        }
        .sheet(isPresented: $showAppearance) {
            AppearanceView(userConfig: userConfig, showDismiss: true)
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: - Layout

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView().tint(foregroundColor)
        case let .ready(sentenceBook):
            VStack(spacing: 0) {
                header(sentenceBook)
                sentenceArea(sentenceBook)
                TranslationPanel(
                    markdown: translation?.markdownResponse,
                    isExpanded: $translationExpanded,
                    foregroundColor: foregroundColor
                )
                bottomBar(sentenceBook)
            }
        }
    }

    private func header(_ sentenceBook: SentenceBook) -> some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.headline)
            }
            .accessibilityLabel("Close sentence mode")

            VStack(alignment: .leading, spacing: 1) {
                Text(document.title ?? book.title ?? "")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let chapterTitle = chapterTitle(sentenceBook) {
                    Text(chapterTitle)
                        .font(.caption)
                        .opacity(0.7)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let position {
                Text("\(sentenceBook.ordinal(of: position)) / \(sentenceBook.totalSentences)")
                    .font(.caption.monospacedDigit())
                    .opacity(0.7)
            }
            Button { showAppearance = true } label: {
                Image(systemName: "textformat.size").font(.headline)
            }
            .accessibilityLabel("Appearance")
        }
        .foregroundStyle(foregroundColor)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func sentenceArea(_ sentenceBook: SentenceBook) -> some View {
        ZStack {
            // A swipe that starts beside the text still turns the page.
            Color.clear.contentShape(Rectangle())
            if let position, let sentence = sentenceBook.sentence(at: position) {
                SentenceTextView(
                    text: sentence.text,
                    font: SentenceFontResolver.font(
                        named: userConfig.selectedFont,
                        size: CGFloat(userConfig.fontSize) * 1.1,
                        verticalWriting: false
                    ),
                    color: UIColor(foregroundColor),
                    lineHeightMultiple: CGFloat(userConfig.lineHeight),
                    highlight: highlight,
                    onTap: { tap in handleTap(tap, sentence: sentence) },
                    onSwipeLeft: { move(to: SentenceNavigation.next(in: sentenceBook, from: position)) },
                    onSwipeRight: { move(to: SentenceNavigation.previous(in: sentenceBook, from: position)) }
                )
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named(Self.rootSpace))
                } action: { textFrame = $0 }
            } else {
                Text("This book has no text to read one sentence at a time.")
                    .foregroundStyle(foregroundColor.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .gesture(swipeGesture(sentenceBook))
    }

    private func swipeGesture(_ sentenceBook: SentenceBook) -> some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard let position, abs(value.translation.width) > abs(value.translation.height) else { return }
                if value.translation.width < -48 {
                    move(to: SentenceNavigation.next(in: sentenceBook, from: position))
                } else if value.translation.width > 48 {
                    move(to: SentenceNavigation.previous(in: sentenceBook, from: position))
                }
            }
    }

    private func bottomBar(_ sentenceBook: SentenceBook) -> some View {
        let next = position.flatMap { SentenceNavigation.next(in: sentenceBook, from: $0) }
        let previous = position.flatMap { SentenceNavigation.previous(in: sentenceBook, from: $0) }
        return HStack(spacing: 4) {
            Button { move(to: previous) } label: {
                Image(systemName: "chevron.left").font(.title3)
            }
            .disabled(previous == nil)
            .accessibilityLabel("Previous sentence")

            Button { stepFontSize(-Self.fontSizeStep) } label: {
                Image(systemName: "textformat.size.smaller").font(.body)
            }
            .disabled(userConfig.fontSize <= Self.fontSizeRange.lowerBound)
            .accessibilityLabel("Smaller text")

            if let position {
                Text("Chapter \(sentenceBook.readableChapterOrdinal(of: position)) of \(sentenceBook.readableChapterCount)")
                    .font(.caption)
                    .opacity(0.7)
                    .frame(maxWidth: .infinity)
            } else {
                Spacer()
            }

            Button { stepFontSize(Self.fontSizeStep) } label: {
                Image(systemName: "textformat.size.larger").font(.body)
            }
            .disabled(userConfig.fontSize >= Self.fontSizeRange.upperBound)
            .accessibilityLabel("Larger text")

            Button { move(to: next) } label: {
                Image(systemName: "chevron.right").font(.title3)
            }
            .disabled(next == nil)
            .accessibilityLabel("Next sentence")
        }
        .tint(foregroundColor)
        .foregroundStyle(foregroundColor)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func chapterTitle(_ sentenceBook: SentenceBook) -> String? {
        guard let position, sentenceBook.chapters.indices.contains(position.chapter) else { return nil }
        let title = sentenceBook.chapters[position.chapter].title
        return (title?.isEmpty ?? true) ? nil : title
    }

    // MARK: - Loading

    private var bookKey: String { book.folder ?? book.id.uuidString }

    private func load() async {
        guard case .loading = state else { return }
        let sources = SentenceReaderLoader.chapterSources(document: document)
        let folder = book.folder
        let bookSyncId = syncId(for: book)
        let spineCount = document.spine.items.count
        let key = bookKey
        let anchor = bookmark

        let loaded = await Task.detached(priority: .userInitiated) {
            let segmented = SentenceReaderLoader.segment(sources: sources)
            var source: SentenceTranslationSource?
            if let folder, let bookSyncId,
               EpubTranslationStore.shared.preload(
                   folder: folder,
                   expectedSyncId: bookSyncId,
                   spineCount: spineCount
               ) {
                source = SentenceTranslationSource(folder: folder, syncId: bookSyncId, spineCount: spineCount)
            }
            let start = SentenceNavigation.initialPosition(
                in: segmented,
                saved: SentenceReaderPositionStore.load(bookKey: key),
                bookmark: anchor
            )
            let first = start.flatMap { segmented.sentence(at: $0) }.flatMap { source?.translation(for: $0) }
            return (segmented, source, start, first)
        }.value

        translations = loaded.1
        position = loaded.2
        translation = loaded.3
        state = .ready(loaded.0)
    }

    // MARK: - Actions

    private func move(to next: SentencePosition?) {
        guard let next, next != position else { return }
        position = next
    }

    private func stepFontSize(_ delta: Int) {
        let updated = userConfig.fontSize + delta
        userConfig.fontSize = min(max(updated, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
    }

    // MARK: - Dictionary

    private func handleTap(_ tap: SentenceTap, sentence: ReaderSentence) {
        closePopups()
        let text = sentence.text as NSString
        guard tap.characterOffset < text.length else { return }
        let queryLength = min(Self.maxTapQueryChars, text.length - tap.characterOffset)
        let query = text.substring(with: NSRange(location: tap.characterOffset, length: queryLength))
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let rect = tap.rect.offsetBy(dx: textFrame.minX, dy: textFrame.minY)
        let scalarOffset = String(text.substring(to: tap.characterOffset)).unicodeScalars.count
        let selection = SelectionData(
            text: query,
            sentence: sentence.text,
            rect: rect,
            normalizedOffset: sentence.start + EpubSentenceSegmenter.matchableCount(
                sentence.text,
                scalarOffset: scalarOffset
            )
        )
        guard let matched = handleTextSelection(selection) else {
            highlight = nil
            return
        }
        // `matched` counts Characters; the highlight range is UTF-16, like everything NSLayoutManager.
        let start = String.Index(utf16Offset: tap.characterOffset, in: sentence.text)
        let end = sentence.text.index(start, offsetBy: matched, limitedBy: sentence.text.endIndex)
            ?? sentence.text.endIndex
        let utf16End = end.utf16Offset(in: sentence.text)
        highlight = NSRange(location: tap.characterOffset, length: utf16End - tap.characterOffset)
    }

    private func popupStack(screenSize: CGSize) -> some View {
        ForEach($popups) { $popup in
            let popupId = popup.id
            PopupView(
                userConfig: userConfig,
                isVisible: $popup.showPopup,
                selectionData: popup.currentSelection,
                lookupResults: popup.lookupResults,
                dictionaryStyles: popup.dictionaryStyles,
                screenSize: screenSize,
                isVertical: popup.isVertical,
                isFullWidth: popup.isFullWidth,
                coverURL: coverURL,
                documentTitle: document.title,
                clearSelection: popup.clearSelection,
                onTextSelected: { selection in
                    if let index = popups.firstIndex(where: { $0.id == popupId }) {
                        closeChildPopups(parent: index)
                    }
                    return handleTextSelection(selection)
                },
                onTapOutside: {
                    if let index = popups.firstIndex(where: { $0.id == popupId }) {
                        closeChildPopups(parent: index)
                    }
                },
                onSwipeDismiss: {
                    guard let index = popups.firstIndex(where: { $0.id == popupId }),
                          popups.indices.contains(index) else { return }
                    if index == 0 {
                        highlight = nil
                        closePopups()
                    } else if popups.indices.contains(index - 1) {
                        popups[index - 1].clearSelection.toggle()
                        closeChildPopups(parent: index - 1)
                    }
                }
            )
            .zIndex(Double(100 + (popups.firstIndex(where: { $0.id == popupId }) ?? 0)))
        }
    }

    /// The reader's lookup, minus the web view: same engine, same styles, same stacked popups.
    private func handleTextSelection(_ selection: SelectionData) -> Int? {
        let lookupResults = LookupEngine.shared.lookup(
            selection.text,
            maxResults: userConfig.maxResults,
            scanLength: userConfig.scanLength
        )
        let popup = PopupItem(
            showPopup: false,
            currentSelection: selection,
            lookupResults: lookupResults,
            dictionaryStyles: LookupEngine.shared.getStylesMap(),
            isVertical: false,
            isFullWidth: false,
            clearSelection: false
        )
        popups.append(popup)

        guard let firstResult = lookupResults.first else { return nil }
        withAnimation(.default.speed(2.2)) {
            popups = popups.map {
                var updated = $0
                if updated.id == popup.id { updated.showPopup = true }
                return updated
            }
        }
        // `String(firstResult.matched)` stops resolving in heavy files — the documented
        // CHoshiDicts interop fallback (see CxxStringInterop.swift).
        return cxxStringToSwift(firstResult.matched).count
    }

    private func closePopups() {
        guard !popups.isEmpty else { return }
        let popupIds = Set(popups.map(\.id))
        withAnimation(.default.speed(2.4)) {
            for index in popups.indices { popups[index].showPopup = false }
        } completion: {
            popups.removeAll { popupIds.contains($0.id) }
        }
    }

    private func closeChildPopups(parent: Int) {
        var popupIds: Set<UUID> = []
        withAnimation(.default.speed(2.4)) {
            for index in popups.indices.dropFirst(parent + 1) {
                popups[index].showPopup = false
                popupIds.insert(popups[index].id)
            }
        } completion: {
            popups.removeAll { popupIds.contains($0.id) }
        }
    }
}

/// The stored pre-translation, collapsed by default and folded away again on every move.
private struct TranslationPanel: View {
    let markdown: String?
    @Binding var isExpanded: Bool
    let foregroundColor: Color

    @State private var settings = AiChatSettingsStore.shared

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.default.speed(1.6)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                    Text("Translation").font(.subheadline.weight(.semibold))
                    Spacer()
                }
                .foregroundStyle(foregroundColor)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                ScrollView {
                    Group {
                        if let markdown {
                            // Textual owns Markdown, exactly as the tutor reply card does.
                            StructuredText(markdown: markdown)
                                .textual.structuredTextStyle(
                                    HoshiMarkdownStyle(useUniformTextSize: settings.useUniformMarkdownTextSize)
                                )
                        } else {
                            Text("No pre-translation for this sentence.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
                .frame(maxHeight: 240)
            }
        }
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }
}
