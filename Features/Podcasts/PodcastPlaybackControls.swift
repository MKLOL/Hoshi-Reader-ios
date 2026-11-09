import SwiftUI

struct PodcastPlaybackControls: View {
    @Bindable var playback: PodcastPlayback
    @State private var scrubbing = false
    @State private var scrubPosition: Double?

    var body: some View {
        VStack(spacing: 10) {
            // A finger drag previews its position and seeks once on release; every seek is
            // sample-accurate and saves the position. VoiceOver adjusts the value without an
            // editing session, so those changes seek at once.
            Slider(value: Binding(get: { scrubPosition ?? playback.position }, set: { value in
                if scrubbing { scrubPosition = value } else { playback.seek(to: value) }
            }), in: 0...max(1, playback.duration)) { editing in
                scrubbing = editing
                if !editing, let target = scrubPosition { scrubPosition = nil; playback.seek(to: target) }
            }
                .accessibilityLabel("Playback position")
            HStack {
                Text(StatisticsMath.duration(scrubPosition ?? playback.position)).monospacedDigit()
                Spacer()
                Text(StatisticsMath.duration(playback.duration)).monospacedDigit()
            }.font(.caption)
            HStack(spacing: 32) {
                Button { playback.seek(to: playback.position - 15) } label: { Image(systemName: "gobackward.15") }.accessibilityLabel("Back 15 seconds")
                Button { playback.toggle() } label: { Image(systemName: playback.playing ? "pause.fill" : "play.fill") }
                    .accessibilityLabel(playback.playing ? "Pause" : "Play")
                    .accessibilityIdentifier("podcast-play-pause")
                Button { playback.seek(to: playback.position + 15) } label: { Image(systemName: "goforward.15") }.accessibilityLabel("Forward 15 seconds")
            }.font(.title2).buttonStyle(.borderless).frame(maxWidth: .infinity)
            Picker("Speed", selection: $playback.speed) {
                ForEach(PodcastPlayback.speeds, id: \.self) { Text("\($0.formatted())×").tag($0) }
            }
        }
    }
}
