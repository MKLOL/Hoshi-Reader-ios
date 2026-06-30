//
//  MangaAiTextTokenizer.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import NaturalLanguage

/// Thin wrapper around Apple's NaturalLanguage tokenizer for AI response layout. Japanese is still
/// handled per character for dictionary taps; Latin word boundaries come from `NLTokenizer`.
nonisolated enum MangaAiTextTokenizer {
    enum SegmentKind: String {
        case japanese
        case word
        case whitespace
        case punctuation
    }

    struct Segment: Equatable {
        let text: String
        let kind: SegmentKind
    }

    static func segments(in text: String) -> [Segment] {
        guard !text.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text

        var result: [Segment] = []
        var cursor = text.startIndex
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            appendNonWord(text[cursor..<range.lowerBound], to: &result)
            appendWord(text[range], to: &result)
            cursor = range.upperBound
            return true
        }
        appendNonWord(text[cursor..<text.endIndex], to: &result)
        return mergeWordJoiners(result)
    }

    private static func appendWord(_ slice: Substring, to result: inout [Segment]) {
        let text = String(slice)
        if text.contains(where: { $0.isMangaAiJapanese }) {
            appendNonWord(slice, to: &result)
        } else {
            append(text: text, kind: .word, to: &result)
        }
    }

    private static func appendNonWord(_ slice: Substring, to result: inout [Segment]) {
        var current = ""
        var currentKind: SegmentKind?

        func flush() {
            guard let kind = currentKind, !current.isEmpty else { return }
            append(text: current, kind: kind, to: &result)
            current = ""
            currentKind = nil
        }

        for character in slice {
            let kind = nonWordKind(for: character)
            if kind == .japanese {
                flush()
                result.append(Segment(text: String(character), kind: .japanese))
            } else if currentKind == nil || currentKind == kind {
                current.append(character)
                currentKind = kind
            } else {
                flush()
                current.append(character)
                currentKind = kind
            }
        }
        flush()
    }

    private static func append(text: String, kind: SegmentKind, to result: inout [Segment]) {
        result.append(Segment(text: text, kind: kind))
    }

    private static func nonWordKind(for character: Character) -> SegmentKind {
        if character.isMangaAiJapanese { return .japanese }
        if character.isWhitespace { return .whitespace }
        return .punctuation
    }

    private static func mergeWordJoiners(_ segments: [Segment]) -> [Segment] {
        var merged: [Segment] = []
        var index = 0
        while index < segments.count {
            guard segments[index].kind == .word else {
                merged.append(segments[index])
                index += 1
                continue
            }

            var text = segments[index].text
            var next = index
            while next + 2 < segments.count,
                  segments[next + 1].kind == .punctuation,
                  isWordJoiner(segments[next + 1].text),
                  segments[next + 2].kind == .word {
                text += segments[next + 1].text + segments[next + 2].text
                next += 2
            }
            merged.append(Segment(text: text, kind: .word))
            index = next + 1
        }
        return merged
    }

    private static func isWordJoiner(_ text: String) -> Bool {
        text == "'" || text == "\u{2019}" || text == "-"
    }
}

private extension Character {
    nonisolated var isMangaAiJapanese: Bool {
        if self == "ー" || self == "々" || self == "〆" || self == "〤" { return true }
        for scalar in unicodeScalars {
            let value = scalar.value
            let isJapanese =
                (0x3040...0x309F).contains(value) ||
                (0x30A0...0x30FF).contains(value) ||
                (0x31F0...0x31FF).contains(value) ||
                (0x3400...0x4DBF).contains(value) ||
                (0x4E00...0x9FFF).contains(value) ||
                (0xF900...0xFAFF).contains(value) ||
                (0x20000...0x2A6DF).contains(value)
            if !isJapanese { return false }
        }
        return true
    }
}
