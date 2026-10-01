#if DEBUG
import SwiftUI
import CHoshiDicts
import CxxStdlib

/// Opt-in synthetic content for UI automation. No server, credentials, real books or recordings.
struct PodcastTranscriptUITestFixture: View {
    private let episode: PodcastEpisode
    private let store: PodcastStore
    private let playback: PodcastPlayback
    private let lookup: PodcastTranscriptLookup

    init() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("podcast-ui-fixture")
        try? FileManager.default.removeItem(at: root)
        let files = PodcastFiles(root: root)
        let config = HttpSyncConfig(baseURL: "https://fixture.invalid", token: "synthetic")
        let account = PodcastRules.account(baseURL: config.baseURL, token: config.token)
        let id = String(repeating: "a", count: 64)
        episode = PodcastEpisode(id: id, title: "Podcast transcript", publishedAt: "2026-10-01", status: "ready", transcript: true)
        files.validatedAccount = account
        let lines = (0..<24).map { index in
            PodcastTranscriptLine(start: Double(index * 10), end: Double(index * 10 + 8), text: "本を読みます。日本語を勉強します。", english: "I read books. I study Japanese.")
        }
        let transcript = PodcastTranscript(episode: id, duration: 240, lines: lines)
        try? PodcastRules.encoder().encode(transcript).write(to: files.transcript(account: account, id: id)!)
        var audio = Data("RIFF".utf8)
        func u32(_ value: Int) { var number = UInt32(value).littleEndian; withUnsafeBytes(of: &number) { audio.append(contentsOf: $0) } }
        func u16(_ value: Int) { var number = UInt16(value).littleEndian; withUnsafeBytes(of: &number) { audio.append(contentsOf: $0) } }
        let bytes = 240 * 8_000 * 2
        u32(36 + bytes); audio.append(Data("WAVEfmt ".utf8)); u32(16)
        u16(1); u16(1); u32(8_000); u32(16_000); u16(2); u16(16)
        audio.append(Data("data".utf8)); u32(bytes); audio.append(Data(count: bytes))
        try? audio.write(to: files.originalAudio(account: account, id: id)!)
        store = PodcastStore(files: files, configuration: { config })
        playback = PodcastPlayback(store: store)
        lookup = PodcastTranscriptLookup { _, _, _ in
            var result = LookupResult()
            result.matched = std.string("本"); result.term.expression = std.string("本"); result.term.reading = std.string("ほん")
            return LookupSnapshot(results: [result], styles: [:])
        }
    }

    var body: some View {
        NavigationStack { PodcastTranscriptView(episode: episode, store: store, playback: playback, lookup: lookup) }
    }
}
#endif
