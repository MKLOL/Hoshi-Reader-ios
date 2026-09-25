import SwiftUI

struct PodcastsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = PodcastStore.shared
    @State private var playback = PodcastPlayback.shared
    @State private var length = PodcastLength.all
    @State private var showID: String?
    @State private var appeared = false
    private var shows: [PodcastShow] { store.catalogue.shows.filter { !$0.id.isEmpty && PodcastRules.display($0.name) != nil } }
    private var inShow: [PodcastEpisode] { store.catalogue.episodes.filter { showID == nil || $0.show == showID } }
    private var episodes: [PodcastEpisode] { inShow.filter(length.includes) }

    var body: some View {
        NavigationStack {
            List {
                if let episode = playback.episode {
                    Section("Now playing") {
                        Text(PodcastRules.display(episode.title) ?? "Podcast lesson").font(.headline)
                        Slider(value: Binding(get: { playback.position }, set: { playback.seek(to: $0) }), in: 0...max(1, playback.duration))
                            .accessibilityLabel("Playback position")
                        HStack {
                            Text(StatisticsMath.duration(playback.position)).monospacedDigit()
                            Spacer()
                            Text(StatisticsMath.duration(playback.duration)).monospacedDigit()
                        }.font(.caption)
                        HStack(spacing: 32) {
                            Button { playback.seek(to: playback.position - 15) } label: { Image(systemName: "gobackward.15") }.accessibilityLabel("Back 15 seconds")
                            Button { playback.toggle() } label: { Image(systemName: playback.playing ? "pause.fill" : "play.fill") }.accessibilityLabel(playback.playing ? "Pause" : "Play")
                            Button { playback.seek(to: playback.position + 15) } label: { Image(systemName: "goforward.15") }.accessibilityLabel("Forward 15 seconds")
                        }.font(.title2).buttonStyle(.borderless).frame(maxWidth: .infinity)
                        Picker("Speed", selection: $playback.speed) {
                            ForEach([Float(0.75), 1, 1.25, 1.5, 2], id: \.self) { Text("\($0.formatted())×").tag($0) }
                        }
                    }
                }
                if let error = playback.error {
                    Section { Text(error).foregroundStyle(.red) }
                }
                if let error = store.error {
                    Section { Text(error).foregroundStyle(.secondary); Button("Retry") { Task { await store.refresh() } } }
                }
                if let worker = store.catalogue.worker, worker.alive == false || !(worker.problems ?? []).isEmpty {
                    Section("Lesson worker") {
                        if worker.alive == false { Label("The worker is not running. Preparation will wait.", systemImage: "clock") }
                        ForEach(Array((worker.problems ?? []).enumerated()), id: \.offset) { _, problem in
                            if let text = PodcastRules.display(problem) { Text(text) }
                        }
                        if let seconds = worker.lastSeenSeconds { Text("Last report: \(max(0, seconds)) seconds ago").font(.caption) }
                    }
                }
                Section {
                    if shows.count > 1 {
                        ScrollView(.horizontal) {
                            HStack {
                                showButton("All shows", id: nil)
                                ForEach(shows) { show in showButton(String((PodcastRules.display(show.name) ?? show.id).prefix(60)), id: show.id) }
                            }
                        }.scrollIndicators(.hidden)
                    }
                    Picker("Original length", selection: $length) {
                        ForEach(PodcastLength.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.menu)
                    if store.catalogue.feedStale {
                        let stale = shows.filter { $0.feedStale == true }.compactMap { PodcastRules.display($0.name) }
                        Text(stale.isEmpty ? "Showing a saved listing; the server could not refresh the feeds." : "Showing saved listings for: " + stale.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if episodes.isEmpty {
                    Section {
                        if store.loading { ProgressView("Loading episodes…") }
                        else if !inShow.isEmpty && length != .all {
                            Text("\(inShow.count) episodes are hidden by the length filter.")
                            Button("All lengths") { length = .all }
                        } else { Text("No episodes available.").foregroundStyle(.secondary) }
                    }
                }
                ForEach(episodes) { episode in
                    Section {
                        episodeRow(episode)
                    }
                }

            }
            .navigationTitle("Podcasts")
            .refreshable { await store.refresh() }
            .toolbar { if store.loading { ProgressView() } }
            .task(id: appeared && scenePhase == .active) {
                let visible = appeared && scenePhase == .active
                store.setVisible(visible)
                guard visible else { return }
                while !Task.isCancelled, store.enabled, store.screenVisible {
                    await store.refresh()
                    do { try await Task.sleep(for: .seconds(5)) } catch { break }
                }
            }
            .onAppear { appeared = true }
            .onDisappear { appeared = false; store.setVisible(false) }
            .onChange(of: shows.map(\.id)) { _, ids in if let showID, ids.count < 2 || !ids.contains(showID) { self.showID = nil } }
        }
    }
    private func showButton(_ title: String, id: String?) -> some View {
        Button(title) { showID = id }
            .buttonStyle(.bordered)
            .tint(showID == id ? .accentColor : .secondary)
    }
    @ViewBuilder private func episodeRow(_ episode: PodcastEpisode) -> some View {
        Text(PodcastRules.display(episode.title) ?? "Podcast lesson").font(.headline)
        if let show = shows.first(where: { $0.id == episode.show }) { Text(String((PodcastRules.display(show.name) ?? show.id).prefix(60))).font(.subheadline).foregroundStyle(.secondary) }
        Text(episode.publishedAt).font(.caption).foregroundStyle(.secondary)
        Text(episode.durationSeconds > 0 ? "Original: \(StatisticsMath.duration(Double(episode.durationSeconds)))" : "Original length unknown").font(.caption)
        if let duration = episode.lessonDurationSeconds { Text("Lesson: \(StatisticsMath.duration(duration))").font(.caption) }
        if let error = store.downloadErrors[episode.id] { Text("Download: \(error)").font(.caption).foregroundStyle(.red) }
        if store.isDownloaded(episode.id) {
            Button { playback.play(episode) } label: { Label("Play lesson", systemImage: "play.circle.fill") }
        } else if let progress = store.downloads[episode.id] {
            if progress > 0 { ProgressView("Downloading…", value: progress) }
            else { ProgressView("Waiting for download…") }
        } else if episode.status == "ready" {
            Button { store.download(episode) } label: { Label("Download lesson", systemImage: "arrow.down.circle") }
        } else if ["queued", "preparing", "running", "processing", "generating"].contains(episode.status) || store.preparing.contains(episode.id) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                if let generation = store.catalogue.generating, let received = store.receivedUptime,
                   let fraction = generation.progress(for: episode.id, worker: store.catalogue.worker, elapsed: ProcessInfo.processInfo.systemUptime - received) {
                    ProgressView(generation.stageLabel, value: fraction)
                    Text("\(min(generation.total, max(0, generation.done))) of \(generation.total) · \(Int(fraction * 100))%").font(.caption)
                } else { ProgressView("Preparing lesson…") }
            }
        } else {
            if episode.status == "failed" {
                Text(PodcastRules.display(episode.errorMessage) ?? PodcastRules.display(episode.errorCode) ?? "Lesson preparation failed.").font(.caption).foregroundStyle(.red)
                if episode.needsAdministrator(maxFailures: store.catalogue.maxFailures) {
                    Text("Ask the administrator to resolve the problem and reset this episode in Book Sync.").font(.caption)
                } else if let limit = store.catalogue.maxFailures {
                    Text("\(max(0, limit - episode.failureCount)) attempts remaining").font(.caption)
                }
            }
            if !episode.needsAdministrator(maxFailures: store.catalogue.maxFailures) {
                Button("Prepare lesson") { Task { await store.prepare(episode) } }
            }
        }
    }
}
