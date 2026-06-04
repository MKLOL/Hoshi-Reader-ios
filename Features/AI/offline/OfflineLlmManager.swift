//
//  OfflineLlmManager.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Owns the single resident on-device LLM and runs translations through it. Ported from Android
//  `features/ai/offline/OfflineLlmManager.translate` + `LlamaInference`.
//
//  Only one model is ever resident (a loaded GGUF is a heavyweight, memory-hungry, process-global
//  resource). Loading is heavy and synchronous in LLM.swift, so it runs on a detached background
//  task — never on the main actor — and both load and generation are serialized through an internal
//  async gate so a delete/model-swap can't free the model mid-translation. The user content mirrors
//  the cloud path: `japaneseText` alone when the instruction is blank, else "<instruction>\n\n<text>".
//

import Foundation
import LLM

/// Thrown when an on-device model can't be used; `message` is safe to show the user.
struct OfflineLlmError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@Observable
@MainActor
final class OfflineLlmManager {
    static let shared = OfflineLlmManager()

    /// Coarse lifecycle of the resident model, surfaced to the UI.
    enum Status: Equatable {
        case idle
        case loading(modelId: String)
        case ready(modelId: String)
        case generating(modelId: String)
    }

    private(set) var status: Status = .idle

    /// Live tok/s of the in-flight generation, or `nil` when idle. Updated from a poller while the
    /// generation runs (LLM.swift's `getCompletion` doesn't expose per-token callbacks here).
    private(set) var tokensPerSecond: Double?

    /// The id of the currently-resident model, or `nil` if none is loaded.
    private(set) var loadedModelId: String?

    /// Context window cap (clamped against the model's own `contextLength`). Matches Android; this
    /// also bounds generation length (llama.cpp stops at the context limit or the model's EOG token,
    /// whichever comes first — a translate-only model stops well before this).
    private static let contextCap: Int32 = 2048

    private let downloads: ModelDownloadManager
    private let settings: OfflineTranslationSettingsStore

    /// The single resident model, guarded by the serialization gate below.
    private var loaded: LLM?

    /// Serializes load + generation on the main actor so they never overlap or race a delete/swap.
    /// `true` while a load/translate is in flight; followers park in `gateWaiters` and are resumed
    /// FIFO. Staying on the main actor avoids crossing any actor boundary with non-`Sendable` state.
    private var gateBusy = false
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []

    init(downloads: ModelDownloadManager = .shared,
         settings: OfflineTranslationSettingsStore = .shared) {
        self.downloads = downloads
        self.settings = settings
    }

    // MARK: - Serialization gate

    /// Acquires the gate, parking FIFO if another operation holds it.
    private func gateAcquire() async {
        if !gateBusy {
            gateBusy = true
            return
        }
        await withCheckedContinuation { gateWaiters.append($0) }
    }

    /// Releases the gate, waking the next waiter (if any).
    private func gateRelease() {
        if gateWaiters.isEmpty {
            gateBusy = false
        } else {
            gateWaiters.removeFirst().resume()
        }
    }

    // MARK: - Load

    /// Ensures `modelId` is loaded and resident, swapping out a different model if needed. The heavy
    /// `LLM(...)` load runs on a detached background task off the main actor.
    func ensureLoaded(modelId: String) async throws {
        await gateAcquire()
        defer { gateRelease() }
        try await loadLocked(modelId: modelId)
    }

    /// Loads `modelId` if it isn't already the resident model. Caller must hold the gate.
    private func loadLocked(modelId: String) async throws {
        if loadedModelId == modelId, loaded != nil { return }

        guard let model = LlmModelCatalog.byId(modelId) else {
            throw OfflineLlmError(message: "Unknown on-device model.")
        }
        guard downloads.isDownloaded(model), let url = downloads.fileURL(for: model) else {
            throw OfflineLlmError(
                message: "On-device model isn't downloaded yet. Download it in Settings → "
                    + "On-device translation."
            )
        }

        // Free the outgoing model before loading the new one (one resident at a time).
        loaded = nil
        loadedModelId = nil
        status = .loading(modelId: modelId)

        let template = model.llmTemplate
        let maxCtx = min(Self.contextCap, model.contextLength)
        // The synchronous, memory-heavy load is moved off the main actor. `LLM` isn't `Sendable`,
        // so it travels back to the main actor inside an unchecked box; this is safe because the
        // instance is only ever used here (one resident, main-actor-confined) and its heavy state
        // is the internal `LLMCore` actor.
        let boxed = await Task.detached(priority: .userInitiated) { () -> UncheckedBox<LLM?> in
            UncheckedBox(LLM(from: url, template: template, maxTokenCount: maxCtx))
        }.value
        let llm = boxed.value

        guard let llm else {
            status = .idle
            throw OfflineLlmError(message: "Failed to load the on-device model. It may be corrupt — "
                + "delete and re-download it.")
        }
        loaded = llm
        loadedModelId = modelId
        status = .ready(modelId: modelId)
    }

    // MARK: - Translate

    /// Result of one on-device translation plus its perf metrics.
    struct Result {
        let text: String
        let modelId: String
        let tokensPerSecond: Double
        let elapsedSeconds: Double
        let approxTokens: Int

        /// Compact one-line telemetry footer, e.g. "⚡ 12.3 tok/s · 47 tokens · 3.8 s · on-device".
        /// Mirrors Android `OfflineTranslationResult.debugLine()`.
        var debugLine: String {
            String(format: "⚡ %.1f tok/s · %d tokens · %.1f s · on-device",
                   tokensPerSecond, approxTokens, elapsedSeconds)
        }
    }

    /// Translates `japaneseText` with the active on-device model, loading it on first use.
    ///
    /// The user content mirrors `OpenAiChatClient.buildRequestBody`: `japaneseText` alone when
    /// `instruction` is blank, otherwise "<instruction>\n\n<text>".
    func translate(instruction: String, japaneseText: String) async throws -> Result {
        let model = try resolveActiveModel()
        let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let userContent = trimmedInstruction.isEmpty
            ? japaneseText
            : "\(trimmedInstruction)\n\n\(japaneseText)"

        // Hold the gate across BOTH the (re)load and the generation so a concurrent delete or model
        // swap can't free the model mid-translation.
        await gateAcquire()
        defer { gateRelease() }

        try await loadLocked(modelId: model.id)
        guard let llm = loaded else {
            throw OfflineLlmError(message: "On-device model is not loaded.")
        }

        status = .generating(modelId: model.id)
        tokensPerSecond = nil
        defer {
            status = loadedModelId.map { .ready(modelId: $0) } ?? .idle
            tokensPerSecond = nil
        }

        // getCompletion() skips the template's preprocess; apply it ourselves so an instruct/
        // chat GGUF sees its expected chat framing instead of a bare prompt.
        let processed = llm.preprocess(userContent, llm.history, .none)

        // Generate off the main actor (it's CPU-heavy). `llm` isn't `Sendable`, but the gate
        // guarantees exclusive access for the duration of this call, so it's safe to box across.
        let start = Date()
        let boxed = UncheckedBox(llm)
        let raw = await Task.detached(priority: .userInitiated) {
            await boxed.value.getCompletion(from: processed)
        }.value
        let elapsed = Date().timeIntervalSince(start)

        let text = cleanup(raw, template: model.templateKind)
        let approxTokens = max(1, text.split(whereSeparator: { $0 == " " || $0 == "\n" }).count)
        let tps = elapsed > 0 ? Double(approxTokens) / elapsed : 0
        return Result(text: text, modelId: model.id, tokensPerSecond: tps,
                      elapsedSeconds: elapsed, approxTokens: approxTokens)
    }

    /// Frees the resident model. Idempotent. Safe to call when nothing is loaded.
    func unload() {
        loaded = nil
        loadedModelId = nil
        status = .idle
        tokensPerSecond = nil
    }

    // MARK: - Helpers

    /// Resolves which model to translate with: the settings choice if downloaded, else the first
    /// downloaded catalog model. Throws if nothing is downloaded.
    private func resolveActiveModel() throws -> LlmModel {
        let preferred = settings.selectedModel
        if downloads.isDownloaded(preferred) { return preferred }
        if let firstId = downloads.downloadedModelIds().first, let model = LlmModelCatalog.byId(firstId) {
            return model
        }
        throw OfflineLlmError(
            message: "No on-device model downloaded yet. Download one in Settings → On-device "
                + "translation."
        )
    }

    /// Trims template residue the generation may leave (a trailing stop sequence the model emitted
    /// before EOG), plus whitespace.
    private func cleanup(_ raw: String, template: LlmTemplateKind) -> String {
        var text = raw
        let stops: [String]
        switch template {
        case .gemma: stops = ["<end_of_turn>", "<eos>"]
        case .chatML: stops = ["<|im_end|>", "<|endoftext|>"]
        }
        for stop in stops {
            if let range = text.range(of: stop) {
                text = String(text[..<range.lowerBound])
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Transfers a non-`Sendable` value across a concurrency boundary. Used to move the freshly-loaded
/// `LLM` out of the detached load task; safe here because the model is only ever touched on the
/// main actor afterward.
nonisolated private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
