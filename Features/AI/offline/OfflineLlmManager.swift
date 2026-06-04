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
//  Generation STREAMS: instead of LLM.swift's one-shot `getCompletion`, `translate` drives the
//  streaming `respond(to:with:)` API (an `AsyncStream<String>` of token deltas) and republishes a
//  growing partial string + live tokens/sec via `generationProgress`, so the popup shows the reply
//  forming in real time and a live throughput counter. Mirrors Android `OfflineLlmManager`'s
//  `GenerationProgress` + `LlamaInference.translate(onProgress:)`.
//

import Foundation
import LLM
import UIKit

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

    /// Live progress of the in-flight on-device generation, or `nil` when idle. Updated on every
    /// streamed token delta so the popup can show the reply forming + a live tok/s counter. Mirrors
    /// Android `OfflineLlmManager.GenerationProgress` (a `StateFlow<GenerationProgress?>`).
    struct GenerationProgress: Equatable {
        /// The reply text accumulated so far (raw, before final stop-sequence cleanup).
        let partialText: String
        /// Approximate generated token count so far.
        let tokens: Int
        /// Generation throughput so far (tokens ÷ elapsed seconds).
        let tokensPerSecond: Double
    }

    /// Live generation progress, published as each token streams in; `nil` outside a generation.
    private(set) var generationProgress: GenerationProgress?

    /// Tok/s of the most recent generation, or `nil` while idle. Computed from the final streamed
    /// token count / elapsed time in `translate(...)`.
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

    /// Keeps the memory-warning observer alive for the lifetime of this (singleton) manager.
    private var memoryWarningObserver: NSObjectProtocol?

    init(downloads: ModelDownloadManager = .shared,
         settings: OfflineTranslationSettingsStore = .shared) {
        self.downloads = downloads
        self.settings = settings
        observeMemoryPressure()
    }

    // MARK: - Memory pressure

    /// Frees the resident model under system memory pressure so a loaded multi-GB GGUF doesn't get
    /// the app jetsammed. Skipped while a load/generation holds the gate so we don't yank the model
    /// out from under an in-flight translate.
    private func observeMemoryPressure() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The notification is delivered on the main queue, matching this main-actor type.
            MainActor.assumeIsolated {
                guard let self, !self.gateBusy else { return }
                self.unload()
            }
        }
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

        // Free the outgoing model before loading the new one (one resident at a time). Dropping the
        // `LLM` reference doesn't synchronously free its llama context (the heavy state lives in the
        // `LLMCore` actor, whose deinit runs asynchronously), so a swap (e.g. 3 GB → 9 GB) could
        // momentarily need both resident. Stop any work on the outgoing model, drop our reference,
        // then hop the runloop / yield so its teardown can run before the new heavy load begins.
        // Best-effort: this avoids the double-resident peak in the common case.
        if let outgoing = loaded {
            outgoing.stop()
            loaded = nil
            loadedModelId = nil
            // Let the dropped instance's actor deinit / llama free run before allocating the next.
            await Task.yield()
        }
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
        generationProgress = .init(partialText: "", tokens: 0, tokensPerSecond: 0)
        defer {
            status = loadedModelId.map { .ready(modelId: $0) } ?? .idle
            tokensPerSecond = nil
            generationProgress = nil
        }

        // Reset the model's KV cache / context before each generation so every translate is a fresh
        // one-shot (matches Android's `nativeTranslate`). Without this the resident model accumulates
        // context across calls — bubbles bleed together and, once the context window fills, replies
        // come back empty. `respond(to:with:)` also appends to history, but `reset()` clears it each
        // call so it never grows.
        //
        // `reset()` clears `history` synchronously but schedules `core.resetContext()` (which zeroes
        // the KV cache / token count) on a fire-and-forget `Task`. That reset can otherwise land
        // AFTER `respond(...)` has begun encoding the new prompt — `prepareContext` appends at
        // `pos: currentTokenCount` without zeroing it — so stale KV-context bleeds into the next
        // translation (and, once the window fills, replies come back empty). Make the reset
        // deterministically complete before generation: `reset()` enqueues the `resetContext()` job
        // on `core`; `Task.yield()` lets that fire-and-forget task body run so the job is enqueued on
        // the actor; then awaiting a cheap, read-only `core` method drains the actor's serial queue
        // up to and including that reset before we call `respond(...)`.
        llm.reset()
        await Task.yield()
        _ = await llm.core.getChatTemplateHint()

        // Stream the reply with LLM.swift's `respond(to:with:)`: it applies the template's
        // `preprocess` internally (so an instruct/chat GGUF sees its chat framing), then hands us an
        // `AsyncStream<String>` of token deltas. We accumulate them, republish a throttled live
        // partial + tok/s through `generationProgress`, and return the final text so `respond`
        // records it in (the just-reset) history. The whole drive runs off the main actor inside
        // `respond` → `core` (an actor); the gate guarantees exclusive access to `llm`, so boxing it
        // across the boundary is safe.
        //
        // Cancellation: `MangaAiController.cancel()` cancels the owning task; the streaming drive
        // can't see that, so on cancel we call `stop()` (sets the core's
        // `shouldContinuePredicting = false`) to wind generation down promptly and free the gate.
        let start = Date()
        let boxed = UncheckedBox(llm)
        // Streamed deltas + final count travel back here from the detached drive (a reference type,
        // boxed across the boundary; the gate guarantees exclusive access).
        let collected = CollectedOutput()
        let collectedBox = UncheckedBox(collected)

        await withTaskCancellationHandler {
            // Drive generation off the main actor (it's CPU-heavy), exactly where the old
            // `getCompletion` ran. `respond(to:with:)` applies `preprocess` and streams token deltas
            // into the output-builder closure, which republishes a throttled live partial + tok/s on
            // the main actor and stashes the final text in `collected`.
            await Task.detached(priority: .userInitiated) {
                await boxed.value.respond(to: userContent) { stream in
                    var output = ""
                    var tokens = 0
                    var lastEmit = Date.distantPast
                    for await delta in stream {
                        output += delta
                        tokens += 1
                        // Throttle live UI updates (~4/s) like Android's 250 ms progress poll.
                        let now = Date()
                        if now.timeIntervalSince(lastEmit) >= 0.25 {
                            lastEmit = now
                            let snapshot = output
                            let tokenCount = tokens
                            let tps = Self.throughput(tokens: tokenCount, since: start, until: now)
                            await MainActor.run {
                                self.generationProgress = .init(
                                    partialText: snapshot, tokens: tokenCount, tokensPerSecond: tps
                                )
                            }
                        }
                    }
                    collectedBox.value.text = output
                    collectedBox.value.tokens = tokens
                    return output
                }
            }.value
        } onCancel: {
            boxed.value.stop()
        }
        let elapsed = Date().timeIntervalSince(start)
        try Task.checkCancellation()

        let text = cleanup(collected.text, template: model.templateKind)
        // Live token count = streamed deltas (≈ generated tokens). Guard against a zero count from an
        // empty reply so the footer never shows "0 tokens".
        let approxTokens = max(1, collected.tokens)
        let tps = elapsed > 0 ? Double(approxTokens) / elapsed : 0
        return Result(text: text, modelId: model.id, tokensPerSecond: tps,
                      elapsedSeconds: elapsed, approxTokens: approxTokens)
    }

    /// Generation throughput so far: streamed tokens ÷ elapsed seconds (0 if no time has passed).
    /// `nonisolated` so the off-main streaming drive can call it without an actor hop.
    nonisolated private static func throughput(tokens: Int, since start: Date, until now: Date) -> Double {
        let elapsed = now.timeIntervalSince(start)
        return elapsed > 0 ? Double(tokens) / elapsed : 0
    }

    /// Frees the resident model. Idempotent. Safe to call when nothing is loaded.
    func unload() {
        loaded = nil
        loadedModelId = nil
        status = .idle
        tokensPerSecond = nil
        generationProgress = nil
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

/// Carries the final streamed text + token count out of `respond(to:with:)`'s output-builder closure
/// (whose return value `respond` consumes internally and discards). A reference type so writes inside
/// the escaping closure are visible to the caller after the await; serialized by the gate.
nonisolated private final class CollectedOutput {
    var text = ""
    var tokens = 0
}
