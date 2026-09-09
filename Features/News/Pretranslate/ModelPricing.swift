//
//  ModelPricing.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Approximate list price of one cloud model, in US dollars per million tokens.
nonisolated struct ModelPrice: Equatable, Sendable {
    let inputPerMillionUsd: Double
    let outputPerMillionUsd: Double
}

/// Rough per-token list prices for the models in `ChatModelCatalog`, used only to show the user an
/// estimate before a bulk job starts. Providers change prices without notice, so every number here
/// is labeled approximate in the UI and an unknown model shows no dollar figure. Same table as the
/// Android app.
nonisolated enum ModelPricing {
    /// Month the table was last checked against the providers' pricing pages.
    static let pricesAsOf = "2026-01"

    private static let prices: [String: ModelPrice] = [
        "gpt-5.5": ModelPrice(inputPerMillionUsd: 1.25, outputPerMillionUsd: 10.0),
        "gpt-5": ModelPrice(inputPerMillionUsd: 1.25, outputPerMillionUsd: 10.0),
        "gpt-5-mini": ModelPrice(inputPerMillionUsd: 0.25, outputPerMillionUsd: 2.0),
        "gpt-4o": ModelPrice(inputPerMillionUsd: 2.5, outputPerMillionUsd: 10.0),
        "gpt-4o-mini": ModelPrice(inputPerMillionUsd: 0.15, outputPerMillionUsd: 0.6),
        "claude-opus-4-8": ModelPrice(inputPerMillionUsd: 5.0, outputPerMillionUsd: 25.0),
        "claude-sonnet-4-6": ModelPrice(inputPerMillionUsd: 3.0, outputPerMillionUsd: 15.0),
        "claude-haiku-4-5": ModelPrice(inputPerMillionUsd: 1.0, outputPerMillionUsd: 5.0),
        "gemini-3.6-flash": ModelPrice(inputPerMillionUsd: 0.5, outputPerMillionUsd: 3.0),
        "gemini-3.1-pro-preview": ModelPrice(inputPerMillionUsd: 2.0, outputPerMillionUsd: 12.0),
        "gemini-3.1-flash-lite": ModelPrice(inputPerMillionUsd: 0.1, outputPerMillionUsd: 0.4),
        "deepseek-chat": ModelPrice(inputPerMillionUsd: 0.28, outputPerMillionUsd: 0.42),
        "deepseek-reasoner": ModelPrice(inputPerMillionUsd: 0.28, outputPerMillionUsd: 0.42),
        "qwen-plus": ModelPrice(inputPerMillionUsd: 0.4, outputPerMillionUsd: 1.2),
        "qwen-turbo": ModelPrice(inputPerMillionUsd: 0.05, outputPerMillionUsd: 0.2),
        "qwen-max": ModelPrice(inputPerMillionUsd: 1.6, outputPerMillionUsd: 6.4),
        "moonshot-v1-8k": ModelPrice(inputPerMillionUsd: 0.2, outputPerMillionUsd: 2.0),
        "moonshot-v1-32k": ModelPrice(inputPerMillionUsd: 1.0, outputPerMillionUsd: 3.0),
    ]

    static func price(for modelId: String) -> ModelPrice? {
        prices[ChatModelCatalog.replacementModelId(for: modelId)] ?? prices[modelId]
    }

    /// Estimated cost in USD, or nil when the model has no known price.
    static func estimateUsd(modelId: String, inputTokens: Int, outputTokens: Int) -> Double? {
        guard let price = price(for: modelId) else { return nil }
        return Double(inputTokens) / 1_000_000 * price.inputPerMillionUsd + Double(outputTokens) / 1_000_000 * price.outputPerMillionUsd
    }

    /// `$0.0042`, `$0.123`, `$3.40`: enough digits to be meaningful at the low end.
    static func formatUsd(_ amount: Double) -> String {
        if amount < 0.01 { return String(format: "$%.4f", amount) }
        if amount < 1.0 { return String(format: "$%.3f", amount) }
        return String(format: "$%.2f", amount)
    }
}

/// Character-based token estimates for Japanese source text and English output. Modern tokenizers
/// spend roughly one token per Japanese character, and an English translation runs to about one
/// token per source character as well; vocabulary notes add a fixed budget per sentence.
nonisolated enum TokenEstimator {
    static let japaneseTokensPerChar = 1.1
    static let englishOutputTokensPerSourceChar = 0.9
    static let explanationTokensPerSentence = 70
    static let perItemOverheadTokens = 14

    static func promptTokens(_ text: String) -> Int { max(1, text.count / 4) }

    static func inputTokens(forSentence sentence: String) -> Int {
        Int(Double(sentence.count) * japaneseTokensPerChar) + perItemOverheadTokens
    }

    static func outputTokens(forSentence sentence: String, withExplanation: Bool) -> Int {
        Int(Double(sentence.count) * englishOutputTokensPerSourceChar) + perItemOverheadTokens + (withExplanation ? explanationTokensPerSentence : 0)
    }
}
