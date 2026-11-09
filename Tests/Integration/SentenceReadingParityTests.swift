import XCTest
import SwiftUI
import WebKit
import AVFoundation
@testable import Hoshi_Reader

nonisolated final class SentenceReadingParityTests: XCTestCase {
    private func fixture() -> SentenceReadingProgress {
        let texts = ["短い。", "とても長い文章を読みます。", "最後。"]
        let sentences = texts.enumerated().map { index, text in
            ReaderSentence(spine: 0, start: index, length: 1, text: text, paragraph: 0)
        }
        let book = SentenceBook(chapters: [
            SentenceChapter(chapterIndex: 0, title: nil, sentences: sentences),
            SentenceChapter(chapterIndex: 1, title: nil, sentences: [])
        ])
        return SentenceReadingProgress(book: book,
            metrics: [0: SentenceChapterMetric(start: 0, count: 170), 1: SentenceChapterMetric(start: 170, count: 10)],
            characterCount: 180)
    }

    func testSentenceTurnsUseCharacterWeightedOrdinaryBookmarks() throws {
        let progress = fixture()
        let second = try XCTUnwrap(progress.at(SentencePosition(chapter: 0, sentence: 1)))
        let third = try XCTUnwrap(progress.at(SentencePosition(chapter: 0, sentence: 2)))
        XCTAssertLessThan(second.progress, 0.2)
        XCTAssertGreaterThan(third.progress, 0.7)
        XCTAssertLessThanOrEqual(abs(second.characterCount - Int(second.progress * 170)), 1)
        XCTAssertEqual(progress.completionPoint, SentenceProgressPoint(chapterIndex: 1, progress: 1, characterCount: 180))
        XCTAssertFalse(progress.isLast(SentencePosition(chapter: 0, sentence: 1)))
        XCTAssertTrue(progress.isLast(SentencePosition(chapter: 0, sentence: 2)))
    }

    func testSharedBookmarkOverridesStaleSentenceCursorAndHandlesCompletion() throws {
        let progress = fixture()
        let cursor = SentencePosition(chapter: 0, sentence: 2)
        XCTAssertEqual(progress.initialPosition(saved: cursor,
            bookmark: SentenceBookmarkAnchor(chapterIndex: 0, progress: 0)), SentencePosition(chapter: 0, sentence: 0))
        let point = try XCTUnwrap(progress.at(cursor))
        XCTAssertEqual(progress.initialPosition(saved: cursor,
            bookmark: SentenceBookmarkAnchor(chapterIndex: 0, progress: point.progress)), cursor)
        XCTAssertEqual(progress.initialPosition(saved: nil,
            bookmark: SentenceBookmarkAnchor(chapterIndex: 1, progress: 1)), cursor)
        XCTAssertEqual(progress.initialPosition(saved: nil,
            bookmark: SentenceBookmarkAnchor(chapterIndex: 0, progress: .nan)), SentencePosition(chapter: 0, sentence: 0))
    }

    @MainActor func testRubyAndPartiallyAnnotatedCompoundsStayOnOneLine() {
        let view = CenteringTextView(frame: CGRect(x: 0, y: 0, width: 100, height: 250), textContainer: nil)
        view.textContainer.lineFragmentPadding = 0
        view.textContainerInset = .zero
        let text = "日本大丈夫です。"
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        view.attributedText = NSAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: 26), .paragraphStyle: style])
        view.configureRuby([RubyAnnotation(start: 2, length: 3, reading: "だいじょうぶ")],
            font: .systemFont(ofSize: 13), color: .label)
        view.layoutIfNeeded()
        let manager = view.layoutManager
        manager.ensureLayout(for: view.textContainer)
        let first = manager.glyphIndexForCharacter(at: 2)
        let last = manager.glyphIndexForCharacter(at: 4)
        XCTAssertEqual(manager.lineFragmentRect(forGlyphAt: first, effectiveRange: nil).minY,
            manager.lineFragmentRect(forGlyphAt: last, effectiveRange: nil).minY)
        XCTAssertFalse(view.layoutManager(manager, shouldBreakLineByWordBeforeCharacterAt: 3))
        XCTAssertEqual(view.attributedText.string, text)
        XCTAssertTrue(CenteringTextView.wrappingRanges(text: "大丈夫。", ruby: [RubyAnnotation(start: 0, length: 1, reading: "だい")])
            .contains(NSRange(location: 0, length: 3)))
    }

    @MainActor func testMalformedAudiobookCuesDoNotHideFollowingValidBlocks() {
        let source = """
        1
        nan:00:00,000 --> 00:00:01,000
        invalid

        2
        00:99:00,000 --> 01:00:00,000
        invalid

        3
        00:00:02,000 --> 00:00:03,000
        日本語
        """
        let cues = SasayakiParser.parseCues(from: Data(source.utf8))
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues.first?.text, "日本語")
    }

    @MainActor func testAudiobookChapterRestoreKeepsPlaybackRunning() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sasayaki-state-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let player = SasayakiPlayer(rootURL: root, bridge: WebViewBridge(), loadChapter: { _, _ in }, getCurrentIndex: { 0 }, onPlayback: {})
        player.player = AVPlayer()
        player.isPlaying = true
        player.currentTime = 42
        player.prepareTransition()
        XCTAssertTrue(player.isPlaying)
        XCTAssertFalse(player.shouldResume)
        XCTAssertTrue(player.chapterTransition)
        player.reloadPlayback()
        XCTAssertEqual(player.currentTime, 42)
        player.teardown()
    }

    @MainActor func testWebKitSentencePaginationPreservesTextAndRuby() async throws {
        // When this is the first test to run, the host app may still be connecting its scene.
        var connected: UIWindowScene?
        for _ in 0..<200 {
            connected = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            if connected != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let scene = try XCTUnwrap(connected)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        // Like the reader, the page owns its whole frame; a safe-area inset would shrink the viewport.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        controller.view.addSubview(webView)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        let readerURL = try XCTUnwrap(Bundle.main.url(forResource: "reader", withExtension: "js"))
        let reader = try String(contentsOf: readerURL, encoding: .utf8)
        // Sentences longer than a line, so that unbroken pages split some of them in either orientation.
        let paragraphs = (0..<30).map { _ in
            "<p>私は<ruby>日本語<rt>にほんご</rt></ruby>の本を毎日少しずつ読みます。次の文章もみんなで一緒に楽しく読みましょう。今日はとても良い天気ですね。</p>"
        }.joined()
        for vertical in [false, true] {
            let html = """
            <!doctype html><html lang="ja"><head><meta name="viewport" content="width=device-width,initial-scale=1"><style>
            html,body { margin:0; padding:0; width:320px; height:240px; overflow:hidden; writing-mode:\(vertical ? "vertical-rl" : "horizontal-tb"); }
            body { box-sizing:border-box; font:22px serif; line-height:1.5; column-width:\(vertical ? 240 : 320)px; column-gap:0; }
            p { margin:0; } \(ReaderTextStyle.wordLayoutCSS)
            </style></head><body>\(paragraphs)<script>\(reader)\n\(ReaderTextStyle.textLayoutScript)
            window.hoshiReader.pageWidth=320;window.hoshiReader.pageHeight=240;</script></body></html>
            """
            webView.loadHTMLString(html, baseURL: nil)
            for _ in 0..<300 {
                if !webView.isLoading, (try? await webView.evaluateJavaScript("!!window.hoshiTextLayout")) as? Bool == true { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let result = try await webView.callAsyncJavaScript("""
                await document.fonts.ready;
                window.hoshiTextLayout.prepare(window.hoshiReader,true);
                const vertical = window.hoshiReader.isVertical();
                const size = vertical ? 240 : 320;
                const dividedSentences = () => window.hoshiTextLayout.sentences.filter(sentence => {
                  const range = document.createRange();
                  range.setStartAfter(sentence.start); range.setEndBefore(sentence.end);
                  const pages = new Set(Array.from(range.getClientRects()).filter(r => r.width > 0 && r.height > 0)
                    .map(r => Math.floor(((vertical ? r.top : r.left) + 0.1) / size)));
                  return pages.size > 1;
                }).length;
                const divided = dividedSentences();
                // The same chapter without its breaks shows that they were needed.
                const marked = ['hoshi-sentence-page-break', 'hoshi-sentence-block-break', 'hoshi-sentence-break-host']
                  .flatMap(name => Array.from(document.getElementsByClassName(name)).map(element => [element, name]));
                const breaks = marked.filter(([, name]) => name !== 'hoshi-sentence-break-host').length;
                marked.forEach(([element, name]) => element.classList.remove(name));
                const dividedWithoutBreaks = dividedSentences();
                marked.forEach(([element, name]) => element.classList.add(name));
                return {preserved:window.hoshiTextLayout.textPreserved,divided,dividedWithoutBreaks,breaks,
                  ruby:document.querySelectorAll('ruby').length};
                """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
            let values = try XCTUnwrap(result)
            XCTAssertEqual(values["preserved"] as? Bool, true)
            XCTAssertEqual(values["divided"] as? Int, 0, "\(vertical ? "Vertical" : "Horizontal") sentences should fit on one page")
            XCTAssertGreaterThan(values["dividedWithoutBreaks"] as? Int ?? 0, 0, "The fixture must need sentence breaks")
            XCTAssertGreaterThan(values["breaks"] as? Int ?? 0, 0)
            XCTAssertEqual(values["ruby"] as? Int, 30)
        }
    }

    /// Publishers often print one paragraph per line with its text indented, so every text node
    /// opens with white space that the layout collapses. Such a character has no box; in vertical
    /// text a range over it read as the origin, and every saved place reopened on the first page.
    @MainActor func testVerticalRestoreFindsItsPageWhenParagraphsOpenWithALineBreak() async throws {
        var connected: UIWindowScene?
        for _ in 0..<200 {
            connected = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            if connected != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let scene = try XCTUnwrap(connected)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        let configuration = WKWebViewConfiguration()
        // The reader reports a finished restore to its host.
        configuration.userContentController.add(IgnoredMessages(), name: "restoreCompleted")
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), configuration: configuration)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        controller.view.addSubview(webView)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        let readerURL = try XCTUnwrap(Bundle.main.url(forResource: "reader", withExtension: "js"))
        let reader = try String(contentsOf: readerURL, encoding: .utf8)
        // Lines that open with kana: a word box would otherwise take the kanji and leave the
        // white space before it in a text node of its own, which holds no counted character.
        let paragraphs = String(repeating: "<p>\n  これは<ruby>日本語<rt>にほんご</rt></ruby>の本です。\n  まいにち少しずつ読みます。\n  「つぎの文章もみんなで読みましょう」と彼は言った。\n</p>\n", count: 40)
        let html = """
        <!doctype html><html lang="ja"><head><meta name="viewport" content="width=device-width,initial-scale=1"><style>
        html,body { margin:0; padding:0; width:320px; height:240px; overflow:hidden; writing-mode:vertical-rl; }
        body { box-sizing:border-box; font:22px serif; line-height:1.5; column-width:240px; column-gap:0; }
        p { margin:0; } \(ReaderTextStyle.wordLayoutCSS) \(ReaderTextStyle.lineBoxCSS)
        </style><script>\(reader)\n\(ReaderTextStyle.textLayoutScript)
        window.hoshiReader.pageWidth=320;window.hoshiReader.pageHeight=240;</script></head><body>
        \(paragraphs)</body></html>
        """
        // The scripts stay out of the body: the reader counts every text node there as the
        // chapter's text, and in the app they are never part of the document.
        webView.loadHTMLString(html, baseURL: nil)
        for _ in 0..<300 {
            if !webView.isLoading, (try? await webView.evaluateJavaScript("!!window.hoshiTextLayout")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let result = try await webView.callAsyncJavaScript("""
            await document.fonts.ready;
            window.hoshiTextLayout.prepare(window.hoshiReader, true);
            const frames = () => new Promise(done => requestAnimationFrame(() => requestAnimationFrame(done)));
            const places = [];
            for (const progress of [0.25, 0.5, 0.75]) {
              await window.hoshiReader.restoreProgress(progress);
              await frames();
              places.push(document.body.scrollTop / 240);
            }
            return {places, pages: Math.round(document.body.scrollHeight / 240)};
            """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        let values = try XCTUnwrap(result)
        let pages = try XCTUnwrap(values["pages"] as? Int), places = try XCTUnwrap(values["places"] as? [Double])
        XCTAssertGreaterThan(pages, 8)
        XCTAssertEqual(places.count, 3)
        for (place, progress) in zip(places, [0.25, 0.5, 0.75]) {
            XCTAssertEqual(place, place.rounded(), "a restored place is a whole page")
            XCTAssertEqual(place, progress * Double(pages), accuracy: 1.5, "\(Int(progress * 100))% of \(pages) pages")
        }
        XCTAssertLessThan(places[0], places[1]); XCTAssertLessThan(places[1], places[2])
    }

    /// The reader shows a spinner until a chapter's breaks are placed. With the reader's own line
    /// rules, a long vertical chapter must be ready in well under the many seconds it once took,
    /// and a whole book in one file is left alone.
    @MainActor func testLongChaptersPaginateQuicklyAndASingleFileBookIsLeftAlone() async throws {
        var connected: UIWindowScene?
        for _ in 0..<200 {
            connected = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            if connected != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let scene = try XCTUnwrap(connected)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        // An iPad mini page in portrait.
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 744, height: 1000))
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        controller.view.addSubview(webView)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        let readerURL = try XCTUnwrap(Bundle.main.url(forResource: "reader", withExtension: "js"))
        let reader = try String(contentsOf: readerURL, encoding: .utf8)
        let pieces = [
            "<ruby>吾輩<rt>わがはい</rt></ruby>は<ruby>猫<rt>ねこ</rt></ruby>である。名前はまだ無い。",
            "どこで生れたかとんと見当がつかぬ。何でも薄暗いじめじめした所でニャーニャー泣いていた事だけは記憶している。",
            "「そうですか」と彼は静かに言った。「それなら、明日の朝いちばんに出発しましょう」",
            "彼女は<em>決して</em>振り返らなかった。窓の外では雨が降り続いている……。",
            "<ruby>東京<rt>とうきょう</rt></ruby>の<ruby>夜景<rt>やけい</rt></ruby>は美しい！本当に？それとも錯覚だろうか。",
            "国際連合安全保障理事会常任理事国の代表者会議が開催された。参加者は百人以上だった。",
            "12月25日、私達は図書館で勉強していた。",
        ]
        func chapter(paragraphs: Int) -> String {
            (0..<paragraphs).map { index in
                "<p>　" + (0..<(2 + index * 7 % 5)).map { pieces[(index * 3 + $0) % pieces.count] }.joined() + "</p>"
            }.joined(separator: "\n")
        }
        func prepare(_ body: String) async throws -> [String: Any] {
            let html = """
            <!doctype html><html lang="ja"><head><meta name="viewport" content="width=device-width,initial-scale=1"><style>
            \(ReaderTextStyle.wordLayoutCSS)
            \(ReaderTextStyle.lineBoxCSS)
            html,body { margin:0 !important; padding:0 !important; width:744px !important; height:1000px !important; overflow:hidden !important; writing-mode:vertical-rl !important; }
            body { \(ReaderTextStyle.typographyDeclarations(font: "Hiragino Mincho ProN", size: 22))
              box-sizing:border-box !important; column-width:744px !important; column-gap:72px; padding:25px 18px 47px !important;
              text-align:start !important; hanging-punctuation:allow-end !important; line-break:strict !important; }
            p { margin:0; }
            </style></head><body>\(body)<script>\(reader)\n\(ReaderTextStyle.textLayoutScript)
            window.hoshiReader.pageWidth=744;window.hoshiReader.pageHeight=1000;</script></body></html>
            """
            webView.loadHTMLString(html, baseURL: nil)
            for _ in 0..<600 {
                if !webView.isLoading, (try? await webView.evaluateJavaScript("!!window.hoshiTextLayout")) as? Bool == true { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let result = try await webView.callAsyncJavaScript("""
                await document.fonts.ready;
                const started = performance.now();
                window.hoshiTextLayout.prepare(window.hoshiReader, true);
                const context = window.hoshiReader.getScrollContext();
                return {milliseconds: performance.now() - started, paginated: window.hoshiTextLayout.paginated,
                  unfinished: !!window.hoshiTextLayout.unfinished, preserved: window.hoshiTextLayout.textPreserved,
                  words: document.querySelectorAll('.hoshi-word').length,
                  breaks: document.querySelectorAll('.hoshi-sentence-page-break,.hoshi-sentence-block-break').length,
                  pages: Math.round(document.body.scrollHeight / context.pageSize), characters: document.body.textContent.length};
                """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
            return try XCTUnwrap(result)
        }

        // About sixty pages. With `-webkit-line-box-contain: block glyphs replaced` this took thirteen seconds.
        let long = try await prepare(chapter(paragraphs: 300))
        print("300-paragraph vertical chapter: \(Int(long["milliseconds"] as? Double ?? -1)) ms, \(long["pages"] ?? "?") pages, \(long["breaks"] ?? "?") breaks, \(long["words"] ?? "?") word boxes")
        XCTAssertEqual(long["preserved"] as? Bool, true)
        XCTAssertEqual(long["paginated"] as? Bool, true)
        XCTAssertEqual(long["unfinished"] as? Bool, false, "an ordinary long chapter must get all of its sentence breaks")
        XCTAssertGreaterThan(long["pages"] as? Int ?? 0, 40)
        XCTAssertGreaterThan(long["breaks"] as? Int ?? 0, 20)
        XCTAssertLessThan(long["milliseconds"] as? Double ?? .infinity, 3_000)

        // A whole book in one file keeps the publisher's layout: no word boxes, no breaks, no wait.
        let book = try await prepare(chapter(paragraphs: 1_500))
        print("single-file book: \(Int(book["milliseconds"] as? Double ?? -1)) ms for \(book["characters"] ?? "?") characters")
        XCTAssertGreaterThan(book["characters"] as? Int ?? 0, 150_000)
        XCTAssertEqual(book["paginated"] as? Bool, false)
        XCTAssertEqual(book["words"] as? Int, 0)
        XCTAssertEqual(book["breaks"] as? Int, 0)
        XCTAssertEqual(book["preserved"] as? Bool, true)
        XCTAssertLessThan(book["milliseconds"] as? Double ?? .infinity, 1_000)
    }
}

/// Receives the messages a reader page posts to a host that these layout tests do not have.
private final class IgnoredMessages: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {}
}
