import SwiftUI

struct PodcastPlaybackControls: View {
    @Bindable var playback: PodcastPlayback

    var body: some View {
        VStack(spacing: 10) {
            Slider(value: Binding(get: { playback.position }, set: { playback.seek(to: $0) }), in: 0...max(1, playback.duration))
                .accessibilityLabel("Playback position")
            HStack {
                Text(StatisticsMath.duration(playback.position)).monospacedDigit()
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
                ForEach([Float(0.75), 1, 1.25, 1.5, 2], id: \.self) { Text("\($0.formatted())×").tag($0) }
            }
        }
    }
}
