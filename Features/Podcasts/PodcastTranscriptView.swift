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
    @State private var selectionRevision = 0
    @State private var transcriptFrame = CGRect.zero
    @State private var lookup = PodcastTranscriptLookup()
    init(episode: PodcastEpisode, store: PodcastStore = .shared, playback: PodcastPlayback = .shared,
         lookup: PodcastTranscriptLookup = PodcastTranscriptLookup()) {
        self.episode = episode; self.store = store; self.playback = playback
        _lookup = State(initialValue: lookup)
    }

    nonisolated private static let coordinateSpace = "podcast-transcript"

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
                    onDismiss: dismissLookup, onCloseChildren: lookup.closeChildren)
            }
            .coordinateSpace(name: Self.coordinateSpace)
        }
        .navigationTitle(PodcastRules.display(episode.title) ?? "Transcript")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { dismissLookup(); showAppearance = true } label: { Image(systemName: "textformat.size") }
                    .accessibilityLabel("Appearance")
                    .accessibilityIdentifier("podcast-appearance")
                if transcript?.lines.contains(where: { !($0.english?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }) == true {
                    Button { dismissLookup(); showEnglish.toggle() } label: { Image(systemName: "translate") }
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
        .onDisappear { dismissLookup() }
    }

    private func dismissLookup() {
        lookup.dismiss()
        selectionRevision += 1
    }

    private func lines(_ transcript: PodcastTranscript) -> some View {
        PodcastTranscriptWebView(transcript: transcript, config: config, current: current,
            showEnglish: showEnglish, following: following && lookup.popups.isEmpty,
            selectionRevision: selectionRevision,
            onPlay: { index in
                dismissLookup(); following = true
                playback.playOriginal(episode, from: transcript.lines[index].start)
            }, onSelect: { index, selection in
                let positioned = SelectionData(text: selection.text, sentence: selection.sentence,
                    rect: selection.rect.offsetBy(dx: transcriptFrame.minX, dy: transcriptFrame.minY))
                return await lookup.select(positioned, line: index, config: config, pause: playback.pause)
            }, onScroll: { following = false; dismissLookup() }, onTapOutside: dismissLookup)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.coordinateSpace)) } action: { transcriptFrame = $0 }
            .overlay(alignment: .bottomTrailing) {
                if !following {
                    Button { dismissLookup(); following = true } label: {
                        Label("Follow playback", systemImage: "location.fill")
                    }.buttonStyle(.borderedProminent).padding()
                }
            }
    }
}
