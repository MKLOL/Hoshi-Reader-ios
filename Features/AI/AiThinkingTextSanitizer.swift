//
//  AiThinkingTextSanitizer.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Removes chain-of-thought scaffolding that some local reasoning models emit as literal text.
nonisolated enum AiThinkingTextSanitizer {
    private static let startTags = ["<think>", "<thinking>"]
    private static let endTags = ["</think>", "</thinking>"]
    private static let thinkingLabels = [
        "thinking process",
        "thinking processes",
        "thought process"
    ]
    private static let reasoningLabels = ["reasoning:", "analysis:"]
    private static let untaggedReasoningPrefixes = [
        "wait, let's check",
        "wait, lets check",
        "wait, let me check",
        "wait, looking",
        "wait, i need",
        "wait, we need",
        "wait, first,",
        "let's check",
        "lets check"
    ]
    private static let visibleScaffoldNeedles = [
        "draft translation",
        "draft breakdown",
        "draft answer",
        "checking the",
        "let's check",
        "lets check",
        "looking at the"
    ]

    static func strip(_ raw: String) -> String {
        var text = raw

        while let open = firstRange(of: startTags, in: text) {
            if let close = firstRange(of: endTags, in: text, range: open.upperBound..<text.endIndex) {
                text.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                text.removeSubrange(open.lowerBound..<text.endIndex)
                break
            }
        }

        while let close = firstRange(of: endTags, in: text) {
            text.removeSubrange(close)
        }

        return stripReasoningPrefix(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func stripUntaggedReasoning(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if let answer = answerAfterVisibleScaffold(in: text) {
            return answer
        }
        guard untaggedReasoningPrefixes.contains(where: { lower.hasPrefix($0) }) else {
            return text
        }

        if let answer = answerStart(in: text) {
            return String(text[answer...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let paragraphBreak = text.range(of: "\n\n") {
            let tail = String(text[paragraphBreak.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let lowerTail = tail.lowercased()
            if !untaggedReasoningPrefixes.contains(where: { lowerTail.hasPrefix($0) }) {
                return tail
            }
        }
        return ""
    }

    private static func answerAfterVisibleScaffold(in text: String) -> String? {
        let lower = text.lowercased()
        let containsScaffold = visibleScaffoldNeedles.contains { lower.contains($0) }
        guard containsScaffold else { return nil }

        if let range = answerLabelRange(in: text) {
            let section = String(text[range.upperBound...])
            return cleanedAnswerSection(section)
        }
        return nil
    }

    private static func stripReasoningPrefix(_ text: String) -> String {
        let leadingWhitespace = text.prefix { $0.isWhitespace }
        let bodyStart = text.index(text.startIndex, offsetBy: leadingWhitespace.count)
        let body = String(text[bodyStart...])
        let lowerBody = body.lowercased()
        let isThinkingPrefix = thinkingLabels.contains { label in
            lowerBody.hasPrefix(label)
        }
        let isReasoningPrefix = reasoningLabels.contains { label in
            lowerBody.hasPrefix(label)
        }
        guard isThinkingPrefix || isReasoningPrefix else { return text }

        if let answer = answerStart(in: body) {
            return String(body[answer...])
        }
        if let paragraphBreak = body.range(of: "\n\n") {
            return String(body[paragraphBreak.upperBound...])
        }
        return ""
    }

    private static func answerStart(in text: String) -> String.Index? {
        if let range = answerLabelRange(in: text) {
            return range.lowerBound
        }
        return nil
    }

    private static func answerLabelRange(in text: String) -> Range<String.Index>? {
        let labels = [
            "**final answer:**",
            "**translation:**",
            "**draft translation:**",
            "final answer:",
            "answer:",
            "translation:",
            "draft translation:",
            "final:"
        ]
        var best: Range<String.Index>?
        for label in labels {
            if let start = text.range(of: label, options: [.caseInsensitive]),
               start.lowerBound == text.startIndex {
                best = start
                break
            }
            if let range = text.range(of: "\n\(label)", options: [.caseInsensitive]) {
                let adjusted = text.index(range.lowerBound, offsetBy: 1)..<range.upperBound
                if best == nil || adjusted.lowerBound < best!.lowerBound {
                    best = adjusted
                }
            }
        }
        let numberedPatterns = [
            #"\n\s*\d+\.\s*\*\*draft translation:\*\*"#,
            #"\n\s*\d+\.\s*draft translation:"#,
            #"\n\s*\d+\.\s*\*\*translation:\*\*"#,
            #"\n\s*\d+\.\s*translation:"#
        ]
        for pattern in numberedPatterns {
            if let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                let adjusted = text.index(range.lowerBound, offsetBy: 1)..<range.upperBound
                if best == nil || adjusted.lowerBound < best!.lowerBound {
                    best = adjusted
                }
            }
        }
        return best
    }

    private static func cleanedAnswerSection(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let cutoffLabels = [
            "\n**draft breakdown:**",
            "\ndraft breakdown:",
            "\n5. **draft breakdown:**",
            "\n5. draft breakdown:"
        ]
        for label in cutoffLabels {
            if let range = text.range(of: label, options: [.caseInsensitive]) {
                text = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if let naturalLine = lines.first(where: { $0.lowercased().contains("natural:") }) {
            let line = String(naturalLine)
            if let colon = line.firstIndex(of: ":") {
                return line[line.index(after: colon)...]
                    .trimmingCharacters(in: CharacterSet(charactersIn: " *-\t"))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return text
            .replacingOccurrences(of: "Draft Translation:", with: "Translation:", options: [.caseInsensitive])
            .replacingOccurrences(of: "**Draft Translation:**", with: "Translation:", options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstRange(
        of needles: [String],
        in text: String,
        range: Range<String.Index>? = nil
    ) -> Range<String.Index>? {
        let searchRange = range ?? text.startIndex..<text.endIndex
        var best: Range<String.Index>?
        for needle in needles {
            guard let found = text.range(of: needle, options: [.caseInsensitive], range: searchRange) else {
                continue
            }
            if best == nil || found.lowerBound < best!.lowerBound {
                best = found
            }
        }
        return best
    }
}
