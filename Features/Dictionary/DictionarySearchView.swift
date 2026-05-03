//
//  DictionarySearchView.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import CHoshiDicts

struct DictionarySearchView: View {
    @Environment(UserConfig.self) private var userConfig
    @Environment(\.tabBarPlacement) private var tabBarPlacement
    @State private var query: String = ""
    @State private var lastQuery: String = ""
    /// Identifies the page that shows the current results. A page loads its HTML once, so it
    /// must be replaced in the same update that sets its content, never before the lookup.
    @State private var resultsPage = 0
    @State private var content: String = ""
    @State private var dictionaryStyles: [String: String] = [:]
    @State private var lookupEntries: [[String: Any]] = []
    @State private var hasSearched = false
    @State private var searchFocused = false
    @State private var didInitialQuery = false
    @State private var popups: [PopupItem] = []
    @State private var clearSelection: Bool = false
    var initialQuery: String = ""
    var initialAutofocus: Bool = true
    var shouldFocus: Bool = false
    
    private var usesTopTabBarLayout: Bool {
        tabBarPlacement == .topBar
    }
    
    private var searchBarInset: CGFloat {
        usesTopTabBarLayout ? 100 : 50
    }
    
    private var tabBarInset: CGFloat {
        usesTopTabBarLayout ? 0 : 45
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                PopupWebView(
                    content: content,
                    position: .zero,
                    clearSelection: clearSelection,
                    dictionaryStyles: dictionaryStyles,
                    lookupEntries: lookupEntries,
                    onMine: { minedContent in
                        await AnkiManager.shared.addNote(content: minedContent, context: MiningContext(sentence: lastQuery, documentTitle: nil, coverURL: nil))
                    },
                    onTextSelected: {
                        closePopups()
                        return await handleTextSelection($0, maxResults: userConfig.maxResults, scanLength: userConfig.scanLength, isVertical: false, isFullWidth: false)
                    },
                    onTapOutside: closePopups
                )
                .id(resultsPage)
                
                ForEach($popups) { $popup in
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
                        topInset: UIApplication.topSafeArea + searchBarInset,
                        bottomInset: max(UIApplication.bottomSafeArea, 30) + tabBarInset,
                        coverURL: nil,
                        documentTitle: nil,
                        clearSelection: popup.clearSelection,
                        onTextSelected: {
                            if let index = popups.firstIndex(where: { $0.id == popupId }) {
                                closeChildPopups(parent: index)
                            }
                            return await handleTextSelection($0, maxResults: userConfig.maxResults, scanLength: userConfig.scanLength, isVertical: false, isFullWidth: false)
                        },
                        onTapOutside: {
                            if let index = popups.firstIndex(where: { $0.id == popupId }) {
                                closeChildPopups(parent: index)
                            }
                        },
                        onSwipeDismiss: {
                            guard let index = popups.firstIndex(where: { $0.id == popupId }),
                                  popups.indices.contains(index) else {
                                return
                            }
                            if index == 0 {
                                clearSelection.toggle()
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
        }
        .ignoresSafeArea()
        .overlay(alignment: .top) {
            LinearGradient(colors: [Color(.systemBackground), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: UIApplication.topSafeArea + 50)
                .ignoresSafeArea(edges: .top)
        }
        .safeAreaInset(edge: .top) {
            DictionarySearchBar(text: $query, isFocused: $searchFocused) {
                Task { await runLookup() }
            }
        }
        .onChange(of: shouldFocus) {
            searchFocused = true
        }
        .onDisappear { closePopups() }
        .onAppear {
            if !didInitialQuery && !initialQuery.isEmpty {
                query = initialQuery
                Task { await runLookup() }
            }
            if initialAutofocus || didInitialQuery {
                searchFocused = false
                Task { @MainActor in
                    searchFocused = true
                }
            } else {
                searchFocused = false
                didInitialQuery = true
            }
        }
    }
    
    private func runLookup() async {
        closePopups()
        
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        hasSearched = true
        
        guard !trimmed.isEmpty else {
            showNothing(for: trimmed)
            return
        }
        
        let generation = lookupGeneration
        let snapshot = await LookupEngine.shared.lookupAsync(trimmed, maxResults: userConfig.maxResults, scanLength: userConfig.scanLength)
        guard !Task.isCancelled, generation == lookupGeneration, query.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
        let results = snapshot.results
        if results.isEmpty {
            showNothing(for: trimmed)
            return
        }
        
        constructHtml(results: results, styles: snapshot.styles)
        lastQuery = trimmed
        resultsPage += 1
    }
    
    private func showNothing(for query: String) {
        content = ""
        lookupEntries = []
        dictionaryStyles = [:]
        lastQuery = query
        resultsPage += 1
    }
    
    @State private var lookupGeneration = 0
    private func handleTextSelection(_ selection: SelectionData, maxResults: Int, scanLength: Int,  isVertical: Bool, isFullWidth: Bool) async -> Int? {
        guard !Task.isCancelled else { return nil }
        lookupGeneration += 1
        let generation = lookupGeneration
        let snapshot = await LookupEngine.shared.lookupAsync(selection.text, maxResults: maxResults, scanLength: scanLength)
        guard !Task.isCancelled, lookupGeneration == generation else { return nil }
        let lookupResults = snapshot.results
        let dictionaryStyles = snapshot.styles
        guard !lookupResults.isEmpty else { return nil }
        let popup = PopupItem(
            showPopup: false,
            currentSelection: selection,
            lookupResults: lookupResults,
            dictionaryStyles: dictionaryStyles,
            isVertical: isVertical,
            isFullWidth: isFullWidth,
            clearSelection: false
        )
        popups.append(popup)
        
        if let firstResult = lookupResults.first {
            withAnimation(.default.speed(2.2)) {
                popups = popups.map {
                    var p = $0
                    if p.id == popup.id {
                        p.showPopup = true
                    }
                    return p
                }
            }
            // `String(firstResult.matched)` stops resolving here ("no exact matches in call to
            // initializer") once the surrounding file gets heavy enough for the type-checker — the
            // documented CHoshiDicts interop fallback (see CxxStringInterop.swift).
            return cxxStringToSwift(firstResult.matched).unicodeScalars.count
        }
        return nil
    }

    private func closePopups() {
        lookupGeneration += 1
        let popupIds = Set(popups.map(\.id))
        withAnimation(.default.speed(2.4)) {
            for index in popups.indices {
                popups[index].showPopup = false
            }
        } completion: {
            popups.removeAll { popupIds.contains($0.id) }
        }
    }
    
    private func closeChildPopups(parent: Int) {
        lookupGeneration += 1
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
    
    private func constructHtml(results: [LookupResult], styles: [String: String]) {
        dictionaryStyles = styles

        // Reuse the shared entry builder so the inline `[String: Any]` literals (which were large
        // enough to risk type-checker timeouts) live in one already-fast place.
        lookupEntries = results.map { PopupView.entryDict(from: $0) }
        
        let collapsedDictionaries = userConfig.collapseMode == .custom
        ? ((try? JSONEncoder().encode(DictionaryManager.shared.collapsedDictionaries))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]") : "[]"
        let audioSources = (try? JSONEncoder().encode(userConfig.enabledAudioSources))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let customCSS = (try? JSONSerialization.data(withJSONObject: userConfig.customCSS, options: .fragmentsAllowed))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""

        // Hoist every interpolated value into a typed local so the large multiline string literal
        // type-checks trivially. Mixed Bool/String/enum interpolations inside one big literal are
        // exactly the kind of expression that can trip "unable to type-check in reasonable time" and
        // cascade into spurious CHoshiDicts `String(...)` interop errors elsewhere in the file.
        let anki = AnkiManager.shared
        let collapseMode: String = userConfig.collapseMode.rawValue
        let expandFirstDictionary: Bool = userConfig.expandFirstDictionary
        let compactGlossaries: Bool = userConfig.compactGlossaries
        let showExpressionTags: Bool = userConfig.showExpressionTags
        let harmonicFrequency: Bool = userConfig.harmonicFrequency
        let deduplicatePitchAccents: Bool = userConfig.deduplicatePitchAccents
        let compactPitchAccents: Bool = userConfig.compactPitchAccents
        let audioEnableAutoplay: Bool = userConfig.audioEnableAutoplay
        let audioPlaybackMode: String = userConfig.audioPlaybackMode.rawValue
        let needsAudio: Bool = anki.needsAudio
        let allowDupes: Bool = anki.allowDupes
        let useAnkiConnect: Bool = anki.useAnkiConnect
        let embedMedia: Bool = anki.embedMedia
        let compactGlossariesAnki: Bool = anki.compactGlossaries

        content = """
        <style>.overlay { padding-bottom: 90px; }</style>
        <script>
            window.collapseMode = "\(collapseMode)";
            window.expandFirstDictionary = \(expandFirstDictionary);
            window.collapsedDictionaries = \(collapsedDictionaries);
            window.compactGlossaries = \(compactGlossaries);
            window.showExpressionTags = \(showExpressionTags);
            window.harmonicFrequency = \(harmonicFrequency);
            window.deduplicatePitchAccents = \(deduplicatePitchAccents);
            window.compactPitchAccents = \(compactPitchAccents);
            window.audioSources = \(audioSources);
            window.audioEnableAutoplay = \(audioEnableAutoplay);
            window.audioPlaybackMode = "\(audioPlaybackMode)";
            window.needsAudio = \(needsAudio);
            window.allowDupes = \(allowDupes);
            window.useAnkiConnect = \(useAnkiConnect);
            window.embedMedia = \(embedMedia);
            window.compactGlossariesAnki = \(compactGlossariesAnki);
            window.customCSS = \(customCSS);
        </script>
        <div style="height: 50px;"></div>
        <div id="entries-container" style="min-height: 100vh;"></div>
        """
    }
}

struct DictionarySearchBar: View {
    @Binding var text: String
    @Binding var isFocused: Bool
    let onSubmit: () -> Void
    
    var body: some View {
        if #available(iOS 26, *) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
                
                CustomSearchField(searchText: $text, isFocused: $isFocused, onSubmit: onSubmit)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                if !text.isEmpty {
                    Button {
                        text = ""
                        isFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
            .glassEffect(.regular.interactive())
            .contentShape(Capsule())
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
        }
        else {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
                
                CustomSearchField(searchText: $text, isFocused: $isFocused, onSubmit: onSubmit)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                if !text.isEmpty {
                    Button {
                        text = ""
                        isFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(0.2), lineWidth: 1))
            .contentShape(Capsule())
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
        }
    }
}

struct CircleButton: View {
    @Environment(\.colorScheme) private var colorScheme
    let systemName: String
    let interactive: Bool
    let fontSize: CGFloat
    
    init(systemName: String, interactive: Bool = true, fontSize: CGFloat = 20) {
        self.systemName = systemName
        self.interactive = interactive
        self.fontSize = fontSize
    }
    
    var body: some View {
        if #available(iOS 26, *) {
            Image(systemName: systemName)
                .font(.system(size: fontSize))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .glassEffect(interactive ? .regular.interactive() : .regular)
                .padding(8)
                .contentShape(Circle())
        } else {
            Image(systemName: systemName)
                .font(.system(size: fontSize))
                .foregroundStyle(.primary)
                // Same 44pt footprint as the iOS 26 glass branch, so callers that layer a
                // scrim behind the button (manga reader top bar) get identical geometry.
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .padding(8)
                .contentShape(Circle())
        }
    }
}
