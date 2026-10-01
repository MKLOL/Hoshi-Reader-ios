import SwiftUI

struct PodcastTranscriptView: View {
    let episode: PodcastEpisode
    var store: PodcastStore = .shared
    var playback: PodcastPlayback = .shared
    @Environment(UserConfig.self) private var config
    @Environment(\.dismiss) private var dismiss
    @State private var transcript: PodcastTranscript?
    @State private var loaded = false
    @State private var showEnglish = false
    @State private var following = true
    @State private var showAppearance = false
    @State private var lookup = PodcastTranscriptLookup()
    init(episode: PodcastEpisode, store: PodcastStore = .shared, playback: PodcastPlayback = .shared,
         lookup: PodcastTranscriptLookup = PodcastTranscriptLookup()) {
        self.episode = episode; self.store = store; self.playback = playback
        _lookup = State(initialValue: lookup)
    }

    private static let coordinateSpace = "podcast-transcript"

    private var current: Int? {
        playback.isCurrent(episode, account: store.account, original: true) ? transcript?.line(at: playback.position) : nil
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let transcript {
                    VStack(spacing: 0) {
                        lines(transcript)
                        if lookup.missingWord {
                            Text("No dictionary match. Install a dictionary in Settings to look up words.")
                                .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                        }
                        if let error = playback.error { Text(error).foregroundStyle(.red).font(.caption).padding(.horizontal) }
                        PodcastPlaybackControls(playback: playback)
                            .padding().background(.bar)
                    }
                } else if loaded {
                    ContentUnavailableView("Transcript unavailable", systemImage: "text.alignleft", description: Text("Download the transcript and original recording again from Podcasts."))
                } else { ProgressView() }
                NativeDictionaryPopupStack(userConfig: config, popups: $lookup.popups,
                    screenSize: geometry.size, documentTitle: episode.title,
                    onTextSelected: { await lookup.show($0, config: config) },
                    onDismiss: lookup.dismiss, onCloseChildren: lookup.closeChildren)
            }
            .coordinateSpace(name: Self.coordinateSpace)
        }
        .navigationTitle(PodcastRules.display(episode.title) ?? "Transcript")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { lookup.dismiss(); showAppearance = true } label: { Image(systemName: "textformat.size") }
                    .accessibilityLabel("Appearance")
                    .accessibilityIdentifier("podcast-appearance")
                if transcript?.lines.contains(where: { !($0.english?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }) == true {
                    Button { showEnglish.toggle() } label: { Image(systemName: "translate") }
                        .accessibilityLabel(showEnglish ? "Hide English" : "Show English")
                        .accessibilityIdentifier("podcast-toggle-english")
                }
            }
        }
        .sheet(isPresented: $showAppearance) {
            AppearanceView(userConfig: config, showDismiss: true, textOnly: true)
                .presentationDetents([.medium, .large])
        }
        .task(id: store.account) {
            guard store.enabled else { lookup.dismiss(); transcript = nil; loaded = true; return }
            transcript = store.transcript(episode.id)
            loaded = true
            if transcript != nil { playback.prepareOriginal(episode) }
        }
        .onChange(of: store.enabled) { _, enabled in if !enabled { lookup.dismiss(); transcript = nil; dismiss() } }
        .onDisappear { lookup.dismiss() }
    }

    private func lines(_ transcript: PodcastTranscript) -> some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(transcript.lines.enumerated()), id: \.offset) { index, line in
                        PodcastTranscriptRow(line: line, index: index, active: current == index,
                            showEnglish: showEnglish, highlight: lookup.line == index ? lookup.highlight : nil,
                            config: config, coordinateSpace: Self.coordinateSpace, dismissLookup: lookup.dismiss,
                            play: {
                                lookup.dismiss(); following = true
                                playback.playOriginal(episode, from: line.start)
                            }, select: { tap, frame in
                                Task { await lookup.select(text: line.text, line: index, tap: tap,
                                    frame: frame, config: config, pause: playback.pause) }
                            })
                            .id(index)
                    }
                }.padding()
            }
            .accessibilityIdentifier("podcast-transcript-lines")
            .onScrollPhaseChange { _, phase in if phase == .interacting { following = false; lookup.dismiss() } }
            .onChange(of: current, initial: true) { _, index in
                if following, lookup.popups.isEmpty, let index {
                    withAnimation { scroll.scrollTo(index, anchor: UnitPoint(x: 0.5, y: 0.33)) }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !following {
                    Button {
                        following = true
                        if let current { withAnimation { scroll.scrollTo(current, anchor: UnitPoint(x: 0.5, y: 0.33)) } }
                    } label: { Label("Follow playback", systemImage: "location.fill") }
                        .buttonStyle(.borderedProminent).padding()
                }
            }
        }
    }
}

struct PodcastTranscriptRow: View {
    let line: PodcastTranscriptLine
    let index: Int
    let active: Bool
    let showEnglish: Bool
    let highlight: NSRange?
    let config: UserConfig
    let coordinateSpace: String
    let dismissLookup: () -> Void
    let play: () -> Void
    let select: (SentenceTap, CGRect) -> Void
    @State private var frame = CGRect.zero
    @State private var annotatedText: String?
    @State private var ruby: [RubyAnnotation] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: play) { Text(StatisticsMath.duration(line.start)).font(.caption.monospacedDigit()) }
                .accessibilityLabel("Play from \(StatisticsMath.duration(line.start))")
                .accessibilityIdentifier("podcast-time-\(index)")
            SentenceTextView(text: line.text,
                font: SentenceFontResolver.sentenceFont(named: config.selectedFont, size: config.fontSize),
                color: .label, lineHeightMultiple: CGFloat(config.lineHeight), highlight: highlight,
                ruby: !config.readerHideFurigana && annotatedText == line.text ? ruby : [],
                onTap: { select($0, frame) }, onTapOutside: dismissLookup, onSwipeLeft: {}, onSwipeRight: {}, fitsContent: true)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(coordinateSpace)) } action: { frame = $0 }
                .accessibilityIdentifier("podcast-text-\(index)")
            if showEnglish, let english = line.english, !english.isEmpty {
                Text(english).font(.body).foregroundStyle(.secondary)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(active ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityValue(active ? "Current line" : "")
        .task(id: config.readerHideFurigana ? nil : line.text) {
            annotatedText = nil; ruby = []
            guard !config.readerHideFurigana else { return }
            let text = line.text
            let work = Task.detached(priority: .userInitiated) { try JapaneseFurigana.annotations(for: text) }
            let result = try? await withTaskCancellationHandler {
                try await work.value
            } onCancel: { work.cancel() }
            guard !Task.isCancelled, let result else { return }
            ruby = result; annotatedText = text
        }
    }
}
