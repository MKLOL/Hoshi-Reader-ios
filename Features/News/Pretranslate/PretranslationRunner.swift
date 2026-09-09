//
//  PretranslationRunner.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Translates a plan's sentences: batches first (a batch that answered but yielded nothing is split
//  in half and retried, which recovers from replies cut off by an output cap), then single retries
//  for whatever is still missing, tolerating a bounded number of failed requests. Results
//  accumulate in a caller-owned sink so a job that is cancelled or gives up can persist what was
//  already paid for.
//

import Foundation

struct PretranslationTooManyFailures: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

nonisolated final class PretranslationSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: SentenceTranslationResult] = [:]

    init(_ initial: [String: SentenceTranslationResult] = [:]) { storage = initial }

    var count: Int { lock.withLock { storage.count } }
    var snapshot: [String: SentenceTranslationResult] { lock.withLock { storage } }
    func contains(_ id: String) -> Bool { lock.withLock { storage[id] != nil } }
    func merge(_ items: [String: SentenceTranslationResult]) { lock.withLock { storage.merge(items) { _, new in new } } }
}

nonisolated struct PretranslationRunner: Sendable {
    let translator: any SentenceTranslating
    let config: PretranslationConfig
    var maxFailedRequests: Int = 6

    /// Fills `sink` with every translation gathered, including the entries of `existing` that belong
    /// to `sentences`. `onProgress` receives the number of sentences translated so far.
    func run(
        sentences: [ReaderSentence],
        existing: [String: SentenceTranslationResult] = [:],
        sink: PretranslationSink,
        onProgress: @Sendable (Int, Int) async -> Void = { _, _ in }
    ) async throws -> [String: SentenceTranslationResult] {
        let ids = Set(sentences.map(\.id))
        sink.merge(existing.filter { ids.contains($0.key) })
        let pending = sentences.filter { !sink.contains($0.id) }
        var failures = 0
        var lastError: Error?
        await onProgress(sink.count, sentences.count)

        func attempt(_ block: () async throws -> Void) async throws {
            do {
                try await block()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures += 1
                lastError = error
                if failures > maxFailedRequests {
                    throw PretranslationTooManyFailures(message: "\(failures) requests failed; last error: \(error.localizedDescription)")
                }
            }
        }

        func translateBatch(_ batch: [ReaderSentence]) async throws {
            try Task.checkCancellation()
            var translated: [String: SentenceTranslationResult] = [:]
            var replied = false
            let batchIds = Set(batch.map(\.id))
            try await attempt {
                translated = try await translator.translateBatch(batch, includeExplanations: config.includeExplanations).filter { batchIds.contains($0.key) }
                replied = true
            }
            sink.merge(translated)
            await onProgress(sink.count, sentences.count)
            // The model answered but nothing usable came back (truncated or malformed reply): halve
            // the batch and retry. A failed request is not split; it already counted against the
            // failure budget. Pairs are not split either: the single pass that follows covers them.
            if replied, translated.isEmpty, batch.count > 2 {
                let half = batch.count / 2
                try await translateBatch(Array(batch[..<half]))
                try await translateBatch(Array(batch[half...]))
            }
        }

        if translator.supportsBatches {
            let size = max(1, config.sentencesPerRequest)
            var index = 0
            while index < pending.count {
                let end = min(pending.count, index + size)
                try await translateBatch(Array(pending[index..<end]))
                index = end
            }
        }
        for sentence in pending where !sink.contains(sentence.id) {
            try Task.checkCancellation()
            try await attempt {
                if let result = try await translator.translateOne(sentence, includeExplanations: config.includeExplanations) {
                    sink.merge([sentence.id: result])
                }
            }
            await onProgress(sink.count, sentences.count)
        }
        if sink.count == 0, !sentences.isEmpty {
            throw PretranslationTooManyFailures(message: "No sentence could be translated" + (lastError.map { ": \($0.localizedDescription)" } ?? ""))
        }
        return sink.snapshot
    }
}
