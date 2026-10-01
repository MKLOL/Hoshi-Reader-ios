import CoreFoundation
import Foundation

/// Offline readings for plain Japanese text that has no publisher-supplied ruby. CoreFoundation
/// owns word segmentation and pronunciation; Foundation's ICU transform produces the kana.
/// These are whole-token readings, not final ruby bases. The shared `furigana.js` dictionary
/// segmenter removes matching kana/okurigana before WebKit lays out native HTML ruby.
/// Call from a background task and retain the original text: ranges address its UTF-16 units.
nonisolated enum JapaneseFurigana {
    static let maximumUTF16Length = 16_384

    static func annotations(for text: String) throws -> [RubyAnnotation] {
        try Task.checkCancellation()
        let length = text.utf16.prefix(maximumUTF16Length + 1).count
        guard length > 0, length <= maximumUTF16Length else { return [] }
        guard let tokenizer = CFStringTokenizerCreate(
            nil, text as CFString, CFRange(location: 0, length: length),
            // Word-boundary mode explicitly honors the locale even for kanji-only input.
            kCFStringTokenizerUnitWordBoundary | kCFStringTokenizerAttributeLatinTranscription,
            Locale(identifier: "ja") as CFLocale
        ) else { return [] }

        let original = text as NSString
        var result: [RubyAnnotation] = []
        while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
            try Task.checkCancellation()
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            guard range.location >= 0, range.length > 0,
                  range.location <= length, range.length <= length - range.location else { continue }
            let base = original.substring(with: NSRange(location: range.location, length: range.length))
            guard base.unicodeScalars.contains(where: { $0.properties.isIdeographic }),
                  let latin = CFStringTokenizerCopyCurrentTokenAttribute(
                    tokenizer, kCFStringTokenizerAttributeLatinTranscription
                  ) as? String,
                  let converted = latin.applyingTransform(.latinToHiragana, reverse: false) else { continue }
            let reading = converted.precomposedStringWithCanonicalMapping
            // A missing/unknown pronunciation may be returned verbatim. Never put Latin text,
            // punctuation, digits, or unresolved kanji above the sentence as if it were a reading.
            guard !reading.isEmpty, reading.unicodeScalars.allSatisfy({ scalar in
                (0x3041...0x3096).contains(scalar.value) ||
                (0x309D...0x309F).contains(scalar.value) || scalar.value == 0x30FC
            }) else { continue }
            result.append(RubyAnnotation(start: range.location, length: range.length, reading: reading))
        }
        return result
    }
}
