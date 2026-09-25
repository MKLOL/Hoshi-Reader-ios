//
//  SentenceTranslator.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// The model behind a pre-translation job. Implementations are stateless and called serially.
nonisolated protocol SentenceTranslating: Sendable {
    /// Whether `translateBatch` is worth calling; small on-device models answer one sentence at a time.
    var supportsBatches: Bool { get }
    /// Translates several sentences in one request. May return a subset; missing ids are retried singly.
    func translateBatch(_ sentences: [ReaderSentence], includeExplanations: Bool) async throws -> [String: SentenceTranslationResult]
    /// Translates one sentence, or returns nil when the reply was unusable.
    func translateOne(_ sentence: ReaderSentence, includeExplanations: Bool) async throws -> SentenceTranslationResult?
}

/// Sends batches through the same clients the reader's live translation uses.
nonisolated struct CloudSentenceTranslator: SentenceTranslating {
    let provider: ChatProvider
    let apiKey: String
    let modelId: String
    var customInstructions: String = ""
    var supportsBatches: Bool { true }

    func translateBatch(_ sentences: [ReaderSentence], includeExplanations: Bool) async throws -> [String: SentenceTranslationResult] {
        let reply = try await CloudChat.complete(
            provider: provider, apiKey: apiKey, model: modelId,
            prompt: SentenceBatchPrompt.instructions(includeExplanations: includeExplanations, customInstructions: customInstructions),
            bubbleText: SentenceBatchPrompt.itemsJson(sentences)
        )
        return SentenceBatchPrompt.parseBatch(reply, expectedIds: Set(sentences.map(\.id)))
    }

    func translateOne(_ sentence: ReaderSentence, includeExplanations: Bool) async throws -> SentenceTranslationResult? {
        let reply = try await CloudChat.complete(
            provider: provider, apiKey: apiKey, model: modelId,
            prompt: SentenceBatchPrompt.singleInstructions(includeExplanations: includeExplanations, customInstructions: customInstructions),
            bubbleText: sentence.text
        )
        return SentenceBatchPrompt.parseSingle(reply, sentenceId: sentence.id)
    }
}

/// Runs the downloaded llama.cpp model one sentence at a time; explanations are not requested.
nonisolated struct OnDeviceSentenceTranslator: SentenceTranslating {
    var supportsBatches: Bool { false }

    func translateBatch(_ sentences: [ReaderSentence], includeExplanations: Bool) async throws -> [String: SentenceTranslationResult] { [:] }

    func translateOne(_ sentence: ReaderSentence, includeExplanations: Bool) async throws -> SentenceTranslationResult? {
        let manager = await OfflineLlmManager.shared
        let result = try await manager.translate(
            instruction: "Translate the following Japanese sentence into natural English. Reply with the translation only.",
            japaneseText: sentence.text
        )
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : SentenceTranslationResult(sentenceId: sentence.id, translation: text)
    }
}
