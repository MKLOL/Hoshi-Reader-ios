//
//  PretranslationModels.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Which engine translates and how.
nonisolated enum PretranslationEngine: Hashable, Sendable {
    /// A cloud model from `ChatModelCatalog` or a custom id.
    case cloud(modelId: String)
    /// The downloaded llama.cpp model selected in the offline translation settings.
    case onDevice(modelId: String)

    var label: String {
        switch self {
        case .cloud(let modelId): return modelId
        case .onDevice(let modelId): return "on-device:\(modelId)"
        }
    }

    var isOnDevice: Bool {
        if case .onDevice = self { return true }
        return false
    }
}

nonisolated struct PretranslationConfig: Hashable, Sendable {
    var engine: PretranslationEngine
    /// Ask for a short vocabulary/grammar note per sentence in addition to the translation.
    var includeExplanations: Bool = true
    var customInstructions: String = ""
    var effectiveInstructions: String { engine.isOnDevice ? "" : customInstructions }
    var sentencesPerRequest: Int = PretranslationConfig.defaultSentencesPerRequest

    static let defaultSentencesPerRequest = 12
    /// Anthropic replies are capped at 2048 output tokens, so its batches stay small.
    static let anthropicSentencesPerRequest = 6

    /// The batch size the job will actually use: Anthropic's output cap forces smaller batches.
    func withEffectiveBatchSize() -> PretranslationConfig {
        guard sentencesPerRequest == Self.defaultSentencesPerRequest, case .cloud(let modelId) = engine else { return self }
        var copy = self
        if ChatModelCatalog.provider(forModelId: modelId).wireFormat == .anthropic {
            copy.sentencesPerRequest = Self.anthropicSentencesPerRequest
        }
        return copy
    }
}

/// Token and cost estimate shown before a job starts.
nonisolated struct PretranslationEstimate: Equatable, Sendable {
    let sentenceCount: Int
    let characterCount: Int
    let inputTokens: Int
    let outputTokens: Int
    /// Nil when the model's price is unknown or the engine runs on-device.
    let costUsd: Double?
}

/// The sentences of one book (spine order) plus the estimate for translating them.
nonisolated struct PretranslationPlan: Sendable {
    let bookId: UUID
    let syncId: String
    let title: String
    let spineCount: Int
    let sentences: [ReaderSentence]
    let estimate: PretranslationEstimate
}

/// One translated sentence, keyed by the sentence address (`c{spine}s{start}`).
nonisolated struct SentenceTranslationResult: Equatable, Sendable {
    let sentenceId: String
    let translation: String
    var explanation: String = ""
}

nonisolated enum PretranslationJobState: Equatable, Sendable {
    case queued
    /// `cancelling`: the user asked to stop; the in-flight request finishes before the job ends.
    case running(completed: Int, total: Int, engineLabel: String, cancelling: Bool)
    case uploading
    /// `uploadAttempted` is false when sync is not configured; `uploaded` is meaningful only then.
    case finished(translated: Int, total: Int, uploadAttempted: Bool, uploaded: Bool, engineLabel: String)
    /// `savedTranslations`: sentences translated and saved before the job gave up.
    case failed(message: String, savedTranslations: Int)
    case cancelled(savedTranslations: Int)

    var isActive: Bool {
        switch self {
        case .queued, .running, .uploading: return true
        case .finished, .failed, .cancelled: return false
        }
    }
}
