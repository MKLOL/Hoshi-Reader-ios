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

    @MainActor func testContentFittingCanBeEnabledBeforeAnyTextOrRubyConfiguration() {
        let text = autoreleasepool { CenteringTextView(frame: .zero, textContainer: nil) }
        XCTAssertNil(text.textLayoutManager, "Glyph taps and ruby placement require TextKit 1.")
        XCTAssertTrue(text.layoutManager.textStorage === text.textStorage)
        XCTAssertTrue(text.ruby.isEmpty)
        text.fitsContent = true
        XCTAssertFalse(text.isScrollEnabled)
        XCTAssertEqual(text.textContainerInset.top, 0)
        XCTAssertTrue(text.rubyLayoutFrames.isEmpty)
    }

    @MainActor func testTranscriptTextFitsWrappedRowsAndResolvesRealGlyphTaps() async throws {
        let sentence = SentenceTextView(text: String(repeating: "日本語を読む。", count: 8),
            font: .systemFont(ofSize: 22), color: .black, lineHeightMultiple: 1.4, highlight: nil, ruby: [],
            onTap: { _ in }, onTapOutside: {}, onSwipeLeft: {}, onSwipeRight: {}, fitsContent: true)
        try await withHostedTextView(sentence) { text in
            XCTAssertFalse(text.isScrollEnabled)
            XCTAssertGreaterThan(text.bounds.height, 60)
            XCTAssertEqual(text.textContainerInset.top, 0)
            let rect = text.layoutManager.boundingRect(forGlyphRange: NSRange(location: 0, length: 1), in: text.textContainer)
            let tap = SentenceTextView.Coordinator.resolveTap(in: text, at: CGPoint(x: rect.midX, y: rect.midY + text.textContainerInset.top))
            XCTAssertEqual(tap?.characterOffset, 0)
            XCTAssertNil(SentenceTextView.Coordinator.resolveTap(in: text, at: CGPoint(x: -10, y: -10)))
        }
    }

    @MainActor func testContentFittingRubyReservesSpaceForTheFirstReadingAndMeasuresStably() async throws {
        let font = UIFont.systemFont(ofSize: 26)
        let sentence = SentenceTextView(text: "日本語を読む。", font: font, color: .black,
            lineHeightMultiple: 1.4, highlight: nil, ruby: [.init(start: 0, length: 3, reading: "にほんご")],
            onTap: { _ in }, onTapOutside: {}, onSwipeLeft: {}, onSwipeRight: {}, fitsContent: true)
        try await withHostedTextView(sentence) { text in
            let headroom = ceil(font.withSize(13).lineHeight)
            XCTAssertEqual(text.textContainerInset.top, headroom, accuracy: 0.5)
            let measured = text.sizeThatFits(CGSize(width: 280, height: CGFloat.greatestFiniteMagnitude))
            let used = text.layoutManager.usedRect(for: text.textContainer)
            XCTAssertGreaterThanOrEqual(measured.height, used.height + headroom - 0.5)
            let reading = try XCTUnwrap(text.rubyLayoutFrames.first)
            XCTAssertGreaterThanOrEqual(reading.minY, 0)
            XCTAssertLessThanOrEqual(reading.maxY, text.textContainerInset.top + 1)
            XCTAssertLessThanOrEqual(reading.maxX, text.bounds.width)
            XCTAssertGreaterThan(reading.height, 0)
            for _ in 0..<3 {
                text.setNeedsLayout(); text.layoutIfNeeded()
                XCTAssertEqual(text.sizeThatFits(CGSize(width: 280, height: CGFloat.greatestFiniteMagnitude)).height, measured.height, accuracy: 0.5)
                XCTAssertEqual(text.textContainerInset.top, headroom, accuracy: 0.5)
            }
        }
    }

    @MainActor func testRubyOnWrappedUnicodeTextKeepsGlyphTapOffsetsAndAnchors() async throws {
        let content = "😀日本語を読む。明日は図書館で本を読みます。さらに次の行にも続きます。"
        let secondWord = (content as NSString).range(of: "図書館")
        let sentence = SentenceTextView(text: content, font: .systemFont(ofSize: 24), color: .black,
            lineHeightMultiple: 1.4, highlight: nil,
            ruby: [.init(start: 2, length: 3, reading: "にほんご"),
                   .init(start: secondWord.location, length: secondWord.length, reading: "としょかん")],
            onTap: { _ in }, onTapOutside: {}, onSwipeLeft: {}, onSwipeRight: {}, fitsContent: true)
        try await withHostedTextView(sentence, width: 180) { text in
            var firstY: CGFloat?
            for offset in [2, secondWord.location, (content as NSString).range(of: "続").location] {
                let glyph = text.layoutManager.glyphRange(forCharacterRange: NSRange(location: offset, length: 1), actualCharacterRange: nil)
                let base = text.layoutManager.boundingRect(forGlyphRange: glyph, in: text.textContainer)
                if let firstY { XCTAssertGreaterThan(base.midY, firstY) } else { firstY = base.midY }
                let point = CGPoint(x: base.midX + text.textContainerInset.left, y: base.midY + text.textContainerInset.top)
                let tap = try XCTUnwrap(SentenceTextView.Coordinator.resolveTap(in: text, at: point))
                XCTAssertEqual(tap.characterOffset, offset)
                XCTAssertEqual(tap.rect.midX, point.x, accuracy: 0.5)
                XCTAssertEqual(tap.rect.midY, point.y, accuracy: 0.5)
                if offset == secondWord.location {
                    let reading = try XCTUnwrap(text.rubyLayoutFrames.last)
                    XCTAssertTrue(reading.contains(CGPoint(x: point.x, y: reading.midY)),
                        "A wrapped base must keep its reading above its own first line, not unrelated adjacent text.")
                }
            }
            XCTAssertNil(SentenceTextView.Coordinator.resolveTap(in: text, at: CGPoint(x: 5, y: 1)),
                "Reading space above the first base must not select a neighboring character.")
        }
    }

    @MainActor func testFirstLineRubyActuallyDrawsAndDisappearsWhenRemoved() async throws {
        let annotations = [RubyAnnotation(start: 0, length: 3, reading: "にほんご")]
        let sentence = SentenceTextView(text: "日本語を読む。", font: .systemFont(ofSize: 26), color: .black,
            lineHeightMultiple: 1.4, highlight: nil, ruby: annotations,
            onTap: { _ in }, onTapOutside: {}, onSwipeLeft: {}, onSwipeRight: {}, fitsContent: true)
        try await withHostedTextView(sentence) { text in
            // A distinct annotation color distinguishes ruby ink from the base text even when
            // removing the readings moves that base text into the former reading space.
            let readingFont = UIFont.systemFont(ofSize: 13)
            text.configureRuby(annotations, font: readingFont, color: .red)
            let headroom = CGRect(x: 0, y: 0, width: text.bounds.width, height: text.textContainerInset.top)
            let shown = renderedImage(of: text)
            XCTAssertGreaterThan(try redPixelCount(in: shown, region: headroom), 5,
                "The reserved first-line space must contain drawn readings, not just valid geometry.")

            text.configureRuby([], font: readingFont, color: .red)
            let hidden = renderedImage(of: text)
            XCTAssertEqual(try redPixelCount(in: hidden, region: CGRect(origin: .zero, size: hidden.size)), 0,
                "Removing annotations must remove their rendered ink as well.")
        }
    }

    @MainActor func testCenteredSentenceCanReuseTheSameRubyViewForContentFittingRows() async throws {
        let sentence = SentenceTextView(text: "日本語。", font: .systemFont(ofSize: 24), color: .black,
            lineHeightMultiple: 1.4, highlight: nil, ruby: [.init(start: 0, length: 3, reading: "にほんご")],
            onTap: { _ in }, onTapOutside: {}, onSwipeLeft: {}, onSwipeRight: {})
        try await withHostedTextView(sentence, height: 400) { text in
            XCTAssertTrue(text.isScrollEnabled)
            let headroom = ceil(UIFont.systemFont(ofSize: 12).lineHeight)
            let used = text.layoutManager.usedRect(for: text.textContainer).height
            XCTAssertGreaterThan(text.textContainerInset.top, headroom)
            XCTAssertEqual(text.textContainerInset.top - headroom,
                text.bounds.height - text.textContainerInset.top - used, accuracy: 1)
            text.fitsContent = true
            text.layoutIfNeeded()
            XCTAssertFalse(text.isScrollEnabled)
            XCTAssertEqual(text.textContainerInset.top, headroom, accuracy: 0.5)
            let fitted = text.sizeThatFits(CGSize(width: 280, height: CGFloat.greatestFiniteMagnitude))
            XCTAssertLessThan(fitted.height, 100, "A row must not inherit the previous sentence screen's centering padding.")
            text.fitsContent = false
            text.layoutIfNeeded()
            XCTAssertTrue(text.isScrollEnabled)
            XCTAssertGreaterThan(text.textContainerInset.top, headroom)
        }
    }

    @MainActor func testInvalidRubyAndHighlightRangesCannotOverflowOrAddEmptyReadingSpace() async throws {
        let sentence = SentenceTextView(text: "日本語。", font: .systemFont(ofSize: 24), color: .black,
            lineHeightMultiple: 1.4, highlight: NSRange(location: Int.max, length: Int.max),
            ruby: [.init(start: Int.max, length: Int.max, reading: "invalid"), .init(start: 0, length: 3, reading: " ")],
            onTap: { _ in }, onTapOutside: {}, onSwipeLeft: {}, onSwipeRight: {}, fitsContent: true)
        try await withHostedTextView(sentence) { text in
            XCTAssertEqual(text.textContainerInset.top, 0)
            XCTAssertEqual(text.text, "日本語。")
        }
    }

    @MainActor private func withHostedTextView(_ sentence: SentenceTextView, width: CGFloat = 280,
        height: CGFloat? = nil, check: (CenteringTextView) throws -> Void) async throws {
        let host = UIHostingController(rootView: sentence.frame(width: width, height: height))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        host.view.layoutIfNeeded()
        func find(_ view: UIView) -> CenteringTextView? {
            if let text = view as? CenteringTextView { return text }
            return view.subviews.lazy.compactMap(find).first
        }
        for _ in 0..<100 where find(host.view) == nil {
            try await Task.sleep(for: .milliseconds(10))
            host.view.layoutIfNeeded()
        }
        let text = try XCTUnwrap(find(host.view))
        text.layoutIfNeeded()
        try check(text)
    }

    @MainActor private func renderedImage(of view: UIView) -> UIImage {
        view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { context in
            UIColor.white.setFill()
            context.fill(view.bounds)
            XCTAssertTrue(view.drawHierarchy(in: view.bounds, afterScreenUpdates: true))
        }
    }

    private func redPixelCount(in image: UIImage, region: CGRect) throws -> Int {
        let cropped = try XCTUnwrap(image.cgImage?.cropping(to: region.integral))
        var pixels = [UInt8](repeating: 0, count: cropped.width * cropped.height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: cropped.width,
                height: cropped.height, bitsPerComponent: 8, bytesPerRow: cropped.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        }
        return stride(from: 0, to: pixels.count, by: 4).filter {
            pixels[$0] > 120 && pixels[$0 + 1] < 80 && pixels[$0 + 2] < 80 && pixels[$0 + 3] > 128
        }.count
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
