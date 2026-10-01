import XCTest
import SwiftUI
@testable import Hoshi_Reader

nonisolated final class SentenceTextViewTests: XCTestCase {
    @MainActor func testFullScreenSentenceCentersAndKeepsUnicodeTapCoordinates() async throws {
        let source = "😀日本語を読みます。"
        func sentence(_ text: String) -> SentenceTextView {
            SentenceTextView(text: text, font: .systemFont(ofSize: 26), color: .label,
                lineHeightMultiple: 1.4, highlight: nil, ruby: [], onTap: { _ in },
                onTapOutside: {}, onSwipeLeft: {}, onSwipeRight: {})
        }
        let host = UIHostingController(rootView: sentence(source))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }

        func findTextView(_ view: UIView) -> CenteringTextView? {
            if let text = view as? CenteringTextView { return text }
            return view.subviews.lazy.compactMap(findTextView).first
        }
        func settle(_ expected: String) async throws -> CenteringTextView {
            for _ in 0..<100 {
                host.view.layoutIfNeeded()
                if let text = findTextView(host.view), text.text == expected, text.bounds.height > 300 {
                    text.layoutIfNeeded()
                    return text
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("The full-screen sentence did not lay out")
            return try XCTUnwrap(findTextView(host.view))
        }

        let text = try await settle(source)
        // Exercise the real representable's initializer and first layout. The designated
        // TextKit 1 stack must be retained, and scrolling must remain available to this screen.
        XCTAssertNil(text.textLayoutManager)
        XCTAssertTrue(text.textContainer.layoutManager?.textStorage === text.textStorage)
        XCTAssertEqual(text.attributedText.string, source)
        XCTAssertTrue(text.isScrollEnabled)
        let layout = text.layoutManager
        layout.ensureLayout(for: text.textContainer)
        let used = layout.usedRect(for: text.textContainer)
        XCTAssertGreaterThan(used.height, 0)
        XCTAssertGreaterThan(text.textContainerInset.top, 0)
        XCTAssertEqual(used.midY + text.textContainerInset.top, text.bounds.height / 2, accuracy: 1)

        // The emoji occupies two UTF-16 code units. A tap on 日 must address the base
        // sentence's offset 2 and return a visible glyph rectangle for dictionary placement.
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: 2, length: 1), actualCharacterRange: nil)
        let glyph = layout.boundingRect(forGlyphRange: glyphs, in: text.textContainer)
        let point = CGPoint(x: glyph.midX + text.textContainerInset.left,
                            y: glyph.midY + text.textContainerInset.top)
        let tap = try XCTUnwrap(SentenceTextView.Coordinator.resolveTap(in: text, at: point))
        XCTAssertEqual(tap.characterOffset, 2)
        XCTAssertGreaterThan(tap.rect.width, 0)
        XCTAssertGreaterThan(tap.rect.height, 0)
        XCTAssertEqual(tap.rect.midX, point.x, accuracy: 0.5)
        XCTAssertEqual(tap.rect.midY, point.y - text.contentOffset.y, accuracy: 0.5)
        XCTAssertNil(SentenceTextView.Coordinator.resolveTap(in: text, at: CGPoint(x: 1, y: 1)))

        let longSentence = Array(repeating: source, count: 80).joined(separator: "\n")
        host.rootView = sentence(longSentence)
        let longText = try await settle(longSentence)
        XCTAssertTrue(longText.isScrollEnabled)
        XCTAssertGreaterThan(longText.contentSize.height, longText.bounds.height)
        XCTAssertEqual(longText.textContainerInset.top, 0, accuracy: 1)
    }
}
