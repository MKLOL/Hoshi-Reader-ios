import XCTest
import WebKit
@testable import Hoshi_Reader

nonisolated final class MangaReadabilityParityTests: XCTestCase {
    private var page: MokuroPage {
        MokuroPage(index: 0, imagePath: "fixture.png", imageWidth: 320, imageHeight: 640,
                   textBoxes: [MokuroTextBox(left: 60, top: 120, width: 160, height: 60,
                                           fontSize: 8, vertical: false, lines: ["こんにちは。"])])
    }
    private func config(enlarge: Bool = true, copy: Bool = false, furigana: Bool = true) -> MangaPageRenderConfig {
        MangaPageRenderConfig(backgroundCssColor: "#000", scanNonJapaneseText: false,
            viewportCssWidth: 320, viewportCssHeight: 640, singleTapLookup: false,
            useNotoSansJpFont: false, showActionButtons: true, selectionScript: "",
            showCopyButton: copy, enlargeSmallText: enlarge, showFurigana: furigana)
    }

    @MainActor func testSmallTextPreferenceDefaultsOnAndPersistsIndependentlyOfCardSettings() {
        let defaults = UserDefaults.standard, key = "mangaEnlargeSmallText"
        let saved = defaults.object(forKey: key)
        defer { if let saved { defaults.set(saved, forKey: key) } else { defaults.removeObject(forKey: key) } }
        defaults.removeObject(forKey: key)
        let preferences = UserConfig()
        XCTAssertTrue(preferences.mangaEnlargeSmallText)
        let dictionary = preferences.dictionaryCard, translation = preferences.translationCard
        preferences.mangaEnlargeSmallText = false
        XCTAssertFalse(UserConfig().mangaEnlargeSmallText)
        XCTAssertEqual(preferences.dictionaryCard, dictionary)
        XCTAssertEqual(preferences.translationCard, translation)
    }

    @MainActor func testCachedPageRendersOriginalOCRSizeWhenEnlargementIsDisabled() async throws {
        let cache = MangaPageRenderCache()
        let browser = try MangaTestBrowser(viewport: CGSize(width: 320, height: 640))
        defer { browser.close() }
        let measurement = """
        (() => {
          const box = document.querySelector('.ocr-box');
          const before = parseFloat(getComputedStyle(box).fontSize);
          box.classList.add('revealed');
          window.hoshiManga.tryWrapFallback(box);
          return [before, parseFloat(getComputedStyle(box).fontSize)];
        })()
        """
        try await load(await cache.htmlFor(page: page, config: config()), in: browser)
        let bigValue = try await browser.web.evaluateJavaScript(measurement)
        let big = try XCTUnwrap(bigValue as? [Double])
        try await load(await cache.htmlFor(page: page, config: config(enlarge: false)), in: browser)
        let exactValue = try await browser.web.evaluateJavaScript(measurement)
        let exact = try XCTUnwrap(exactValue as? [Double])
        XCTAssertGreaterThan(big[1], big[0])
        XCTAssertEqual(exact[1], exact[0], accuracy: 0.01)
        XCTAssertEqual(exact[0], 8, accuracy: 0.1)
        // Returning to the original preference can reuse its cached page without changing behavior.
        try await load(await cache.htmlFor(page: page, config: config()), in: browser)
        let repeatedValue = try await browser.web.evaluateJavaScript(measurement)
        let repeated = try XCTUnwrap(repeatedValue as? [Double])
        XCTAssertEqual(repeated[1], big[1], accuracy: 0.1)
    }

    @MainActor func testSoloTranslateHasThirtyPercentMoreAreaAndKeepsClearOfRevealedText() async throws {
        let cache = MangaPageRenderCache()
        let browser = try MangaTestBrowser(viewport: CGSize(width: 320, height: 640))
        defer { browser.close() }
        let measurement = """
        (() => {
          const box = document.querySelector('.ocr-box');
          box.classList.add('revealed');
          window.hoshiManga.tryWrapFallback(box);
          window.hoshiManga.placeActions(box);
          const action = document.querySelector('.ocr-ai-btn').getBoundingClientRect();
          const copy = getComputedStyle(document.querySelector('.ocr-copy-btn')).display;
          const text = window.hoshiManga.renderedTextRects(box);
          const overlap = text.some(r => Math.min(r.right, action.right) > Math.max(r.left, action.left) &&
                                        Math.min(r.bottom, action.bottom) > Math.max(r.top, action.top));
          return { width: action.width, height: action.height, copyHidden: copy === 'none', overlap };
        })()
        """
        try await load(await cache.htmlFor(page: page, config: config(copy: true)), in: browser)
        let pairValue = try await browser.web.evaluateJavaScript(measurement)
        let pair = try XCTUnwrap(pairValue as? [String: Any])
        try await load(await cache.htmlFor(page: page, config: config()), in: browser)
        let oneValue = try await browser.web.evaluateJavaScript(measurement)
        let one = try XCTUnwrap(oneValue as? [String: Any])
        let pairedArea = try XCTUnwrap(pair["width"] as? Double) * XCTUnwrap(pair["height"] as? Double)
        let soloArea = try XCTUnwrap(one["width"] as? Double) * XCTUnwrap(one["height"] as? Double)
        XCTAssertEqual(soloArea / pairedArea, 1.14 * 1.14, accuracy: 0.015)
        XCTAssertEqual(pair["copyHidden"] as? Bool, false)
        XCTAssertEqual(one["copyHidden"] as? Bool, true)
        XCTAssertEqual(one["overlap"] as? Bool, false)
    }

    @MainActor func testMangaReadingPreferencesPersistWithSafeDefaults() {
        let defaults = UserDefaults.standard
        let keys = ["mangaShowFurigana", "disablePageTurnAnimation"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        keys.forEach { defaults.removeObject(forKey: $0) }
        let settings = UserConfig()
        XCTAssertTrue(settings.mangaShowFurigana)
        XCTAssertFalse(settings.disablePageTurnAnimation)
        settings.mangaShowFurigana = false
        settings.disablePageTurnAnimation = true
        XCTAssertFalse(UserConfig().mangaShowFurigana)
        XCTAssertTrue(UserConfig().disablePageTurnAnimation)
    }

    @MainActor func testGeneratedRubyPreservesCanonicalOCRAndCachedPreferenceChanges() async throws {
        let text = "😀学校に行きます。\n本を読む。"
        let page = MokuroPage(index: 0, imagePath: "fixture.png", imageWidth: 320, imageHeight: 640,
            textBoxes: [MokuroTextBox(left: 60, top: 120, width: 160, height: 100,
                fontSize: 16, vertical: false, lines: text.components(separatedBy: "\n"))])
        let cache = MangaPageRenderCache()
        let browser = try MangaTestBrowser(viewport: CGSize(width: 320, height: 640))
        defer { browser.close() }
        let probe = """
        (() => {
          const box = document.querySelector('.ocr-box'), manga = window.hoshiManga;
          manga.prepareReveal(box); box.classList.add('revealed'); manga.fitFurigana(box); manga.placeActions(box);
          const clone = box.querySelector('p').cloneNode(true);
          clone.querySelectorAll('rt, rp').forEach(node => node.remove());
          return { source:manga.bubbleText(box), base:clone.textContent,
            action:document.querySelector('.ocr-actions').dataset.bubbleText,
            readings:Array.from(box.querySelectorAll('rt')).map(rt => rt.textContent),
            bases:Array.from(box.querySelectorAll('ruby span')).map(base => base.textContent) };
        })()
        """
        for enabled in [true, false, true] {
            try await load(await cache.htmlFor(page: page, config: config(enlarge: false, copy: true, furigana: enabled)), in: browser)
            let result = try await browser.web.evaluateJavaScript(probe)
            let fields = try XCTUnwrap(result as? [String: Any])
            XCTAssertEqual(fields["source"] as? String, text)
            XCTAssertEqual(fields["base"] as? String, text)
            XCTAssertEqual(fields["action"] as? String, text)
            let readings = try XCTUnwrap(fields["readings"] as? [String])
            XCTAssertEqual(readings.contains("がっこう"), enabled)
            XCTAssertEqual((fields["bases"] as? [String])?.contains("学校"), enabled)
            if !enabled { XCTAssertTrue(readings.isEmpty) }
        }
    }

    @MainActor func testLongRubyBubbleScrollsWithoutShrinkingAndReopensAtBeginning() async throws {
        let page = MokuroPage(index: 0, imagePath: "fixture.png", imageWidth: 320, imageHeight: 640,
            textBoxes: [MokuroTextBox(left: 280, top: 600, width: 30, height: 30,
                fontSize: 24, vertical: true, lines: [String(repeating: "学校に行く。", count: 180)])])
        let cache = MangaPageRenderCache()
        let browser = try MangaTestBrowser(viewport: CGSize(width: 320, height: 640))
        defer { browser.close() }
        try await load(await cache.htmlFor(page: page, config: config(enlarge: false)), in: browser)
        let result = try await browser.web.evaluateJavaScript("""
        (() => {
          const box = document.querySelector('.ocr-box'), p = box.querySelector('p'), manga = window.hoshiManga;
          const originalRect = box.getBoundingClientRect(), font = parseFloat(getComputedStyle(box).fontSize);
          manga.prepareReveal(box); box.classList.add('revealed'); manga.fitFurigana(box);
          const scrolling = box.classList.contains('furigana-scroll');
          const rect = box.getBoundingClientRect(), fittedFont = parseFloat(getComputedStyle(box).fontSize);
          p.scrollLeft = -100; p.scrollTop = 100;
          manga.clearRevealed();
          const reset = box.getBoundingClientRect();
          const restored = ['left','top','width','height'].every(key => Math.abs(reset[key] - originalRect[key]) < 0.01);
          manga.prepareReveal(box); box.classList.add('revealed'); manga.fitFurigana(box);
          return {scrolling, restored, font, fittedFont, left:rect.left, top:rect.top,
            right:rect.right, bottom:rect.bottom, scrollLeft:p.scrollLeft, scrollTop:p.scrollTop};
        })()
        """)
        let fields = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(fields["scrolling"] as? Bool, true)
        XCTAssertEqual(fields["restored"] as? Bool, true)
        XCTAssertEqual(try XCTUnwrap(fields["font"] as? Double), try XCTUnwrap(fields["fittedFont"] as? Double), accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(fields["left"] as? Double), 0)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(fields["top"] as? Double), 0)
        XCTAssertLessThanOrEqual(try XCTUnwrap(fields["right"] as? Double), 320)
        XCTAssertLessThanOrEqual(try XCTUnwrap(fields["bottom"] as? Double), 640)
        XCTAssertEqual(fields["scrollLeft"] as? Double, 0)
        XCTAssertEqual(fields["scrollTop"] as? Double, 0)
    }

    func testHTMLCacheRevalidatesReplacedImageVersions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.png")
        try Data([1, 2, 3]).write(to: file)
        let loader = MangaImageLoader()
        await loader.configure(root: root, declaredPaths: ["fixture.png"])
        let cache = MangaPageRenderCache(imageLoader: loader)
        let first = await cache.htmlFor(page: page, config: config())
        try Data([4, 5]).write(to: file)
        let replaced = await cache.htmlFor(page: page, config: config())
        XCTAssertNotEqual(first, replaced)
        let repeated = await cache.htmlFor(page: page, config: config())
        XCTAssertEqual(replaced, repeated)
    }

    @MainActor private func load(_ html: String, in browser: MangaTestBrowser) async throws {
        let finished = expectation(description: "Manga document loaded")
        browser.finished = finished
        browser.failure = nil
        browser.loaded = false
        browser.web.loadHTMLString(html, baseURL: URL(string: MangaPageHtml.baseURLString))
        await fulfillment(of: [finished], timeout: 15)
        if let error = browser.failure { throw error }
        guard browser.loaded else { throw URLError(.timedOut) }
    }
}

/// WebKit suspends detached views. Host one live view and serve the same custom scheme as the
/// reader so neither document navigation nor the image fixture relies on an unhandled URL.
@MainActor private final class MangaTestBrowser: NSObject, WKNavigationDelegate {
    let web: WKWebView
    private let window: UIWindow
    private weak var previous: UIWindow?
    var finished: XCTestExpectation?
    var failure: Error?
    var loaded = false

    init(viewport: CGSize) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previous = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(MangaTestImageScheme(), forURLScheme: MangaImageScheme.scheme)
        web = WKWebView(frame: CGRect(origin: .zero, size: viewport), configuration: config)
        super.init()
        web.navigationDelegate = self
        let host = UIViewController()
        host.view.addSubview(web)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
    }

    func close() {
        web.stopLoading()
        web.navigationDelegate = nil
        web.removeFromSuperview()
        window.isHidden = true
        window.rootViewController = nil
        previous?.makeKeyAndVisible()
    }
    private func finish() { finished?.fulfill(); finished = nil }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true; finish() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failure = error; finish()
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failure = error; finish()
    }
}

@MainActor private final class MangaTestImageScheme: NSObject, WKURLSchemeHandler {
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.lastPathComponent == "fixture.png" else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: "image/png", expectedContentLength: png.count, textEncodingName: nil))
        urlSchemeTask.didReceive(png)
        urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
