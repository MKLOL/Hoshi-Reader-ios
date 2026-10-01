import CoreText
import UIKit
import XCTest
@testable import Hoshi_Reader

nonisolated final class SentenceFontResolverTests: XCTestCase {
    @MainActor func testBuiltInReaderFamiliesKeepTheirJapaneseFacesAndSentenceSize() {
        for (family, expected) in [("Hiragino Mincho ProN", "HiraMinProN-W3"), ("Hiragino Kaku Gothic ProN", "HiraKakuProN-W3")] {
            let font = SentenceFontResolver.sentenceFont(named: family, size: 26)
            XCTAssertEqual(font.fontName, expected)
            XCTAssertEqual(font.pointSize, 28.6, accuracy: 0.0001)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "日本語の漢字とひらがなカタカナ。", attributes: [.font: font]))
            let runs = CTLineGetGlyphRuns(line) as! [CTRun]
            XCTAssertFalse(runs.isEmpty)
            for run in runs {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                let actual = attributes[kCTFontAttributeName] as! CTFont
                XCTAssertEqual(CTFontCopyPostScriptName(actual) as String, expected,
                               "ordinary Japanese must use the selected face rather than a locale fallback")
            }
        }
    }

    @MainActor func testAFontCollectionSelectsTheRequestedFaceInsteadOfItsFirstFace() throws {
        // Use an installed iOS collection; no downloaded fixture or bundled third-party font.
        let installed = try XCTUnwrap(UIFont(name: "AvenirNext-Regular", size: 26))
        let url = try XCTUnwrap(CTFontCopyAttribute(installed as CTFont, kCTFontURLAttribute) as? URL)
        let descriptors = try XCTUnwrap(CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])
        let names = descriptors.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String }
        XCTAssertGreaterThan(names.count, 1)
        for name in names {
            let resolved = try XCTUnwrap(SentenceFontResolver.font(at: url, preferredPostScriptName: name, size: 26))
            XCTAssertEqual(resolved.fontName, name)
            XCTAssertEqual(resolved.pointSize, 26)
        }
    }

    func testDownloadedFamiliesKeepTheRegularFaceAndHorizontalKyokashoVariant() {
        XCTAssertEqual(FontManager.postScriptName(for: "Klee"), "Klee-Medium")
        XCTAssertEqual(FontManager.postScriptName(for: "Tsukushi A Round Gothic"), "TsukuARdGothic-Regular")
        XCTAssertEqual(FontManager.postScriptName(for: "YuKyokasho", verticalWriting: true), "YuKyo-Medium")
        XCTAssertEqual(FontManager.postScriptName(for: "YuKyokasho", verticalWriting: false), "YuKyo_Yoko-Medium")
        XCTAssertEqual(FontManager.postScriptName(for: "YuMincho"), "YuMin-Medium")
        XCTAssertEqual(FontManager.postScriptName(for: "YuGothic"), "YuGo-Medium")
    }
}
