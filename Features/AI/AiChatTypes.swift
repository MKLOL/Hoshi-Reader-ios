//
//  AiChatTypes.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  The ChatGPT/LLM data graph, ported from the Android features/ai/AiChatHistory.kt. Persisted
//  per-manga in `ai_chat_log.json` and also used as the chat sync blob shape, so field names
//  must match Android. Missing list/optional fields decode to empty/nil for forward-compat.
//

import Foundation

/// Image bytes attached to a ChatGPT exchange (screenshot translation), base64 without the
/// `data:` prefix.
nonisolated struct AiChatImage: Codable, Equatable {
    let mimeType: String
    let base64Data: String
}

/// One ChatGPT exchange about a manga bubble or screenshot. `timestampSeconds` is in the same
/// Apple-reference-date epoch the rest of the app's sidecar files use.
nonisolated struct AiChatEntry: Codable, Equatable, Identifiable {
    let bubbleText: String
    let prompt: String
    let model: String
    let response: String
    let timestampSeconds: Double
    var screenshotImage: AiChatImage?
    var dictionaryLookup: AiChatDictionaryLookup?
    /// Optional one-line on-device LLM telemetry (Android only); `nil` for ChatGPT replies. Kept
    /// for wire compatibility.
    var debugInfo: String?

    /// Stable identity for SwiftUI lists. Content-addressed like the sync chat key.
    var id: String { chatEntryKeySuffix(timestampAppleSeconds: timestampSeconds, bubbleText: bubbleText, response: response) }

    enum CodingKeys: String, CodingKey {
        case bubbleText, prompt, model, response, timestampSeconds, screenshotImage, dictionaryLookup, debugInfo
    }

    init(bubbleText: String, prompt: String, model: String, response: String, timestampSeconds: Double,
         screenshotImage: AiChatImage? = nil, dictionaryLookup: AiChatDictionaryLookup? = nil, debugInfo: String? = nil) {
        self.bubbleText = bubbleText
        self.prompt = prompt
        self.model = model
        self.response = response
        self.timestampSeconds = timestampSeconds
        self.screenshotImage = screenshotImage
        self.dictionaryLookup = dictionaryLookup
        self.debugInfo = debugInfo
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bubbleText = try c.decode(String.self, forKey: .bubbleText)
        prompt = try c.decode(String.self, forKey: .prompt)
        model = try c.decode(String.self, forKey: .model)
        response = try c.decode(String.self, forKey: .response)
        timestampSeconds = try c.decode(Double.self, forKey: .timestampSeconds)
        screenshotImage = try c.decodeIfPresent(AiChatImage.self, forKey: .screenshotImage)
        dictionaryLookup = try c.decodeIfPresent(AiChatDictionaryLookup.self, forKey: .dictionaryLookup)
        debugInfo = try c.decodeIfPresent(String.self, forKey: .debugInfo)
    }
}

/// The per-manga ChatGPT history, newest entries last.
nonisolated struct AiChatLog: Codable, Equatable {
    var entries: [AiChatEntry]

    init(entries: [AiChatEntry] = []) { self.entries = entries }

    enum CodingKeys: String, CodingKey { case entries }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = try c.decodeIfPresent([AiChatEntry].self, forKey: .entries) ?? []
    }
}

/// Compact Yomitan-style lookup context stored beside a ChatGPT exchange.
nonisolated struct AiChatDictionaryLookup: Codable, Equatable {
    let query: String
    var results: [AiChatDictionaryLookupResult]

    init(query: String, results: [AiChatDictionaryLookupResult] = []) {
        self.query = query
        self.results = results
    }

    enum CodingKeys: String, CodingKey { case query, results }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        query = try c.decode(String.self, forKey: .query)
        results = try c.decodeIfPresent([AiChatDictionaryLookupResult].self, forKey: .results) ?? []
    }
}

nonisolated struct AiChatDictionaryLookupResult: Codable, Equatable {
    let expression: String
    let reading: String
    let matched: String
    var deinflectionTrace: [AiChatDeinflectionStep]
    var glossaries: [AiChatGlossary]
    var frequencies: [AiChatFrequencyGroup]
    var pitches: [AiChatPitchGroup]
    var rules: [String]

    init(expression: String, reading: String, matched: String,
         deinflectionTrace: [AiChatDeinflectionStep] = [], glossaries: [AiChatGlossary] = [],
         frequencies: [AiChatFrequencyGroup] = [], pitches: [AiChatPitchGroup] = [], rules: [String] = []) {
        self.expression = expression
        self.reading = reading
        self.matched = matched
        self.deinflectionTrace = deinflectionTrace
        self.glossaries = glossaries
        self.frequencies = frequencies
        self.pitches = pitches
        self.rules = rules
    }

    enum CodingKeys: String, CodingKey {
        case expression, reading, matched, deinflectionTrace, glossaries, frequencies, pitches, rules
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        expression = try c.decode(String.self, forKey: .expression)
        reading = try c.decode(String.self, forKey: .reading)
        matched = try c.decode(String.self, forKey: .matched)
        deinflectionTrace = try c.decodeIfPresent([AiChatDeinflectionStep].self, forKey: .deinflectionTrace) ?? []
        glossaries = try c.decodeIfPresent([AiChatGlossary].self, forKey: .glossaries) ?? []
        frequencies = try c.decodeIfPresent([AiChatFrequencyGroup].self, forKey: .frequencies) ?? []
        pitches = try c.decodeIfPresent([AiChatPitchGroup].self, forKey: .pitches) ?? []
        rules = try c.decodeIfPresent([String].self, forKey: .rules) ?? []
    }
}

nonisolated struct AiChatDeinflectionStep: Codable, Equatable {
    let name: String
    let description: String
}

nonisolated struct AiChatGlossary: Codable, Equatable {
    let dictionary: String
    let content: String
    let definitionTags: String
    let termTags: String
}

nonisolated struct AiChatFrequencyGroup: Codable, Equatable {
    let dictionary: String
    var frequencies: [AiChatFrequency]

    init(dictionary: String, frequencies: [AiChatFrequency] = []) {
        self.dictionary = dictionary
        self.frequencies = frequencies
    }

    enum CodingKeys: String, CodingKey { case dictionary, frequencies }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dictionary = try c.decode(String.self, forKey: .dictionary)
        frequencies = try c.decodeIfPresent([AiChatFrequency].self, forKey: .frequencies) ?? []
    }
}

nonisolated struct AiChatFrequency: Codable, Equatable {
    let value: Int
    let displayValue: String
}

nonisolated struct AiChatPitchGroup: Codable, Equatable {
    let dictionary: String
    var pitchPositions: [Int]

    init(dictionary: String, pitchPositions: [Int] = []) {
        self.dictionary = dictionary
        self.pitchPositions = pitchPositions
    }

    enum CodingKeys: String, CodingKey { case dictionary, pitchPositions }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dictionary = try c.decode(String.self, forKey: .dictionary)
        pitchPositions = try c.decodeIfPresent([Int].self, forKey: .pitchPositions) ?? []
    }
}
