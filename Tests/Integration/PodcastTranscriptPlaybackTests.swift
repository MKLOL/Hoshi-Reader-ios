import XCTest
import SwiftUI
import CHoshiDicts
import CxxStdlib
@testable import Hoshi_Reader

nonisolated final class PodcastTranscriptPlaybackTests: XCTestCase {
    func testTapQueryAndHighlightUseWholeUnicodeCharacters() throws {
        let selection = try XCTUnwrap(PodcastTranscriptSelection(text: "😀日本語です", offset: 1))
        XCTAssertEqual(selection.offset, 0)
        XCTAssertEqual(selection.query, "😀日本語です")
        XCTAssertEqual(selection.highlight(matchedScalars: 3), NSRange(location: 0, length: 4))
        XCTAssertNil(PodcastTranscriptSelection(text: "日本", offset: -1))
        XCTAssertNil(PodcastTranscriptSelection(text: "日本", offset: 2))
        XCTAssertNil(PodcastTranscriptSelection(text: "  ", offset: 0))
    }

    @MainActor func testWordTapPausesAndOpensReaderDictionaryWithSentenceContext() async {
        var result = LookupResult()
        result.matched = std.string("本")
        var query = "", paused = false
        let lookup = PodcastTranscriptLookup { text, _, _ in
            query = text
            XCTAssertTrue(paused, "Pause before even beginning the lookup.")
            return LookupSnapshot(results: [result], styles: ["fixture": "body{}"])
        }
        await lookup.select(text: "本を読む", line: 2,
            tap: SentenceTap(characterOffset: 0, rect: CGRect(x: 2, y: 3, width: 12, height: 20)),
            frame: CGRect(x: 10, y: 30, width: 100, height: 30), config: UserConfig(), pause: { paused = true })
        XCTAssertEqual(query, "本を読む")
        XCTAssertEqual(lookup.line, 2)
        XCTAssertEqual(lookup.highlight, NSRange(location: 0, length: 1))
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
        let task = Task { await lookup.select(text: "本", line: 0,
            tap: SentenceTap(characterOffset: 0, rect: .zero), frame: .zero, config: UserConfig(), pause: {}) }
        while response == nil { await Task.yield() }
        lookup.dismiss()
        var result = LookupResult(); result.matched = std.string("本")
        response?.resume(returning: LookupSnapshot(results: [result], styles: [:]))
        await task.value
        XCTAssertTrue(lookup.popups.isEmpty)
        XCTAssertNil(lookup.highlight)
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

    @MainActor func testTranscriptTextFitsWrappedRowsAndResolvesRealGlyphTaps() async throws {
        let sentence = SentenceTextView(text: String(repeating: "日本語を読む。", count: 8),
            font: .systemFont(ofSize: 22), color: .label, lineHeightMultiple: 1.4, highlight: nil, ruby: [],
            onTap: { _ in }, onTapOutside: {}, onSwipeLeft: {}, onSwipeRight: {}, fitsContent: true)
        let host = UIHostingController(rootView: sentence.frame(width: 280))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        host.view.layoutIfNeeded()
        func find(_ view: UIView) -> UITextView? {
            if let text = view as? UITextView { return text }
            return view.subviews.lazy.compactMap(find).first
        }
        for _ in 0..<100 where find(host.view) == nil {
            try await Task.sleep(for: .milliseconds(10))
            host.view.layoutIfNeeded()
        }
        let text = try XCTUnwrap(find(host.view))
        XCTAssertFalse(text.isScrollEnabled)
        XCTAssertGreaterThan(text.bounds.height, 60)
        let rect = text.layoutManager.boundingRect(forGlyphRange: NSRange(location: 0, length: 1), in: text.textContainer)
        let tap = SentenceTextView.Coordinator.resolveTap(in: text, at: CGPoint(x: rect.midX, y: rect.midY + text.textContainerInset.top))
        XCTAssertEqual(tap?.characterOffset, 0)
        XCTAssertNil(SentenceTextView.Coordinator.resolveTap(in: text, at: CGPoint(x: -10, y: -10)))
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
