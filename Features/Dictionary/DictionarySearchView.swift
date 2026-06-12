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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var query: String = ""
    @State private var lastQuery: String = ""
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
        UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular
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
                        return handleTextSelection($0, maxResults: userConfig.maxResults, scanLength: userConfig.scanLength, isVertical: false, isFullWidth: false)
                    },
                    onTapOutside: closePopups
                )
                .id(lastQuery)
                
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
                            return handleTextSelection($0, maxResults: userConfig.maxResults, scanLength: userConfig.scanLength, isVertical: false, isFullWidth: false)
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
                runLookup()
            }
        }
        .onChange(of: shouldFocus) {
            searchFocused = true
        }
        .onAppear {
            if !didInitialQuery && !initialQuery.isEmpty {
                query = initialQuery
                runLookup()
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
    
    private func runLookup() {
        closePopups()
        
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        hasSearched = true
        lastQuery = trimmed
        
        guard !trimmed.isEmpty else {
            content = ""
            lookupEntries = []
            dictionaryStyles = [:]
            return
        }
        
        let results = LookupEngine.shared.lookup(trimmed, maxResults: userConfig.maxResults, scanLength: userConfig.scanLength)
        if results.isEmpty {
            content = ""
            lookupEntries = []
            dictionaryStyles = [:]
            return
        }
        
        constructHtml(results: results, styles: LookupEngine.shared.getStylesMap())
    }
    
    private func handleTextSelection(_ selection: SelectionData, maxResults: Int, scanLength: Int,  isVertical: Bool, isFullWidth: Bool) -> Int? {
        let lookupResults = LookupEngine.shared.lookup(selection.text, maxResults: maxResults, scanLength: scanLength)
        let dictionaryStyles = LookupEngine.shared.getStylesMap()
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
            return cxxStringToSwift(firstResult.matched).count
        }
        return nil
    }

    private func closePopups() {
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
        
        let audioSources = (try? JSONEncoder().encode(userConfig.enabledAudioSources))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let customCSS = (try? JSONSerialization.data(withJSONObject: userConfig.customCSS, options: .fragmentsAllowed))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""

        // Hoist every interpolated value into a typed local so the large multiline string literal
        // type-checks trivially. Mixed Bool/String/enum interpolations inside one big literal are
        // exactly the kind of expression that can trip "unable to type-check in reasonable time" and
        // cascade into spurious CHoshiDicts `String(...)` interop errors elsewhere in the file.
        let anki = AnkiManager.shared
        let collapseDictionaries: Bool = userConfig.collapseDictionaries
        let compactGlossaries: Bool = userConfig.compactGlossaries
        let showExpressionTags: Bool = userConfig.showExpressionTags
        let harmonicFrequency: Bool = userConfig.harmonicFrequency
        let deduplicatePitchAccents: Bool = userConfig.deduplicatePitchAccents
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
            window.collapseDictionaries = \(collapseDictionaries);
            window.compactGlossaries = \(compactGlossaries);
            window.showExpressionTags = \(showExpressionTags);
            window.harmonicFrequency = \(harmonicFrequency);
            window.deduplicatePitchAccents = \(deduplicatePitchAccents);
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
