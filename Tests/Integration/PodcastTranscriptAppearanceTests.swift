import XCTest
import SwiftUI
import CoreText
@testable import Hoshi_Reader

nonisolated final class PodcastTranscriptAppearanceTests: XCTestCase {
    @MainActor func testTranscriptGeneratesVisibleRubyAndFollowsReaderAppearanceChanges() async throws {
        let defaults = UserDefaults.standard
        let saved = ["selectedFont", "fontSize", "readerHideFurigana"].map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in saved { defaults.set(value, forKey: key) } }
        let config = UserConfig()
        config.selectedFont = "Hiragino Mincho ProN"; config.fontSize = 26; config.readerHideFurigana = false
        let row = PodcastTranscriptRow(
            line: .init(start: 0, end: 10, text: "本を読みます。日本語を勉強します。", english: nil),
            index: 0, active: false, showEnglish: false, highlight: nil, config: config,
            coordinateSpace: "fixture", dismissLookup: {}, play: {}, select: { _, _ in })
        let host = UIHostingController(rootView: row.frame(width: 280))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        func textView(_ view: UIView) -> CenteringTextView? {
            if let text = view as? CenteringTextView { return text }
            return view.subviews.lazy.compactMap(textView).first
        }
        func waitFor(_ predicate: () -> Bool) async throws {
            for _ in 0..<200 {
                host.view.layoutIfNeeded()
                if predicate() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("Transcript appearance did not update")
        }
        try await waitFor { textView(host.view)?.ruby.isEmpty == false }
        let text = try XCTUnwrap(textView(host.view))
        XCTAssertTrue(text.ruby.contains { $0.reading == "ほん" })
        // UITextView.font retains its typing default after attributed-text updates. Inspect the
        // effective font used by the glyphs, which must follow every reader appearance change.
        func effectiveFont() -> UIFont? {
            text.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        }
        func assertGlyphFont(_ name: String, size: CGFloat) {
            let line = CTLineCreateWithAttributedString(text.attributedText)
            let runs = CTLineGetGlyphRuns(line) as! [CTRun]
            XCTAssertFalse(runs.isEmpty)
            for run in runs {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                let font = attributes[kCTFontAttributeName] as! CTFont
                XCTAssertEqual(CTFontCopyPostScriptName(font) as String, name)
                XCTAssertEqual(CTFontGetSize(font), size, accuracy: 0.01)
            }
        }
        assertGlyphFont("HiraMinProN-W3", size: 28.6)
        XCTAssertFalse(text.rubyLayoutFrames.isEmpty)
        for rect in text.rubyLayoutFrames {
            XCTAssertGreaterThanOrEqual(rect.minY, 0)
            XCTAssertLessThanOrEqual(rect.maxY, text.bounds.height)
        }

        config.readerHideFurigana = true
        try await waitFor { text.ruby.isEmpty }
        XCTAssertTrue(text.rubyLayoutFrames.isEmpty)
        config.selectedFont = "Hiragino Kaku Gothic ProN"; config.fontSize = 30
        try await waitFor { effectiveFont()?.fontName == "HiraKakuProN-W3" && effectiveFont()?.pointSize == 33 }
        assertGlyphFont("HiraKakuProN-W3", size: 33)
        config.readerHideFurigana = false
        try await waitFor { !text.ruby.isEmpty }
        XCTAssertTrue(text.ruby.contains { $0.reading == "ほん" })
        assertGlyphFont("HiraKakuProN-W3", size: 33)
        XCTAssertEqual(text.text, "本を読みます。日本語を勉強します。", "Readings never replace the text addressed by dictionary taps.")
    }
}
