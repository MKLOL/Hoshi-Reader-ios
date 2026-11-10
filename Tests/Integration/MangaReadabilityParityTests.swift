import XCTest
import WebKit
@testable import Hoshi_Reader

nonisolated final class MangaReadabilityParityTests: XCTestCase {
    private var page: MokuroPage {
        MokuroPage(index: 0, imagePath: "fixture.png", imageWidth: 320, imageHeight: 640,
                   textBoxes: [MokuroTextBox(left: 60, top: 120, width: 160, height: 60,
                                           fontSize: 19, vertical: false, lines: ["こんにちは。"], originalFontSize: 8)])
    }
    private func config(enlarge: Bool = true, copy: Bool = false, furigana: Bool = true,
                        amount: Int = 50, threshold: Int = 30,
                        viewport: CGSize = CGSize(width: 320, height: 640)) -> MangaPageRenderConfig {
        MangaPageRenderConfig(backgroundCssColor: "#000", scanNonJapaneseText: false,
            viewportCssWidth: Int(viewport.width), viewportCssHeight: Int(viewport.height), singleTapLookup: false,
            useNotoSansJpFont: false, showActionButtons: true, selectionScript: "",
            showCopyButton: copy, enlargeSmallText: enlarge, textEnlargementAmount: amount,
            smallTextThreshold: threshold, showFurigana: furigana)
    }

    @MainActor func testSmallTextPreferenceDefaultsOnAndPersistsIndependentlyOfCardSettings() {
        let defaults = UserDefaults.standard, key = "mangaEnlargeSmallText"
        let saved = defaults.object(forKey: key)
        let savedCompound = defaults.object(forKey: "mangaTextEnlargement.ios")
        defer {
            ReaderPreferencesStore.shared.reset()
            if let saved { defaults.set(saved, forKey: key) } else { defaults.removeObject(forKey: key) }
            if let savedCompound { defaults.set(savedCompound, forKey: "mangaTextEnlargement.ios") } else { defaults.removeObject(forKey: "mangaTextEnlargement.ios") }
        }
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: "mangaTextEnlargement.ios")
        ReaderPreferencesStore.shared.reset()
        let preferences = UserConfig()
        XCTAssertTrue(preferences.mangaEnlargeSmallText)
        let dictionary = preferences.dictionaryCard, translation = preferences.translationCard
        preferences.mangaEnlargeSmallText = false
        XCTAssertFalse(UserConfig().mangaEnlargeSmallText)
        XCTAssertEqual(preferences.dictionaryCard, dictionary)
        XCTAssertEqual(preferences.translationCard, translation)
    }

    @MainActor func testCachedPageUsesAndroidImageRelativeSizeAndOriginalSizeWhenEnlargementIsDisabled() async throws {
        let cache = MangaPageRenderCache()
        let browser = try MangaTestBrowser(viewport: CGSize(width: 320, height: 640))
        defer { browser.close() }
        let measurement = """
        (() => {
          const box = document.querySelector('.ocr-box');
          const before = parseFloat(getComputedStyle(box).fontSize);
          box.classList.add('revealed');
          return [before, parseFloat(getComputedStyle(box).fontSize)];
        })()
        """
        try await load(await cache.htmlFor(page: page, config: config()), in: browser)
        let bigValue = try await browser.web.evaluateJavaScript(measurement)
        let big = try XCTUnwrap(bigValue as? [Double])
        try await load(await cache.htmlFor(page: page, config: config(enlarge: false)), in: browser)
        let exactValue = try await browser.web.evaluateJavaScript(measurement)
        let exact = try XCTUnwrap(exactValue as? [Double])
        XCTAssertEqual(big[1], big[0], accuracy: 0.01)
        XCTAssertGreaterThan(big[1], exact[1])
        XCTAssertEqual(big[0], 19, accuracy: 0.1)
        XCTAssertEqual(exact[1], exact[0], accuracy: 0.01)
        XCTAssertEqual(exact[0], 8, accuracy: 0.1)
        // Returning to the original preference can reuse its cached page without changing behavior.
        try await load(await cache.htmlFor(page: page, config: config()), in: browser)
        let repeatedValue = try await browser.web.evaluateJavaScript(measurement)
        let repeated = try XCTUnwrap(repeatedValue as? [Double])
        XCTAssertEqual(repeated[1], big[1], accuracy: 0.1)
    }

    func testMokuroSourceGlyphSizesAndBoostMatchAndroidWithoutGeometryDependentScaling() throws {
        let sourceSizes = [8, 18, 30, 45, 0]
        let blocks: [[String: Any]] = sourceSizes.enumerated().map { index, size in
            ["box": [10, 20, 200 + index * 70, 500], "font_size": size,
             "vertical": index % 2 == 0, "lines": [String(repeating: "学校", count: index + 1)],
             "lines_coords": [[[0, 0], [100, 0], [100, 100], [0, 100]]]]
        }
        let data = try JSONSerialization.data(withJSONObject: ["pages": [[
            "img_path": "fixture.png", "img_width": 1400, "img_height": 2100, "blocks": blocks
        ]]])
        let book = try XCTUnwrap(JSONDecoder().decode(RawMokuro.self, from: data).toMokuroBook(fallbackTitle: "Fixture"))
        let boxes = try XCTUnwrap(book.pages.first).textBoxes
        XCTAssertEqual(boxes.map(\.fontSize), [19, 24, 30, 45, 15])
        XCTAssertEqual(boxes.map(\.originalFontSize), [8, 18, 30, 45, 1])
        XCTAssertEqual(boxes.map { $0.revealFontSize(enlargeSmallText: false) }, [8, 18, 30, 45, 1])
        XCTAssertEqual(boxes.map { $0.revealFontSize(enlargeSmallText: true) }, [19, 24, 30, 45, 15])
        let encoded = try JSONEncoder().encode(boxes[0])
        var older = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        older.removeValue(forKey: "originalFontSize")
        let oldBox = try JSONDecoder().decode(MokuroTextBox.self, from: JSONSerialization.data(withJSONObject: older))
        XCTAssertEqual(oldBox.originalFontSize, oldBox.fontSize)
    }

    func testEveryEnlargementSettingPreservesSourceSizeOrder() {
        for threshold in 10...60 {
            for amount in 0...100 {
                let settings = MangaTextEnlargement(amount: amount, threshold: threshold)
                var previous = settings.fontSize(original: 1)
                for original in 2...120 {
                    let result = settings.fontSize(original: original)
                    if result < previous || result < original || (original >= threshold && result != original) {
                        XCTFail("Size order changed at source \(original), amount \(amount), cutoff \(threshold)")
                        return
                    }
                    previous = result
                }
            }
        }
    }

    @MainActor func testPagePreviewRevealsEveryBubbleWithoutLookupAndKeepsOriginalComparison() async throws {
        let cache = MangaPageRenderCache()
        let browser = try MangaTestBrowser(viewport: CGSize(width: 320, height: 640))
        defer { browser.close() }
        var preview = config(amount: 75, threshold: 40)
        preview.textSizePreview = true
        try await load(await cache.htmlFor(page: page, config: preview), in: browser)
        let result = try await browser.web.evaluateJavaScript("""
            (() => { const boxes = [...document.querySelectorAll('.ocr-box')];
              return [boxes.every(b => b.classList.contains('revealed')), parseFloat(getComputedStyle(boxes[0]).fontSize)]; })()
            """)
        let values = try XCTUnwrap(result as? [NSNumber])
        XCTAssertTrue(values[0].boolValue)
        XCTAssertEqual(values[1].doubleValue, 32, accuracy: 0.1)
        preview.enlargeSmallText = false
        try await load(await cache.htmlFor(page: page, config: preview), in: browser)
        let original = try await browser.web.evaluateJavaScript("parseFloat(getComputedStyle(document.querySelector('.ocr-box')).fontSize)")
        XCTAssertEqual(try XCTUnwrap(original as? Double), 8, accuracy: 0.1)
    }

    @MainActor func testPreviewAndReaderUseIdenticalPageAndGlyphGeometryIncludingSpreads() async throws {
        let cache = MangaPageRenderCache()
        let measurement = """
            (() => {
              const rect = e => { const r = e.getBoundingClientRect(); return [r.x,r.y,r.width,r.height]; };
              return [innerWidth,innerHeight,
                ...[...document.querySelectorAll('.frame')].flatMap(rect),
                ...[...document.querySelectorAll('.ocr-box')].flatMap(e => [parseFloat(getComputedStyle(e).fontSize),...rect(e)])];
            })()
            """
        for viewport in [CGSize(width: 744, height: 1133), CGSize(width: 1133, height: 744)] {
            let browser = try MangaTestBrowser(viewport: viewport)
            defer { browser.close() }
            let left: MokuroPage? = viewport.width > viewport.height ? page : nil
            let readerConfig = config(amount: 75, threshold: 40, viewport: viewport)
            try await load(await cache.htmlFor(page: page, leftPage: left, config: readerConfig), in: browser)
            _ = try await browser.web.evaluateJavaScript("""
                document.querySelectorAll('.ocr-box').forEach(box => {
                  box.classList.add('revealed'); window.hoshiManga.tryWrapFallback(box); window.hoshiManga.fitFurigana(box);
                });
                """)
            let normalValue = try await browser.web.evaluateJavaScript(measurement)
            let normal = try XCTUnwrap(normalValue as? [Double])
            var preview = readerConfig
            preview.textSizePreview = true
            try await load(await cache.htmlFor(page: page, leftPage: left, config: preview), in: browser)
            let actualValue = try await browser.web.evaluateJavaScript(measurement)
            let actual = try XCTUnwrap(actualValue as? [Double])
            XCTAssertEqual(actual, normal, "Preview must use the reader's exact image and OCR geometry")
        }
    }

    func testAdjustableEnlargementUsesTheSameCurveAsThePreview() {
        XCTAssertEqual([12, 20, 30, 40].map { MangaTextEnlargement().fontSize(original: $0) }, [21, 25, 30, 40])
        XCTAssertEqual([12, 20, 30, 40].map { MangaTextEnlargement(amount: 75, threshold: 40).fontSize(original: $0) }, [33, 35, 37, 40])
        XCTAssertEqual(MangaTextEnlargement(enabled: false, amount: 100, threshold: 60).fontSize(original: 8), 8)
        XCTAssertEqual(MangaTextEnlargement(amount: 0, threshold: 60).fontSize(original: 8), 8)
        XCTAssertEqual(MangaTextEnlargement(amount: 100, threshold: 40).fontSize(original: 8), 40)
        XCTAssertEqual(MangaTextEnlargement(amount: 100, threshold: 40).fontSize(original: 45), 45)
        XCTAssertEqual(MangaTextEnlargement(amount: 58, threshold: 51).fontSize(original: 1), 30)
    }

    @MainActor func testRenderCacheUsesAmountAndThresholdWithoutReimportingManga() async throws {
        let cache = MangaPageRenderCache()
        let browser = try MangaTestBrowser(viewport: CGSize(width: 320, height: 640))
        defer { browser.close() }
        for (amount, threshold, expected) in [(50, 30, 19), (100, 40, 40), (0, 40, 8), (50, 30, 19)] {
            try await load(await cache.htmlFor(page: page, config: config(amount: amount, threshold: threshold)), in: browser)
            let value = try await browser.web.evaluateJavaScript("""
                (() => { const box = document.querySelector('.ocr-box');
                  box.classList.add('revealed'); window.hoshiManga.tryWrapFallback(box);
                  return parseFloat(getComputedStyle(box).fontSize); })()
                """)
            XCTAssertEqual(try XCTUnwrap(value as? Double), Double(expected), accuracy: 0.1)
        }
    }

    func testUnusedLineCoordinatesDoNotAffectParsedBook() throws {
        let block: [String: Any] = [
            "box": [10, 20, 110, 420], "font_size": 18.125,
            "vertical": true, "lines": ["学校で本を読む。"]
        ]
        func parse(coordinates: Any?) throws -> MokuroBook {
            var source = block
            source["lines_coords"] = coordinates
            let data = try JSONSerialization.data(withJSONObject: ["pages": [[
                "img_path": "fixture.png", "img_width": 1400,
                "img_height": 2100, "blocks": [source]
            ]]])
            return try XCTUnwrap(JSONDecoder().decode(RawMokuro.self, from: data)
                .toMokuroBook(fallbackTitle: "Fixture"))
        }
        let expected = try parse(coordinates: nil)
        XCTAssertEqual(try parse(coordinates: NSNull()), expected)
        XCTAssertEqual(try parse(coordinates: "malformed coordinates"), expected)
        let quadrilateral = [[10.125, 20.75], [110.125, 20.75], [110.125, 420.75], [10.125, 420.75]]
        XCTAssertEqual(try parse(coordinates: Array(repeating: quadrilateral, count: 4_096)), expected)
        XCTAssertEqual(expected.pages[0].textBoxes[0].fontSize, 24)
        XCTAssertEqual(expected.pages[0].textBoxes[0].originalFontSize, 18)
    }

    @MainActor func testIPadOCRLookupKeepsImageRelativeFontAndTranslationButtonStableWithRuby() async throws {
        let text = "学校で本を読む。"
        let page = MokuroPage(index: 0, imagePath: "fixture.png", imageWidth: 1400, imageHeight: 2100,
            textBoxes: [MokuroTextBox(left: 450, top: 700, width: 110, height: 500,
                fontSize: 19, vertical: true, lines: [text], blockIndex: 3, originalFontSize: 8)])
        let cache = MangaPageRenderCache()
        for viewport in [CGSize(width: 744, height: 1133), CGSize(width: 1133, height: 744)] {
            let browser = try MangaTestBrowser(viewport: viewport)
            defer { browser.close() }
            for enlarge in [true, false] {
                for copy in [true, false] {
                    try await load(await cache.htmlFor(page: page,
                        config: config(enlarge: enlarge, copy: copy, viewport: viewport)), in: browser)
                    let value = try await browser.web.evaluateJavaScript("""
                    (() => {
                      const box = document.querySelector('.ocr-box'), manga = window.hoshiManga;
                      let lookups = 0;
                      window.hoshiSelection = {clearSelection() {}, selectText() {lookups++; return '学校';}};
                      const fontBefore = parseFloat(getComputedStyle(box).fontSize);
                      function tapBox() { const r = box.getBoundingClientRect(); return manga.handleTap(r.left+r.width/2, r.top+r.height/2, 16); }
                      function snapshot() {
                        const actions = document.querySelector('.ocr-actions');
                        const r = actions.querySelector('.ocr-ai-btn').getBoundingClientRect();
                        return {x:r.x,y:r.y,width:r.width,height:r.height,placement:actions.dataset.placement,
                          font:parseFloat(getComputedStyle(box).fontSize), visible:actions.classList.contains('is-visible')};
                      }
                      const firstResult = tapBox(), first = snapshot();
                      const lookupResult = tapBox(), second = snapshot();
                      const thirdResult = tapBox(), third = snapshot();
                      const actions = document.querySelector('.ocr-actions');
                      return {fontBefore,firstResult,lookupResult,thirdResult,first,second,third,lookups,
                        hasRuby:box.querySelectorAll('rt').length > 0,source:manga.bubbleText(box),
                        actionText:actions.dataset.bubbleText,block:actions.dataset.blockId};
                    })()
                    """)
                    let fields = try XCTUnwrap(value as? [String: Any])
                    XCTAssertEqual(fields["firstResult"] as? String, "__revealed__")
                    XCTAssertEqual(fields["lookupResult"] as? String, "学校")
                    XCTAssertEqual(fields["thirdResult"] as? String, "学校")
                    XCTAssertEqual(fields["lookups"] as? Int, 2)
                    XCTAssertEqual(fields["hasRuby"] as? Bool, true)
                    XCTAssertEqual(fields["source"] as? String, text)
                    XCTAssertEqual(fields["actionText"] as? String, text)
                    XCTAssertEqual(fields["block"] as? String, "p0b3")
                    let expectedFont = Double(enlarge ? 19 : 8) * min(Double(viewport.width) / 1400, Double(viewport.height) / 2100)
                    XCTAssertEqual(try XCTUnwrap(fields["fontBefore"] as? Double), expectedFont, accuracy: 0.03)
                    let first = try XCTUnwrap(fields["first"] as? [String: Any])
                    XCTAssertEqual(first["visible"] as? Bool, true)
                    XCTAssertEqual(try XCTUnwrap(first["font"] as? Double), expectedFont, accuracy: 0.03)
                    XCTAssertGreaterThan(try XCTUnwrap(first["width"] as? Double), 25)
                    for key in ["second", "third"] {
                        let repeated = try XCTUnwrap(fields[key] as? [String: Any])
                        XCTAssertEqual(repeated["visible"] as? Bool, true)
                        XCTAssertEqual(repeated["placement"] as? String, first["placement"] as? String)
                        for metric in ["x", "y", "width", "height", "font"] {
                            XCTAssertEqual(try XCTUnwrap(repeated[metric] as? Double), try XCTUnwrap(first[metric] as? Double), accuracy: 0.01)
                        }
                    }
                }
            }
        }
    }

    @MainActor func testHorizontalRubyWrapRestoresOriginalFontAndReopensWithStableActions() async throws {
        let viewport = CGSize(width: 744, height: 1133)
        let text = String(repeating: "学校で本を読みます。", count: 2)
        let page = MokuroPage(index: 0, imagePath: "fixture.png", imageWidth: 744, imageHeight: 1133,
            textBoxes: [MokuroTextBox(left: 300, top: 100, width: 80, height: 800,
                fontSize: 19, vertical: false, lines: [text], blockIndex: 5, originalFontSize: 8)])
        let browser = try MangaTestBrowser(viewport: viewport)
        defer { browser.close() }
        let cache = MangaPageRenderCache()
        try await load(await cache.htmlFor(page: page, config: config(viewport: viewport)), in: browser)
        let value = try await browser.web.evaluateJavaScript("""
        (() => {
          const box = document.querySelector('.ocr-box'), manga = window.hoshiManga;
          let lookups = 0;
          window.hoshiSelection = {clearSelection() {}, selectText() {lookups++; return '学校';}};
          const originalStyle = box.style.cssText, originalFont = box.style.fontSize;
          const fontBefore = parseFloat(getComputedStyle(box).fontSize);
          function tapBox() {
            const r = box.getBoundingClientRect();
            return manga.handleTap(r.left+r.width/2, r.top+r.height/2, 16);
          }
          function snapshot() {
            const actions = document.querySelector('.ocr-actions');
            const r = actions.querySelector('.ocr-ai-btn').getBoundingClientRect();
            return {x:r.x,y:r.y,width:r.width,height:r.height,placement:actions.dataset.placement,
              visible:actions.classList.contains('is-visible'),font:parseFloat(getComputedStyle(box).fontSize),
              wrap:box.classList.contains('wrap'),source:manga.bubbleText(box),
              actionText:actions.dataset.bubbleText,block:actions.dataset.blockId};
          }
          const revealResult = tapBox(), first = snapshot();
          const lookupResult = tapBox(), second = snapshot();
          manga.clearRevealed();
          const reset = {style:box.style.cssText,font:box.style.fontSize,
            computedFont:parseFloat(getComputedStyle(box).fontSize),wrap:box.classList.contains('wrap'),
            visible:document.querySelector('.ocr-actions').classList.contains('is-visible'),
            hasOriginalFont:'wrapOriginalFontSize' in box.dataset};
          const reopenResult = tapBox(), reopened = snapshot();
          const reopenedLookupResult = tapBox(), reopenedLookup = snapshot();
          return {fontBefore,originalFont,originalStyle,revealResult,lookupResult,reopenResult,
            reopenedLookupResult,lookups,hasRuby:box.querySelectorAll('rt').length > 0,
            first,second,reset,reopened,reopenedLookup};
        })()
        """)
        let fields = try XCTUnwrap(value as? [String: Any])
        XCTAssertEqual(fields["hasRuby"] as? Bool, true)
        XCTAssertEqual(fields["revealResult"] as? String, "__revealed__")
        XCTAssertEqual(fields["reopenResult"] as? String, "__revealed__")
        XCTAssertEqual(fields["lookupResult"] as? String, "学校")
        XCTAssertEqual(fields["reopenedLookupResult"] as? String, "学校")
        XCTAssertEqual(fields["lookups"] as? Int, 2)
        let first = try XCTUnwrap(fields["first"] as? [String: Any])
        let originalFont = try XCTUnwrap(fields["originalFont"] as? String)
        XCTAssertTrue(originalFont.hasSuffix("cqw"))
        XCTAssertEqual(first["wrap"] as? Bool, true)
        XCTAssertEqual(try XCTUnwrap(first["font"] as? Double),
            try XCTUnwrap(fields["fontBefore"] as? Double), accuracy: 0.01)
        let reset = try XCTUnwrap(fields["reset"] as? [String: Any])
        XCTAssertEqual(reset["font"] as? String, originalFont)
        XCTAssertEqual(reset["style"] as? String, fields["originalStyle"] as? String)
        XCTAssertEqual(try XCTUnwrap(reset["computedFont"] as? Double),
            try XCTUnwrap(fields["fontBefore"] as? Double), accuracy: 0.01)
        XCTAssertEqual(reset["wrap"] as? Bool, false)
        XCTAssertEqual(reset["visible"] as? Bool, false)
        XCTAssertEqual(reset["hasOriginalFont"] as? Bool, false)
        for key in ["first", "second", "reopened", "reopenedLookup"] {
            let snapshot = try XCTUnwrap(fields[key] as? [String: Any])
            XCTAssertEqual(snapshot["visible"] as? Bool, true)
            XCTAssertEqual(snapshot["wrap"] as? Bool, true)
            XCTAssertEqual(snapshot["source"] as? String, text)
            XCTAssertEqual(snapshot["actionText"] as? String, text)
            XCTAssertEqual(snapshot["block"] as? String, "p0b5")
            XCTAssertEqual(snapshot["placement"] as? String, first["placement"] as? String)
            for metric in ["x", "y", "width", "height", "font"] {
                XCTAssertEqual(try XCTUnwrap(snapshot[metric] as? Double),
                    try XCTUnwrap(first[metric] as? Double), accuracy: 0.01)
            }
        }
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
            ReaderPreferencesStore.shared.reset()
            for (key, value) in zip(keys, previous) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        keys.forEach { defaults.removeObject(forKey: $0) }
        ReaderPreferencesStore.shared.reset()
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

    func testImageLoaderRejectsAnObsoleteBooksNamespace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("page.png"))
        let previous = MangaImageLoader(), current = MangaImageLoader()
        await previous.configure(root: root, declaredPaths: ["page.png"])
        await current.configure(root: root, declaredPaths: ["page.png"])
        let obsoleteSource = await previous.source(relativePath: "page.png")
        let obsoleteURL = try XCTUnwrap(obsoleteSource.flatMap { URL(string: $0.url) })
        do {
            _ = try await current.image(for: obsoleteURL, allowedPaths: ["page.png"])
            XCTFail("an old document must not request bytes from the new book through an identical relative path")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .noPermissionsToReadFile)
        }
        let source = await current.source(relativePath: "page.png")
        let url = try XCTUnwrap(source.flatMap { URL(string: $0.url) })
        let bytes = try await current.image(for: url, allowedPaths: ["page.png"])
        XCTAssertEqual(bytes, Data([1, 2, 3]))
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
@MainActor private final class MangaTestBrowser: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
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
        config.userContentController.add(self, name: "hoshiManga")
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
        web.configuration.userContentController.removeScriptMessageHandler(forName: "hoshiManga")
        web.removeFromSuperview()
        window.isHidden = true
        window.rootViewController = nil
        previous?.makeKeyAndVisible()
    }
    private func finish() { finished?.fulfill(); finished = nil }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {}
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
