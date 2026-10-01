import XCTest
@testable import Hoshi_Reader

nonisolated final class JapaneseFuriganaTests: XCTestCase {
    func testKanaLatinNumbersAndPunctuationNeedNoRuby() throws {
        XCTAssertEqual(try JapaneseFurigana.annotations(for: "ひらがな、カタカナとコーヒー。ABC 123 😀！？"), [])
        XCTAssertEqual(try JapaneseFurigana.annotations(for: ""), [])
    }

    func testJapaneseSentenceKeepsContextAndDictionaryTapOffsets() throws {
        let text = "今日は学校に行きます。"
        let annotations = try JapaneseFurigana.annotations(for: text)
        let readings = Dictionary(uniqueKeysWithValues: annotations.map {
            ((text as NSString).substring(with: NSRange(location: $0.start, length: $0.length)), $0.reading)
        })
        XCTAssertEqual(readings["今日"], "きょう")
        XCTAssertEqual(readings["学校"], "がっこう")
        XCTAssertEqual(readings["行き"], "いき")
        XCTAssertEqual(annotations.map(\.start), annotations.map(\.start).sorted())
    }

    func testKanjiOnlyTermsUseJapaneseReadingsWithoutKanaLanguageHints() throws {
        for (text, reading) in [("中国", "ちゅうごく"), ("東京", "とうきょう"), ("今日", "きょう"), ("本", "ほん")] {
            XCTAssertEqual(try JapaneseFurigana.annotations(for: text),
                [RubyAnnotation(start: 0, length: (text as NSString).length, reading: reading)])
        }
    }

    func testEmojiAndDecomposedKanaDoNotShiftOriginalUTF16Ranges() throws {
        let text = "😀か\u{3099}、本を読む。"
        let annotations = try JapaneseFurigana.annotations(for: text)
        let book = try XCTUnwrap(annotations.first { $0.reading == "ほん" })
        XCTAssertEqual(book.start, 5)
        XCTAssertEqual(book.length, 1)
        XCTAssertEqual((text as NSString).substring(with: NSRange(location: book.start, length: book.length)), "本")
        let read = try XCTUnwrap(annotations.first { $0.reading == "よむ" })
        XCTAssertEqual((text as NSString).substring(with: NSRange(location: read.start, length: read.length)), "読む")
    }

    func testLongVowelTranscriptionProducesKanaWithoutLatinOrCombiningMarks() throws {
        let text = "珈琲を飲む。"
        let annotations = try JapaneseFurigana.annotations(for: text)
        let coffee = try XCTUnwrap(annotations.first {
            (text as NSString).substring(with: NSRange(location: $0.start, length: $0.length)) == "珈琲"
        })
        XCTAssertEqual(coffee.reading, "こおひい")
        XCTAssertEqual(annotations.last?.reading, "のむ")
    }

    func testOversizedInputIsNotPartiallyAnnotated() throws {
        let text = String(repeating: "本", count: JapaneseFurigana.maximumUTF16Length + 1)
        XCTAssertTrue(try JapaneseFurigana.annotations(for: text).isEmpty)
    }

    func testCancelledWorkDoesNotReturnReadings() async throws {
        let task = Task.detached { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try JapaneseFurigana.annotations(for: "今日は学校に行きます。")
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        let cancelled = await task.value
        XCTAssertTrue(cancelled)
    }
}
