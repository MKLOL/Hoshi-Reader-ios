//
//  PretranslationPlanner.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Segments a book's chapters exactly the way sentence mode and the desktop pipeline do, so the
//  translations written later match the reader's anchors, and prices the job.
//

import EPUBKit
import Foundation

nonisolated enum PretranslationPlanner {
    static func plan(bookId: UUID, syncId: String, bookRoot: URL, config: PretranslationConfig) throws -> PretranslationPlan {
        // Same parser BookStorage.loadEpub uses, called directly because planning runs off the
        // main actor.
        let document = try EPUBParser().parse(documentAt: bookRoot)
        return plan(bookId: bookId, syncId: syncId, document: document, config: config)
    }

    static func plan(bookId: UUID, syncId: String, document: EPUBDocument, config: PretranslationConfig) -> PretranslationPlan {
        var sentences: [ReaderSentence] = []
        for (spine, item) in document.spine.items.enumerated() {
            guard let manifestItem = document.manifest.items[item.idref] else { continue }
            guard let path = document.resourceURL(for: manifestItem.path) else { continue }
            guard let html = try? String(contentsOf: path, encoding: .utf8) else { continue }
            sentences += EpubSentenceSegmenter.segment(spine: spine, html: html).filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        return PretranslationPlan(
            bookId: bookId,
            syncId: syncId,
            title: document.title ?? "",
            spineCount: document.spine.items.count,
            sentences: sentences,
            estimate: estimate(sentences, config: config)
        )
    }

    static func estimate(_ sentences: [ReaderSentence], config: PretranslationConfig) -> PretranslationEstimate {
        let characters = sentences.reduce(0) { $0 + $1.text.count }
        let perRequest = max(1, config.sentencesPerRequest)
        let requests = sentences.isEmpty ? 0 : (sentences.count + perRequest - 1) / perRequest
        let promptTokens = TokenEstimator.promptTokens(SentenceBatchPrompt.instructions(includeExplanations: config.includeExplanations, customInstructions: config.effectiveInstructions)) * requests
        let inputTokens = promptTokens + sentences.reduce(0) { $0 + TokenEstimator.inputTokens(forSentence: $1.text) }
        let outputTokens = sentences.reduce(0) { $0 + TokenEstimator.outputTokens(forSentence: $1.text, withExplanation: config.includeExplanations) }
        let cost: Double?
        switch config.engine {
        case .cloud(let modelId): cost = ModelPricing.estimateUsd(modelId: modelId, inputTokens: inputTokens, outputTokens: outputTokens)
        case .onDevice: cost = nil
        }
        return PretranslationEstimate(sentenceCount: sentences.count, characterCount: characters, inputTokens: inputTokens, outputTokens: outputTokens, costUsd: cost)
    }
}
