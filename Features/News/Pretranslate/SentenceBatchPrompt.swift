//
//  SentenceBatchPrompt.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  The batch contract with a cloud model: a fixed instruction, a JSON array of `{id, text}` items,
//  and a JSON array of `{id, translation, explanation}` back. Parsing is lenient about code fences,
//  reasoning blocks and prose around the array, salvages the complete items of a reply cut off by
//  an output-token cap, and matches every item by id. Identical to the Android prompt so both apps
//  produce the same `promptId`.
//

import Foundation

nonisolated enum SentenceBatchPrompt {
    static func instructions(includeExplanations: Bool) -> String {
        var text = "You translate sentences from an easy Japanese news article for a language learner. "
        text += "For every item in the JSON array below, write a natural English translation"
        if includeExplanations {
            text += " and a short note (one or two lines, Markdown allowed) on vocabulary or grammar a learner might find tricky; "
            text += "leave the note empty when nothing is tricky"
        }
        text += ". "
        text += "Reply with JSON only: an array with one object per input item, in the same order, "
        text += "shaped like {\"id\": string, \"translation\": string, \"explanation\": string}. "
        text += "Keep the id exactly as given. Do not add any text before or after the JSON."
        return text
    }

    /// Stable identifier of the prompt, stored in the translation blob's `promptId`.
    static func promptId(includeExplanations: Bool) -> String {
        "sha256:" + String(sha256Hex(instructions(includeExplanations: includeExplanations)).prefix(32))
    }

    static func itemsJson(_ sentences: [ReaderSentence]) -> String {
        let items = sentences.map { ["id": $0.id, "text": $0.text] }
        let data = (try? JSONSerialization.data(withJSONObject: items, options: [.withoutEscapingSlashes])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// The one-sentence prompt used when a batch reply left an item out.
    static func singleInstructions(includeExplanations: Bool) -> String {
        var text = "Translate this sentence from an easy Japanese news article into natural English"
        if includeExplanations { text += ", then add a short note on tricky vocabulary or grammar if any" }
        text += ". Reply with JSON only, shaped like {\"translation\": string, \"explanation\": string}."
        return text
    }

    /// Extracts translations from a model reply. Returns only well-formed items whose id is among
    /// `expectedIds`; callers retry whatever is missing.
    static func parseBatch(_ reply: String, expectedIds: Set<String>) -> [String: SentenceTranslationResult] {
        let cleaned = strip(reply)
        guard let array = parseArray(cleaned) else { return [:] }
        var result: [String: SentenceTranslationResult] = [:]
        for element in array {
            guard let item = element as? [String: Any], let rawId = item["id"] as? String else { continue }
            let id = rawId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard expectedIds.contains(id), result[id] == nil else { continue }
            guard let translation = (item["translation"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !translation.isEmpty else { continue }
            result[id] = SentenceTranslationResult(sentenceId: id, translation: translation, explanation: (item["explanation"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
        return result
    }

    /// A single-sentence reply. JSON is required when the model attempted it; a plain-text reply (no
    /// braces at all) is accepted as the translation because some models ignore the format
    /// instruction, but a broken or truncated JSON object is rejected rather than stored as a fragment.
    static func parseSingle(_ reply: String, sentenceId: String) -> SentenceTranslationResult? {
        let cleaned = strip(reply)
        if let start = cleaned.firstIndex(of: "{") {
            guard let end = cleaned.lastIndex(of: "}"), end > start,
                  let object = try? JSONSerialization.jsonObject(with: Data(cleaned[start...end].utf8)) as? [String: Any],
                  let translation = (object["translation"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !translation.isEmpty
            else { return nil }
            return SentenceTranslationResult(sentenceId: sentenceId, translation: translation, explanation: (object["explanation"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
        let plain = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty, plain.count < 2_000 else { return nil }
        return SentenceTranslationResult(sentenceId: sentenceId, translation: plain)
    }

    private static func strip(_ reply: String) -> String {
        reply
            .replacingOccurrences(of: #"<think>[\s\S]*?(</think>|$)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"```[a-zA-Z]*"#, with: "", options: .regularExpression)
    }

    /// Finds the reply's array. Tries the outermost `[...]` first; when that is not valid JSON
    /// (typically because the output was truncated mid-item), parses the longest prefix that ends at
    /// a complete object so the finished items are still used.
    private static func parseArray(_ text: String) -> [Any]? {
        guard let start = text.firstIndex(of: "[") else { return nil }
        if let end = text.lastIndex(of: "]"), end > start, let array = parseArrayOrNil(String(text[start...end])) { return array }
        if let objectStart = text.firstIndex(of: "{"), objectStart < start, let objectEnd = text.lastIndex(of: "}"), objectEnd > objectStart,
           let object = try? JSONSerialization.jsonObject(with: Data(text[objectStart...objectEnd].utf8)) as? [String: Any],
           let wrapped = object.values.first(where: { $0 is [Any] }) as? [Any] {
            return wrapped
        }
        var closeBrace = text.lastIndex(of: "}")
        while let brace = closeBrace, brace > start {
            if let array = parseArrayOrNil(String(text[start...brace]) + "]") { return array }
            closeBrace = text[..<brace].lastIndex(of: "}")
        }
        return nil
    }

    private static func parseArrayOrNil(_ candidate: String) -> [Any]? {
        (try? JSONSerialization.jsonObject(with: Data(candidate.utf8))) as? [Any]
    }
}
