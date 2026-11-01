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
    var usage: ReaderUsageSession? = nil
    var readerModel: ReaderViewModel? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(UserConfig.self) private var userConfig

    @State private var state: LoadState = .loading
    @State private var position: SentencePosition?
    @State private var translations: SentenceTranslationSource?
    @State private var translation: SentenceTranslation?
    @State private var translationExpanded = false
    @State private var bookFinished = false
    @State private var readingProgress: SentenceReadingProgress?
    @AppStorage("sentenceReaderLayout") private var paneLayout = "stacked"
    @State private var showAppearance = false
    @State private var popups: [PopupItem] = []
    @State private var highlight: NSRange?
    @State private var textFrame: CGRect = .zero

    /// Longest query handed to the dictionary from a tap; `scanLength` trims it further.
    private static let maxTapQueryChars = 32
    private static let fontSizeStep = 2
    /// The reader's Appearance sheet allows 16...40; `fontSize` is shared, so the steppers here
    /// must not push the web reader to a size that sheet cannot produce.
    private static let fontSizeRange = 16...40
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
            .consumesOutsideLookupTouches(isActive: isLookingUp || popups.contains(where: \.showPopup), dismiss: dismissPopups)
        }
        .onDisappear { closePopups(); readerModel?.persistReadingTime() }
        .task { await load() }
        .onChange(of: position) { _, new in
            translationExpanded = false
            dismissPopups()
            translation = new.flatMap { current in
                guard case let .ready(book) = state, let sentence = book.sentence(at: current) else { return nil }
                return translations?.translation(for: sentence)
            }
            if let new { SentenceReaderPositionStore.save(new, bookKey: bookKey) } // queued off the main actor
        }
        .onChange(of: readerModel?.index) { _, _ in refreshFromBookmark() }
        .onChange(of: readerModel?.currentProgress) { _, _ in refreshFromBookmark() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            guard let readerModel else { return }
            Task {
                await readerModel.syncAfterForeground()
                refreshFromBookmark()
            }
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
                    .dismissesPopupsOnTap(dismissPopups)
                sentencePanes(sentenceBook)
                bottomBar(sentenceBook)
                    .dismissesPopupsOnTap(dismissPopups)
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
            Menu {
                Button { paneLayout = "stacked"; dismissPopups() } label: {
                    Label("Above and below", systemImage: paneLayout == "stacked" ? "checkmark" : "rectangle.split.1x2")
                }
                Button { paneLayout = "side-by-side"; dismissPopups() } label: {
                    Label("Side by side", systemImage: paneLayout == "side-by-side" ? "checkmark" : "rectangle.split.2x1")
                }
            } label: {
                Image(systemName: paneLayout == "side-by-side" ? "rectangle.split.2x1" : "rectangle.split.1x2")
            }
            .accessibilityLabel("Sentence layout")
            Button { dismissPopups(); showAppearance = true } label: {
                Image(systemName: "textformat.size").font(.headline)
            }
            .accessibilityLabel("Appearance")
        }
        .foregroundStyle(foregroundColor)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// Each pane scrolls independently, leaving long Japanese text and translation tables reachable.
    private func sentencePanes(_ sentenceBook: SentenceBook) -> some View {
        GeometryReader { geometry in
            if translationExpanded && paneLayout == "side-by-side" {
                HStack(spacing: 0) {
                    sentenceArea(sentenceBook).frame(width: geometry.size.width / 2)
                    translationPanel.frame(width: geometry.size.width / 2)
                }
            } else {
                VStack(spacing: 0) {
                    sentenceArea(sentenceBook)
                        .frame(height: translationExpanded ? geometry.size.height / 2 : nil)
                    translationPanel
                }
            }
        }
    }

    private var translationPanel: some View {
        TranslationPanel(markdown: translation?.markdownResponse, isExpanded: $translationExpanded,
            foregroundColor: foregroundColor)
            .dismissesPopupsOnTap(dismissPopups)
    }

    @ViewBuilder
    private func sentenceArea(_ sentenceBook: SentenceBook) -> some View {
        ZStack {
            // A swipe that starts beside the text still turns the page, and a tap there closes
            // an open popup, exactly as tapping the page does in the reader.
            Color.clear.contentShape(Rectangle())
                .onTapGesture { dismissPopups() }
            if let position, let sentence = sentenceBook.sentence(at: position) {
                SentenceTextView(
                    text: sentence.text,
                    font: SentenceFontResolver.sentenceFont(
                        named: userConfig.selectedFont,
                        size: userConfig.fontSize
                    ),
                    color: UIColor(foregroundColor),
                    lineHeightMultiple: CGFloat(userConfig.lineHeight),
                    highlight: highlight,
                    ruby: userConfig.readerHideFurigana ? [] : sentence.ruby,
                    onTap: { tap in handleTap(tap, sentence: sentence) },
                    onTapOutside: { dismissPopups() },
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

            if let next {
                Button { move(to: next) } label: {
                    Image(systemName: "chevron.right").font(.title3)
                }
                .accessibilityLabel("Next sentence")
            } else if position != nil, readerModel != nil {
                Button { finishBook(sentenceBook) } label: {
                    Image(systemName: bookFinished ? "checkmark.circle.fill" : "checkmark.circle").font(.title3)
                }
                .disabled(bookFinished)
                .accessibilityLabel(bookFinished ? "Book finished" : "Finish book")
            }
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

        // Detached so a novel's segmentation and the blob decode stay off the main actor, but
        // tied to this view's `.task`: leaving the screen cancels the work instead of letting it
        // finish and write into a dismissed view.
        let work = Task.detached(priority: .userInitiated) { () -> (SentenceBook, SentenceTranslationSource?, SentencePosition?, SentenceTranslation?, SentencePosition?)? in
            let segmented = SentenceReaderLoader.segment(sources: sources)
            guard !Task.isCancelled else { return nil }
            var source: SentenceTranslationSource?
            if let folder, let bookSyncId,
               EpubTranslationStore.shared.preload(
                   folder: folder,
                   expectedSyncId: bookSyncId,
                   spineCount: spineCount
               ) {
                source = SentenceTranslationSource(folder: folder, syncId: bookSyncId, spineCount: spineCount)
            }
            let saved = SentenceReaderPositionStore.load(bookKey: key)
            let start = SentenceNavigation.initialPosition(
                in: segmented,
                saved: saved,
                bookmark: anchor
            )
            let first = start.flatMap { segmented.sentence(at: $0) }.flatMap { source?.translation(for: $0) }
            return (segmented, source, start, first, saved)
        }
        let loaded = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        guard let loaded, !Task.isCancelled else { return }

        translations = loaded.1
        state = .ready(loaded.0)
        if let readerModel {
            let mapping = readerModel.sentenceProgress(for: loaded.0)
            readingProgress = mapping
            let anchor = SentenceBookmarkAnchor(chapterIndex: readerModel.index, progress: readerModel.currentProgress)
            let migrationKey = "sentenceSharedBookmark.\(bookKey)"
            if !UserDefaults.standard.bool(forKey: migrationKey), let cursor = loaded.4,
               let point = mapping.at(cursor), point.characterCount > readerModel.currentCharacter {
                // Adopt an older separate sentence cursor once. From here on the shared bookmark wins.
                position = cursor
                readerModel.prepareSentenceProgress(point)
                readerModel.saveSentenceProgress(point)
            } else {
                position = mapping.initialPosition(saved: loaded.4, bookmark: anchor)
            }
            if let position, let point = mapping.at(position) { readerModel.prepareSentenceProgress(point) }
            UserDefaults.standard.set(true, forKey: migrationKey)
            bookFinished = readerModel.currentProgress >= 1 && readerModel.index == mapping.completionPoint?.chapterIndex && position.map(mapping.isLast) == true
        } else {
            position = loaded.2
        }
        translation = position.flatMap { loaded.0.sentence(at: $0) }.flatMap { translations?.translation(for: $0) }
    }

    // MARK: - Actions

    private func move(to next: SentencePosition?) {
        if popups.contains(where: \.showPopup) { dismissPopups(); return }
        guard let next, next != position else { return }
        dismissPopups()
        bookFinished = false
        position = next
        if let readerModel, let point = readingProgress?.at(next) {
            readerModel.saveSentenceProgress(point)
        }
    }

    private func finishBook(_ sentenceBook: SentenceBook) {
        guard let readerModel, let position, let mapping = readingProgress else { return }
        guard mapping.isLast(position), let end = mapping.completionPoint else { return }
        dismissPopups()
        readerModel.saveSentenceProgress(end)
        readerModel.persistReadingTime()
        bookFinished = true
    }

    private func refreshFromBookmark() {
        guard let readerModel, let mapping = readingProgress else { return }
        let anchor = SentenceBookmarkAnchor(chapterIndex: readerModel.index, progress: readerModel.currentProgress)
        let restored = mapping.initialPosition(saved: position, bookmark: anchor)
        if restored != position, let restored, let point = mapping.at(restored) {
            readerModel.prepareSentenceProgress(point)
        }
        position = restored
        bookFinished = readerModel.currentProgress >= 1 && readerModel.index == mapping.completionPoint?.chapterIndex && position.map(mapping.isLast) == true
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
        let query = text.substring(with: text.rangeOfComposedCharacterSequences(for: NSRange(location: tap.characterOffset, length: queryLength)))
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
        let generation = lookupGeneration
        Task {
            guard generation == lookupGeneration else { return }
            let matched = await handleTextSelection(selection)
            guard lookupGeneration == generation + 1 else { return }
            guard let matched else { highlight = nil; return }
            // Lookup lengths count Unicode scalars; NSLayoutManager ranges use UTF-16.
            let start = String.Index(utf16Offset: tap.characterOffset, in: sentence.text)
            let end = sentence.text.unicodeScalars.index(start, offsetBy: matched, limitedBy: sentence.text.endIndex)
                ?? sentence.text.endIndex
            let utf16End = end.utf16Offset(in: sentence.text)
            highlight = NSRange(location: tap.characterOffset, length: utf16End - tap.characterOffset)
        }
    }

    private func popupStack(screenSize: CGSize) -> some View {
        NativeDictionaryPopupStack(userConfig: userConfig, popups: $popups, screenSize: screenSize,
            coverURL: coverURL, documentTitle: document.title, onTextSelected: handleTextSelection,
            onDismiss: dismissPopups, onCloseChildren: { closeChildPopups(parent: $0) })
    }

    /// The reader's lookup, minus the web view: same engine, same styles, same stacked popups.
    @State private var lookupGeneration = 0
    @State private var isLookingUp = false
    private func handleTextSelection(_ selection: SelectionData) async -> Int? {
        guard !Task.isCancelled else { return nil }
        lookupGeneration += 1
        let generation = lookupGeneration
        isLookingUp = true
        defer { if lookupGeneration == generation { isLookingUp = false } }
        let snapshot = await LookupEngine.shared.lookupAsync(
            selection.text,
            maxResults: userConfig.maxResults,
            scanLength: userConfig.scanLength
        )
        guard !Task.isCancelled, lookupGeneration == generation else { return nil }
        let lookupResults = snapshot.results
        usage?.record(.lookup, text: lookupResults.first.map { cxxStringToSwift($0.matched) } ?? selection.text,
            term: lookupResults.first.map { cxxStringToSwift($0.term.expression) },
            source: popups.contains { $0.showPopup } ? "popup" : "page", found: !lookupResults.isEmpty)
        guard !lookupResults.isEmpty else { return nil }
        let popup = PopupItem(
            showPopup: false,
            currentSelection: selection,
            lookupResults: lookupResults,
            dictionaryStyles: snapshot.styles,
            isVertical: false,
            isFullWidth: userConfig.popupFullWidth,
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
        return cxxStringToSwift(firstResult.matched).unicodeScalars.count
    }

    /// What a tap anywhere outside the popup does: the reader's `onTapOutside`, minus the web view.
    private func dismissPopups() {
        highlight = nil
        closePopups()
    }

    private func closePopups() {
        lookupGeneration += 1
        isLookingUp = false
        guard !popups.isEmpty else { return }
        let popupIds = Set(popups.map(\.id))
        withAnimation(.default.speed(2.4)) {
            for index in popups.indices { popups[index].showPopup = false }
        } completion: {
            popups.removeAll { popupIds.contains($0.id) }
        }
    }

    private func closeChildPopups(parent: Int) {
        lookupGeneration += 1
        isLookingUp = false
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

private extension View {
    /// A tap on this view's empty space closes the dictionary popups. Buttons inside keep
    /// priority, so the controls still work with a popup open.
    func dismissesPopupsOnTap(_ dismiss: @escaping () -> Void) -> some View {
        contentShape(Rectangle()).onTapGesture(perform: dismiss)
    }
}

/// The stored pre-translation, collapsed by default and folded away again on every move.
private struct TranslationPanel: View {
    let markdown: String?
    @Binding var isExpanded: Bool
    let foregroundColor: Color
    var usage: ReaderUsageSession? = nil

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
                .frame(maxHeight: .infinity)
            }
        }
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }
}
