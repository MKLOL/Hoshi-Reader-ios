import XCTest
import SwiftUI
import CHoshiDicts
import CxxStdlib
@testable import Hoshi_Reader

nonisolated final class PodcastTranscriptPlaybackTests: XCTestCase {
    @MainActor func testWordTapPausesAndOpensReaderDictionaryWithSentenceContext() async {
        var result = LookupResult()
        result.matched = std.string("本")
        var query = "", paused = false
        let lookup = PodcastTranscriptLookup { text, _, _ in
            query = text
            XCTAssertTrue(paused, "Pause before even beginning the lookup.")
            return LookupSnapshot(results: [result], styles: ["fixture": "body{}"])
        }
        let matched = await lookup.select(SelectionData(text: "本を読む", sentence: "本を読む",
            rect: CGRect(x: 12, y: 33, width: 12, height: 20)), line: 2, config: UserConfig(), pause: { paused = true })
        XCTAssertEqual(query, "本を読む")
        XCTAssertEqual(lookup.line, 2)
        XCTAssertEqual(matched, 1)
        XCTAssertEqual(lookup.popups.count, 1)
        XCTAssertEqual(lookup.popups.first?.currentSelection?.sentence, "本を読む")
        XCTAssertEqual(lookup.popups.first?.currentSelection?.rect.origin, CGPoint(x: 12, y: 33))
        XCTAssertEqual(lookup.popups.first?.dictionaryStyles["fixture"], "body{}")
        lookup.dismiss()
        XCTAssertTrue(paused, "Dismissing a card must not restart the recording.")
        XCTAssertTrue(lookup.popups.isEmpty)
    }

    @MainActor func testDismissedLookupCannotReopenAfterItsAsyncResultArrives() async {
        var response: CheckedContinuation<LookupSnapshot, Never>?
        let lookup = PodcastTranscriptLookup { _, _, _ in await withCheckedContinuation { response = $0 } }
        let task = Task { await lookup.select(SelectionData(text: "本", sentence: "本", rect: .zero),
            line: 0, config: UserConfig(), pause: {}) }
        while response == nil { await Task.yield() }
        lookup.dismiss()
        var result = LookupResult(); result.matched = std.string("本")
        response?.resume(returning: LookupSnapshot(results: [result], styles: [:]))
        let matched = await task.value
        XCTAssertNil(matched)
        XCTAssertTrue(lookup.popups.isEmpty)
        XCTAssertFalse(lookup.missingWord)
    }

    @MainActor func testOriginalAndLessonResumeIndependentlyAndTimestampStartsOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = PodcastFiles(root: root)
        let config = HttpSyncConfig(baseURL: "https://fixture.test", token: "fixture")
        let account = PodcastRules.account(baseURL: config.baseURL, token: config.token)
        let id = String(repeating: "a", count: 64)
        let episode = PodcastEpisode(id: id, title: "本を読む", publishedAt: "2026-10-01", status: "ready", lessonDurationSeconds: 60)
        files.validatedAccount = account
        let audio = Self.silentWAV(seconds: 60)
        try audio.write(to: XCTUnwrap(files.audio(account: account, id: id)))
        try audio.write(to: XCTUnwrap(files.originalAudio(account: account, id: id)))
        let transcript = PodcastTranscript(episode: id, duration: 60, lines: [.init(start: 0, end: 20, text: "本を読む", english: "Read a book")])
        try PodcastRules.encoder().encode(transcript).write(to: XCTUnwrap(files.transcript(account: account, id: id)))
        files.savePosition(12, account: account, id: id)
        files.savePosition(24, account: account, id: id, original: true)
        let store = PodcastStore(files: files, configuration: { config })
        let playback = PodcastPlayback(store: store)
        defer { playback.stop() }
        playback.prepareOriginal(episode)
        XCTAssertNil(playback.error)
        XCTAssertTrue(playback.original)
        XCTAssertFalse(playback.playing)
        XCTAssertEqual(playback.position, 24)
        playback.playOriginal(episode, from: 30)
        XCTAssertTrue(playback.playing)
        XCTAssertEqual(playback.position, 30)
        playback.pause()
        playback.playOriginal(episode, from: 59.5)
        XCTAssertTrue(playback.playing)
        XCTAssertEqual(playback.position, 59.5, "A timestamp in the final second must not restart the episode.")
        playback.seek(to: 30)
        playback.pause()
        playback.play(episode)
        XCTAssertFalse(playback.original)
        XCTAssertEqual(playback.position, 12)
        XCTAssertEqual(files.position(account: account, id: id, original: true), 30)
        playback.pause()
        playback.prepareOriginal(episode)
        XCTAssertEqual(playback.position, 30)
    }

    private static func silentWAV(seconds: Int) -> Data {
        let samples = seconds * 8_000
        var data = Data("RIFF".utf8)
        func u32(_ value: Int) { var n = UInt32(value).littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        func u16(_ value: Int) { var n = UInt16(value).littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        u32(36 + samples * 2); data.append(Data("WAVEfmt ".utf8)); u32(16)
        u16(1); u16(1); u32(8_000); u32(16_000); u16(2); u16(16)
        data.append(Data("data".utf8)); u32(samples * 2); data.append(Data(count: samples * 2))
        return data
    }
}
