import XCTest
import SwiftUI
import WebKit
@testable import Hoshi_Reader

nonisolated final class PodcastTranscriptAppearanceTests: XCTestCase {
    @MainActor func testTranscriptGeneratesVisibleRubyAndFollowsReaderAppearanceChanges() async throws {
        let browser = try TranscriptTestBrowser()
        defer { browser.close() }
        let web = try await browser.loadedWebView()
        try await browser.waitFor("document.querySelector('#podcast-text-0 ruby rt')?.textContent === 'たと'")
        try await assertJavaScript(web, """
            (() => {
                const style = getComputedStyle(document.querySelector('#podcast-text-0'));
                return style.fontFamily.includes('Hiragino Mincho ProN') && style.fontSize === '26px' &&
                    style.lineHeight === 'normal' && document.fonts.check('26px "Hiragino Mincho ProN"', '例えば本');
            })()
            """, "Transcript typography must use the EPUB font and exact configured size.")
        let original = try await web.evaluateJavaScript(Self.baseTextScript(index: 0)) as? String
        XCTAssertEqual(original, TranscriptTestBrowser.firstLine)
        let originalGlyphHeight = try await glyphHeight(web)

        browser.config.readerHideFurigana = true
        browser.update()
        try await browser.waitFor("Array.from(document.querySelectorAll('#podcast-text-0 rt')).every(rt => getComputedStyle(rt).display === 'none' || rt.getBoundingClientRect().height === 0)")
        let hiddenText = try await web.evaluateJavaScript(Self.baseTextScript(index: 0)) as? String
        XCTAssertEqual(hiddenText, original)

        browser.config.selectedFont = "Hiragino Kaku Gothic ProN"
        browser.config.fontSize = 30
        browser.update()
        try await browser.waitFor("getComputedStyle(document.querySelector('#podcast-text-0')).fontFamily.includes('Hiragino Kaku Gothic ProN') && getComputedStyle(document.querySelector('#podcast-text-0')).fontSize === '30px'")
        browser.config.readerHideFurigana = false
        browser.update()
        try await browser.waitFor("document.querySelector('#podcast-text-0 rt')?.getBoundingClientRect().height > 0")
        let enlargedGlyphHeight = try await glyphHeight(web)
        XCTAssertGreaterThan(enlargedGlyphHeight, originalGlyphHeight)
        let shownText = try await web.evaluateJavaScript(Self.baseTextScript(index: 0)) as? String
        XCTAssertEqual(shownText, original)

        browser.config.layoutAdvanced = true
        browser.config.lineHeight = 1.8
        browser.config.characterSpacing = 5
        browser.update()
        try await browser.waitFor("getComputedStyle(document.querySelector('#podcast-text-0')).lineHeight === '54px' && getComputedStyle(document.querySelector('#podcast-text-0')).letterSpacing === '1.5px'")
        XCTAssertTrue(browser.webView === web, "Appearance changes update the existing document without replacing the WebView.")
    }

    @MainActor func testRubySeparatesOkuriganaAndUsesNativeWebKitLayoutWhenWrapped() async throws {
        let browser = try TranscriptTestBrowser(width: 220)
        defer { browser.close() }
        let web = try await browser.loadedWebView()
        try await browser.waitFor("document.querySelectorAll('#podcast-text-2 ruby').length >= 4")
        try await assertJavaScript(web, """
            (() => {
                const p = document.querySelector('#podcast-text-0');
                const ruby = p.querySelector('ruby'), rt = ruby.querySelector('rt');
                const base = ruby.cloneNode(true); base.querySelectorAll('rt,rp').forEach(n => n.remove());
                let tail = '', next = ruby.nextSibling;
                while (next?.nodeType === Node.TEXT_NODE) { tail += next.textContent; next = next.nextSibling; }
                return base.textContent === '例' && rt.textContent === 'たと' &&
                    tail.startsWith('えば') &&
                    getComputedStyle(ruby).display === 'ruby' && getComputedStyle(rt).display === 'ruby-text' &&
                    getComputedStyle(rt).position === 'static';
            })()
            """, "例えば must render as native ruby 例(たと) followed by ordinary えば.")
        try await assertJavaScript(web, """
            (() => {
                const p = document.querySelector('#podcast-text-2'), boxes = [];
                for (const ruby of p.querySelectorAll('ruby')) {
                    const rt = ruby.querySelector('rt');
                    const base = Array.from(ruby.childNodes).find(n => n.nodeType === Node.TEXT_NODE || (n.nodeType === Node.ELEMENT_NODE && !n.matches('rt,rp')));
                    if (!rt || !base) return false;
                    const range = document.createRange(); range.selectNodeContents(base);
                    const b = range.getBoundingClientRect(), r = rt.getBoundingClientRect();
                    if (!(b.width > 0 && r.width > 0 && r.height > 0 &&
                          r.top + r.height / 2 < b.top + b.height / 2 && r.right >= b.left && r.left <= b.right)) return false;
                    boxes.push(b);
                }
                return boxes.length >= 4 && boxes.at(-1).top > boxes[0].top + 20 &&
                    document.documentElement.scrollWidth <= innerWidth + 1;
            })()
            """, "WebKit must attach each reading above its own base while wrapping without horizontal overflow.")
        let unicode = try await web.evaluateJavaScript(Self.baseTextScript(index: 1)) as? String
        let long = try await web.evaluateJavaScript(Self.baseTextScript(index: 2)) as? String
        XCTAssertEqual(unicode, TranscriptTestBrowser.unicodeLine)
        XCTAssertEqual(long, TranscriptTestBrowser.longLine)
    }

    @MainActor func testSharedReaderSelectionExcludesRubyAndTimestampActions() async throws {
        let browser = try TranscriptTestBrowser()
        defer { browser.close() }
        let web = try await browser.loadedWebView()
        try await browser.waitFor("document.querySelector('#podcast-text-1 ruby rt') != null")
        _ = try await web.evaluateJavaScript("""
            (() => {
                const walker = window.hoshiSelection.createWalker(document.querySelector('#podcast-text-1'));
                for (let node; node = walker.nextNode();) {
                    const offset = node.textContent.indexOf('本');
                    if (offset < 0) continue;
                    const range = document.createRange(); range.setStart(node, offset); range.setEnd(node, offset + 1);
                    const rect = range.getBoundingClientRect();
                    window.hoshiTranscript.selectAt(rect.left + rect.width / 2, rect.top + rect.height / 2);
                    return true;
                }
                return false;
            })()
            """)
        try await browser.waitUntil { browser.selections.count == 1 }
        let selection = try XCTUnwrap(browser.selections.first)
        XCTAssertEqual(selection.0, 1)
        XCTAssertEqual(selection.1.text, "本を読みます")
        XCTAssertTrue(selection.1.sentence.contains("本を読みます"))
        XCTAssertFalse(selection.1.sentence.contains("ほん"))
        XCTAssertTrue(browser.plays.isEmpty, "Dictionary selection must not fire the timestamp action.")

        _ = try await web.evaluateJavaScript("""
            (() => {
                const rect = document.querySelector('#podcast-time-1').getBoundingClientRect();
                window.hoshiTranscript.selectAt(rect.left + rect.width / 2, rect.top + rect.height / 2);
            })()
            """)
        XCTAssertTrue(browser.plays.isEmpty, "The native lookup recognizer leaves browser button activation alone.")
        _ = try await web.evaluateJavaScript("document.querySelector('#podcast-time-1').click()")
        try await browser.waitUntil { browser.plays == [1] }
        XCTAssertEqual(browser.selections.count, 1, "A timestamp starts playback without selecting its digits.")
    }

    @MainActor func testFollowingRevealsCurrentLineWithoutMovingIndependentReading() async throws {
        let browser = try TranscriptTestBrowser(width: 220, height: 400)
        defer { browser.close() }
        let web = try await browser.loadedWebView()
        try await browser.waitFor("document.documentElement.dataset.readingsReady === 'true'")
        browser.current = 2; browser.following = true; browser.update()
        try await browser.waitFor("document.querySelector('#podcast-line-2').classList.contains('current') && window.scrollY > 20")
        browser.following = false; browser.update()
        _ = try await web.evaluateJavaScript("window.scrollTo(0, 0)")
        browser.current = 1; browser.update()
        try await browser.waitFor("document.querySelector('#podcast-line-1').classList.contains('current')")
        let position = try await web.evaluateJavaScript("window.scrollY") as? Double
        XCTAssertEqual(try XCTUnwrap(position), 0, accuracy: 1, "Changing the active line must leave an independent reader's viewport alone.")
        browser.current = 2; browser.following = true; browser.update()
        try await browser.waitFor("window.scrollY > 20")
        try await assertJavaScript(web, """
            (() => { const r = document.querySelector('#podcast-line-2').getBoundingClientRect();
                return r.top >= 0 && r.top < innerHeight / 2; })()
            """, "Following must bring the current line back into view.")
        XCTAssertTrue(browser.plays.isEmpty, "Following the text must never initiate playback.")
    }

    @MainActor func testDelayedFontLoadCannotRestoreAnAnchorAfterTheReaderScrolls() async throws {
        let browser = try TranscriptTestBrowser(width: 220, height: 400)
        defer { browser.close() }
        let web = try await browser.loadedWebView()
        try await browser.waitFor("document.documentElement.dataset.readingsReady === 'true'")
        _ = try await web.callAsyncJavaScript("await document.fonts.ready; return true", arguments: [:], in: nil, contentWorld: .page)
        _ = try await web.evaluateJavaScript("""
            (() => {
                window.testFontWaitObserved = false;
                const pending = new Promise(resolve => { window.finishTestFontLoad = resolve; });
                Object.defineProperty(document.fonts, 'ready', {configurable: true, get() {
                    window.testFontWaitObserved = true; return pending;
                }});
                return true;
            })()
            """)
        browser.config.fontSize = 30
        browser.update()
        try await browser.waitFor("window.testFontWaitObserved === true")

        // Enter through UIKit's actual scroll delegate so this also covers the native-to-JS
        // invalidation hook, while the normal stylesheet update remains suspended on font loading.
        web.scrollView.delegate?.scrollViewWillBeginDragging?(web.scrollView)
        let requestedValue = try await web.callAsyncJavaScript("""
            await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
            window.scrollTo(0, document.documentElement.scrollHeight);
            await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
            return {y: window.scrollY, height: document.documentElement.scrollHeight, viewport: innerHeight,
                revision: window.hoshiTranscript.layoutRevision, anchor: window.hoshiTranscript.visibleAnchor()};
            """, arguments: [:], in: nil, contentWorld: .page)
        let requestedState = try XCTUnwrap(requestedValue as? [String: Any])
        let requestedPosition = try XCTUnwrap(requestedState["y"] as? Double)
        XCTAssertGreaterThan(requestedPosition, 80, "The reader must have moved away from the original anchor.")
        XCTAssertEqual(browser.scrollEvents, 1)
        let finishedValue = try await web.callAsyncJavaScript("""
            window.finishTestFontLoad();
            await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
            delete document.fonts.ready;
            return {y: window.scrollY, height: document.documentElement.scrollHeight, viewport: innerHeight,
                revision: window.hoshiTranscript.layoutRevision, anchor: window.hoshiTranscript.visibleAnchor()};
            """, arguments: [:], in: nil, contentWorld: .page)
        let finishedState = try XCTUnwrap(finishedValue as? [String: Any])
        let finishedPosition = try XCTUnwrap(finishedState["y"] as? Double)
        XCTAssertEqual(finishedPosition, requestedPosition, accuracy: 1,
                       "A delayed font completion must not restore the old viewport over a newer user scroll. Before: \(requestedState); after: \(finishedState)")
    }

    private static func baseTextScript(index: Int) -> String {
        "(() => { const p = document.querySelector('#podcast-text-\(index)').cloneNode(true); p.querySelectorAll('rt,rp').forEach(n => n.remove()); return p.textContent; })()"
    }

    @MainActor private func glyphHeight(_ web: WKWebView) async throws -> Double {
        let result = try await web.evaluateJavaScript("""
            (() => { const base = document.querySelector('#podcast-text-0 ruby').firstChild;
                const range = document.createRange(); range.selectNodeContents(base); return range.getBoundingClientRect().height; })()
            """)
        return try XCTUnwrap(result as? Double)
    }

    @MainActor private func assertJavaScript(_ web: WKWebView, _ script: String, _ message: String,
                                            file: StaticString = #filePath, line: UInt = #line) async throws {
        let result = try await web.evaluateJavaScript(script)
        XCTAssertEqual(result as? Bool, true, message, file: file, line: line)
    }
}

/// Hosts the production representable and its real bundled scripts; no duplicate HTML renderer.
@MainActor private final class TranscriptTestBrowser {
    static let firstLine = "例えば、本を読みます。"
    static let unicodeLine = "😀か\u{3099}、本を読みます。日本語を勉強します。"
    static let longLine = String(repeating: "例えば、本を読みます。", count: 5)
    let config: UserConfig
    private let transcript: PodcastTranscript
    private let savedDefaults: [(String, Any?)]
    private let window: UIWindow
    private weak var previous: UIWindow?
    private var host: UIHostingController<AnyView>!
    private let width: CGFloat
    private let height: CGFloat
    var plays: [Int] = []
    var selections: [(Int, SelectionData)] = []
    var current: Int?
    var following = false
    var scrollEvents = 0
    private(set) var webView: WKWebView?

    init(width: CGFloat = 300, height: CGFloat = 700) throws {
        self.width = width
        self.height = height
        savedDefaults = ["selectedFont", "fontSize", "readerHideFurigana", "layoutAdvanced", "lineHeight", "characterSpacing"]
            .map { ($0, UserDefaults.standard.object(forKey: $0)) }
        config = UserConfig()
        config.selectedFont = "Hiragino Mincho ProN"; config.fontSize = 26
        config.readerHideFurigana = false; config.layoutAdvanced = false
        transcript = PodcastTranscript(episode: String(repeating: "a", count: 64), duration: 30,
            lines: [Self.firstLine, Self.unicodeLine, Self.longLine].enumerated().map { (index, text) -> PodcastTranscriptLine in
                let start = Double(index * 10)
                return PodcastTranscriptLine(start: start, end: start + 8, text: text, english: nil)
            })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previous = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        host = UIHostingController(rootView: content())
        window.rootViewController = host; window.makeKeyAndVisible()
    }

    private func content() -> AnyView {
        AnyView(PodcastTranscriptWebView(transcript: transcript, config: config, current: current, showEnglish: false,
            following: following, selectionRevision: 0, onPlay: { [weak self] in self?.plays.append($0) },
            onSelect: { [weak self] index, selection in self?.selections.append((index, selection)); return 1 },
            onScroll: { [weak self] in self?.scrollEvents += 1 }, onTapOutside: {}).frame(width: width, height: height))
    }

    func update() { host.rootView = content(); host.view.layoutIfNeeded() }

    func loadedWebView() async throws -> WKWebView {
        func find(_ view: UIView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.lazy.compactMap(find).first
        }
        try await waitUntil {
            self.host.view.layoutIfNeeded()
            self.webView = find(self.host.view)
            return self.webView != nil
        }
        try await waitFor("typeof window.hoshiTranscript === 'object' && document.querySelector('#podcast-text-2') != null")
        return try XCTUnwrap(webView)
    }

    func waitFor(_ expression: String) async throws {
        let web = try XCTUnwrap(webView)
        for _ in 0..<250 {
            if let value = try? await web.evaluateJavaScript(expression), value as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "TranscriptWebViewTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for: \(expression)"])
    }

    func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<250 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw URLError(.timedOut)
    }

    func close() {
        webView?.stopLoading()
        window.isHidden = true; window.rootViewController = nil; host = nil
        previous?.makeKeyAndVisible()
        for (key, value) in savedDefaults { UserDefaults.standard.set(value, forKey: key) }
    }
}
