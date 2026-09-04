//
//  EpubSentenceSegmenter.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Splits a chapter's XHTML into exactly the sentences the desktop pre-translation tool addresses
//  (`tools/pretranslate/hoshi_pretranslate/epub.py`, `_ChapterTextExtractor` + `_segment`), so that
//  a sentence shown on its own resolves its stored translation through
//  `EpubTranslationStore.lookup(id: "c{spine}s{start}#{hash}", …)`.
//
//  Why this is not delegated to an HTML library (AGENTS.md asks for the concrete incompatibility):
//  the output required here is not "the text of the document" — it is a byte-identical
//  reproduction of one specific parser's text runs, because the sentence *addresses* are derived
//  from them and are already baked into blobs on disk and on the server. The tool's parser has
//  behaviors no general library reproduces: a block element emits a boundary on BOTH its start and
//  its end tag (and exactly one for a self-closing one), `rt`/`rp`/`script`/`style` subtrees are
//  dropped while `</ruby>` implicitly closes an unclosed `<rt>`, text before `<body>` is discarded,
//  and a text run is delimited by *any* tag rather than by element boundaries. Feeding the same
//  chapter to libxml2, WebKit or an XML parser produces a different run sequence, which produces
//  different offsets, which resolves either nothing or — worse — the wrong sentence. The Android
//  app carries the same hand-written port for the same reason
//  (features/reader/sentence/EpubSentenceSegmenter.kt); the three implementations are pinned to
//  each other by Tests/Regression/test_sentence_segmenter.py, which runs the real tool over a
//  fixture EPUB and demands identical triples.
//
//  Deliberately `nonisolated`: segmenting a novel is tens of milliseconds of pure computation and
//  runs off the main actor while sentence mode loads.
//

import Foundation

/// One addressable sentence of a chapter.
///
/// `start` and `length` count only *matchable* characters — the class `String.filtered()` keeps —
/// so they are independent of markup and whitespace and match the addresses the pre-translation
/// tool stores.
nonisolated struct ReaderSentence: Equatable, Sendable {
    /// Package spine index of the chapter, including `linear="no"` items.
    let spine: Int
    /// Matchable-character offset of the sentence's first matchable character within the chapter.
    let start: Int
    /// Number of matchable characters in the sentence.
    let length: Int
    /// The sentence as shown: punctuation kept, whitespace runs collapsed to single spaces.
    let text: String
    /// Paragraph ordinal within the chapter.
    let paragraph: Int

    /// The pre-translation tool's address for this sentence.
    var id: String { "c\(spine)s\(start)" }
}

/// A chapter as the tool sees it: its first heading, and its sentences.
nonisolated struct SegmentedChapter: Sendable {
    let heading: String
    let sentences: [ReaderSentence]
}

nonisolated enum EpubSentenceSegmenter {
    /// Characters that end a sentence. ASCII `.` is deliberately absent: in Japanese prose it is a
    /// decimal point or an abbreviation far more often than a full stop.
    private static let sentenceTerminators: Set<Unicode.Scalar> = Set("。！？!?".unicodeScalars)
    /// Swallowed after a terminator, so a sentence ending inside quotes keeps its closing bracket.
    private static let trailingChars: Set<Unicode.Scalar> = Set("。、！？…‥」』）)】〉》〕｝}］]".unicodeScalars)
    /// Where an over-long run with no terminator is split.
    private static let softBreak: Set<Unicode.Scalar> = Set("、，,".unicodeScalars)
    /// Hard ceiling in matchable characters, for a chapter with no sentence punctuation at all.
    private static let maxSentenceChars = 400

    /// Elements that end a sentence even without punctuation, so a heading or an unpunctuated line
    /// of dialogue stands on its own.
    private static let blockTags: Set<String> = [
        "p", "div", "br", "hr", "li", "dd", "dt", "blockquote", "pre", "figcaption", "figure",
        "h1", "h2", "h3", "h4", "h5", "h6",
        "section", "article", "aside", "nav", "header", "footer", "main",
        "table", "thead", "tbody", "tfoot", "tr", "td", "th", "caption",
        "ul", "ol", "dl",
    ]
    /// Subtrees whose text is not part of the chapter. `head`/`title` are covered by the `<body>`
    /// gate instead, so that `<svg><title>` inside the body still counts.
    private static let skipTags: Set<String> = ["rt", "rp", "script", "style"]
    private static let furiganaTags: Set<String> = ["rt", "rp"]
    private static let headingTags: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6"]

    // MARK: - Entry points

    static func segment(spine: Int, html: String) -> [ReaderSentence] {
        chapter(spine: spine, html: html).sentences
    }

    static func chapter(spine: Int, html: String) -> SegmentedChapter {
        let extracted = extractParts(html)
        return SegmentedChapter(
            heading: extracted.heading,
            sentences: segmentParts(spine: spine, parts: extracted.parts)
        )
    }

    // MARK: - The matchable-character class

    /// Kana, kanji, radicals, ASCII and fullwidth alphanumerics — the offset space every sentence
    /// address is counted in.
    ///
    /// An explicit predicate rather than a regular expression: the segmenter asks this of every
    /// character in the book, and `NSRegularExpression` per character is three orders of magnitude
    /// slower. `Tests/Regression/test_sentence_segmenter.py` proves the two agree on every one of
    /// the 1,112,064 Unicode scalars, so this stays exactly `EpubTranslationStore.normalize`'s
    /// character class.
    @inline(__always)
    static func isMatchable(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true              // 0-9 A-Z a-z
        case 0x25CB, 0x25EF: return true                                     // ○ ◯
        case 0x3005...0x3007: return true                                    // 々 〆 〇
        case 0x303B: return true                                             // 〻
        case 0x3041...0x3096: return true                                    // ぁ-ゖ
        case 0x309D...0x309E: return true                                    // ゝ-ゞ
        case 0x30A1...0x30FA: return true                                    // ァ-ヺ
        case 0x30FC: return true                                             // ー
        case 0xFF10...0xFF19, 0xFF21...0xFF3A, 0xFF41...0xFF5A: return true   // ０-９ Ａ-Ｚ ａ-ｚ
        case 0xFF66...0xFF9D: return true                                     // ｦ-ﾝ
        default: return scalar.properties.isUnifiedIdeograph || scalar.properties.isRadical
        }
    }

    /// Matchable characters among the first `scalarOffset` scalars of `text` — how far into the
    /// sentence a tap landed, in the address space.
    static func matchableCount(_ text: String, scalarOffset: Int) -> Int {
        var count = 0
        var index = 0
        for scalar in text.unicodeScalars {
            if index >= scalarOffset { break }
            if isMatchable(scalar) { count += 1 }
            index += 1
        }
        return count
    }

    // MARK: - Extraction

    struct Extraction {
        /// Text runs in document order; `nil` marks a block boundary.
        let parts: [String?]
        /// The chapter's first heading, whitespace-collapsed. Empty when it has none.
        let heading: String
    }

    /// Turns chapter markup into the tool's text runs.
    ///
    /// A run is delimited by *any* tag, not by element boundaries — that is what `html.parser`
    /// hands the tool, and it matters: a terminator only swallows the trailing brackets that sit in
    /// its own run, so `<p>「あ！<em>」</em></p>` is two sentences on both sides.
    ///
    /// Tolerant of the markup real books ship: unclosed tags, stray `<`, mismatched furigana.
    static func extractParts(_ html: String) -> Extraction {
        var parts: [String?] = []
        var heading = ""
        var headingChunks = ""
        var headingDepth = 0
        var pending = String.UnicodeScalarView()
        var skipStack: [String] = []
        // A fragment with no `<body>` at all is all body — the tool never sees one, but the reader
        // may be handed a chapter that was already unwrapped.
        var inBody = html.range(of: "<body", options: [.caseInsensitive, .literal]) == nil

        func flushText() {
            guard !pending.isEmpty else { return }
            let decoded = decodeEntities(String(pending))
            parts.append(decoded)
            if headingDepth > 0 { headingChunks += decoded }
            pending = String.UnicodeScalarView()
        }

        func boundary() {
            flushText()
            parts.append(nil)
        }

        let scalars = Array(html.unicodeScalars)
        let count = scalars.count
        var index = 0
        while index < count {
            if scalars[index] != "<" {
                var next = index
                while next < count, scalars[next] != "<" { next += 1 }
                if skipStack.isEmpty, inBody { pending.append(contentsOf: scalars[index..<next]) }
                index = next
                continue
            }
            // Every tag, comment or declaration ends the current text run, exactly as the parser's
            // data callback does.
            flushText()
            if matches(scalars, at: index, "<!--") {
                index = find(scalars, from: index + 4, "-->").map { $0 + 3 } ?? count
                continue
            }
            if matches(scalars, at: index, "<!") || matches(scalars, at: index, "<?") {
                index = firstIndex(of: ">", in: scalars, from: index).map { $0 + 1 } ?? count
                continue
            }
            guard let end = tagEnd(scalars, from: index) else { break }
            let raw = String(String.UnicodeScalarView(scalars[(index + 1)..<end]))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            index = end + 1
            let closing = raw.hasPrefix("/")
            let selfClosing = !closing && raw.hasSuffix("/")
            let name = tagName(raw)
            if name.isEmpty { continue }

            if !closing {
                if name == "body" { inBody = true }
                if skipTags.contains(name) {
                    if selfClosing { continue } // a self-closing skip tag has no content
                    // `<rt>` implicitly closes a previous `<rt>`/`<rp>` sibling.
                    if furiganaTags.contains(name), let top = skipStack.last, furiganaTags.contains(top) {
                        skipStack.removeLast()
                    }
                    skipStack.append(name)
                    continue
                }
                if !skipStack.isEmpty { continue }
                if blockTags.contains(name) { boundary() }
                // A self-closing block tag emits one boundary, not two, and never opens a heading.
                if !selfClosing, headingTags.contains(name), heading.isEmpty { headingDepth += 1 }
            } else {
                if skipTags.contains(name) {
                    if skipStack.contains(name) {
                        while let popped = skipStack.popLast(), popped != name {}
                    }
                    continue
                }
                if name == "ruby" {
                    // `</ruby>` closes any `<rt>`/`<rp>` still open, as every browser does.
                    while let top = skipStack.last, furiganaTags.contains(top) { skipStack.removeLast() }
                }
                if !skipStack.isEmpty { continue }
                if blockTags.contains(name) { boundary() }
                if headingTags.contains(name), headingDepth > 0 {
                    headingDepth -= 1
                    if headingDepth == 0, heading.isEmpty {
                        heading = collapseWhitespace(headingChunks)
                        headingChunks = ""
                    }
                }
            }
        }
        flushText()
        return Extraction(parts: parts, heading: heading)
    }

    // MARK: - Segmentation

    static func segmentParts(spine: Int, parts: [String?]) -> [ReaderSentence] {
        var sentences: [ReaderSentence] = []
        var normalizedCount = 0
        // One entry per scalar, so an over-long split lands on a character boundary.
        var buffer: [Unicode.Scalar] = []
        var bufferStart: Int?
        var bufferLength = 0
        var paragraph = 0
        var lastSoftBreak = -1

        func collapsed(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars)
            return collapseWhitespace(String(view))
        }

        func flush() {
            if let start = bufferStart, bufferLength > 0 {
                let text = collapsed(buffer[...])
                if !text.isEmpty {
                    sentences.append(ReaderSentence(
                        spine: spine, start: start, length: bufferLength, text: text, paragraph: paragraph
                    ))
                }
            }
            buffer = []
            bufferStart = nil
            bufferLength = 0
            lastSoftBreak = -1
        }

        /// Force-ends a run that has no terminator, preferring the last comma. A break at index 0
        /// would emit nothing and leave the buffer unchanged, so it is not taken.
        func splitOverlong() {
            let headEnd = (lastSoftBreak > 0 && lastSoftBreak < buffer.count - 1)
                ? lastSoftBreak + 1
                : buffer.count
            let head = buffer[0..<headEnd]
            let tail = Array(buffer[headEnd...])
            let headLength = head.reduce(into: 0) { $0 += isMatchable($1) ? 1 : 0 }
            let text = collapsed(head)
            if !text.isEmpty, headLength > 0, let start = bufferStart {
                sentences.append(ReaderSentence(
                    spine: spine, start: start, length: headLength, text: text, paragraph: paragraph
                ))
            }
            let tailMatchable = tail.reduce(into: 0) { $0 += isMatchable($1) ? 1 : 0 }
            let start = bufferStart
            buffer = tail
            bufferLength = tailMatchable
            bufferStart = (start != nil && tailMatchable > 0) ? start! + headLength : nil
            lastSoftBreak = -1
        }

        for part in parts {
            guard let part else {
                flush()
                paragraph += 1
                continue
            }
            let scalars = Array(part.unicodeScalars)
            var position = 0
            while position < scalars.count {
                let scalar = scalars[position]
                position += 1
                buffer.append(scalar)
                if isMatchable(scalar) {
                    if bufferStart == nil { bufferStart = normalizedCount }
                    normalizedCount += 1
                    bufferLength += 1
                } else if softBreak.contains(scalar) {
                    lastSoftBreak = buffer.count - 1
                }
                if sentenceTerminators.contains(scalar) {
                    while position < scalars.count, trailingChars.contains(scalars[position]) {
                        let trailing = scalars[position]
                        position += 1
                        buffer.append(trailing)
                        if isMatchable(trailing) {
                            normalizedCount += 1
                            bufferLength += 1
                        }
                    }
                    flush()
                } else if bufferLength >= maxSentenceChars {
                    splitOverlong()
                }
            }
        }
        flush()
        return sentences
    }

    // MARK: - Text helpers

    /// Python's `" ".join(text.split())`: every whitespace run becomes a single space, and leading
    /// and trailing whitespace disappears. The class is `str.isspace()` — Unicode `White_Space`
    /// plus the four ASCII separators U+001C…U+001F.
    static func collapseWhitespace(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace || (0x1C...0x1F).contains(scalar.value) {
                pendingSpace = !out.isEmpty
            } else {
                if pendingSpace { out.append(" ") }
                pendingSpace = false
                out.append(scalar)
            }
        }
        return String(out)
    }

    /// The named references that appear in real EPUB text, plus every numeric reference.
    ///
    /// Numeric references are the ones that matter for correctness: `&#12354;` left undecoded is
    /// the five matchable digits `12354`, which would shift every offset after it in the chapter.
    /// The named set is pinned to the Android port's table so the two apps agree character for
    /// character.
    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "hellip": "…", "mdash": "—", "ndash": "–", "ensp": "\u{2002}", "emsp": "\u{2003}",
        "thinsp": "\u{2009}", "copy": "©", "reg": "®", "trade": "™", "laquo": "«", "raquo": "»",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "middot": "·", "bull": "•",
        "deg": "°", "times": "×",
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar == "&" else {
                out.append(scalar)
                index += 1
                continue
            }
            guard let end = firstIndex(of: ";", in: scalars, from: index + 1), end - index <= 12 else {
                out.append(scalar)
                index += 1
                continue
            }
            let body = String(String.UnicodeScalarView(scalars[(index + 1)..<end]))
            let decoded: String?
            if body.lowercased().hasPrefix("#x") {
                decoded = UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) }
            } else if body.hasPrefix("#") {
                decoded = UInt32(body.dropFirst()).flatMap(Unicode.Scalar.init).map { String($0) }
            } else {
                decoded = namedEntities[body]
            }
            if let decoded {
                out.append(contentsOf: decoded.unicodeScalars)
                index = end + 1
            } else {
                out.append(scalar)
                index += 1
            }
        }
        return String(out)
    }

    // MARK: - Scanning helpers

    /// Index of the `>` closing the tag that starts at `start`, honoring quoted attributes.
    private static func tagEnd(_ scalars: [Unicode.Scalar], from start: Int) -> Int? {
        var quote: Unicode.Scalar?
        var index = start + 1
        while index < scalars.count {
            let scalar = scalars[index]
            if let open = quote {
                if scalar == open { quote = nil }
            } else if scalar == "\"" || scalar == "'" {
                quote = scalar
            } else if scalar == ">" {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func tagName(_ raw: String) -> String {
        var name = ""
        for character in raw.drop(while: { $0 == "/" }) {
            if character.isWhitespace || character == "/" { break }
            name.append(character)
        }
        return name.lowercased()
    }

    private static func matches(_ scalars: [Unicode.Scalar], at index: Int, _ prefix: String) -> Bool {
        let needle = Array(prefix.unicodeScalars)
        guard index + needle.count <= scalars.count else { return false }
        for offset in 0..<needle.count where scalars[index + offset] != needle[offset] { return false }
        return true
    }

    private static func firstIndex(
        of scalar: Unicode.Scalar,
        in scalars: [Unicode.Scalar],
        from start: Int
    ) -> Int? {
        var index = max(start, 0)
        while index < scalars.count {
            if scalars[index] == scalar { return index }
            index += 1
        }
        return nil
    }

    private static func find(_ scalars: [Unicode.Scalar], from start: Int, _ needle: String) -> Int? {
        var index = max(start, 0)
        while index < scalars.count {
            if matches(scalars, at: index, needle) { return index }
            index += 1
        }
        return nil
    }
}
