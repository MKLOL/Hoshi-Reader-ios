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
//  the cloud path for non-reasoning models; ChatML reasoning models get a stricter final-only wrapper
//  so chain-of-thought never becomes visible UI.
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
import os

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
        /// Approximate visible answer token count so far.
        let tokens: Int
        /// Approximate hidden thinking token count so far. The text itself is never exposed.
        let thinkingTokens: Int
        /// Generation throughput so far ((thinking + answer tokens) ÷ elapsed seconds).
        let tokensPerSecond: Double

        var totalTokens: Int { tokens + thinkingTokens }
    }

    /// Live generation progress, published as each token streams in; `nil` outside a generation.
    private(set) var generationProgress: GenerationProgress?

    /// Tok/s of the most recent generation, or `nil` while idle. Computed from the final streamed
    /// token count / elapsed time in `translate(...)`.
    private(set) var tokensPerSecond: Double?

    /// The id of the currently-resident model, or `nil` if none is loaded.
    private(set) var loadedModelId: String?

    /// Context window cap (clamped against the model's own `contextLength`). Needs to be high enough
    /// for the user-visible 10K answer limit plus prompt/private-thinking overhead when the model
    /// supports it.
    nonisolated private static let contextCap: Int32 = 12288
    /// Hidden reasoning cap for ChatML reasoning models. This gives the model room to reason privately
    /// while forcing it into the final-answer phase before it can consume the context window.
    nonisolated private static let thinkingTokenBudget = 192
    /// Fail-safe cap for `.suppressed`: if a model ignores the empty think block and emits `<think>`
    /// anyway, hide at most one token before force-closing the hidden phase.
    nonisolated private static let suppressedThinkingTokenBudget = 1
#if DEBUG
    nonisolated static var debugThinkingTokenBudget: Int { thinkingTokenBudget }
#endif
    /// Injected into ChatML assistant context after hidden thinking, but not streamed to the UI. This
    /// nudges the visible phase to continue as the answer instead of narrating draft/check steps.
    private static let chatMLResponsePrefix = "The English answer is: "

    private let downloads: ModelDownloadManager
    private let settings: OfflineTranslationSettingsStore

    /// The single resident model, guarded by the serialization gate below.
    private var loaded: LLM?

    /// Serializes load + generation on the main actor so they never overlap or race a delete/swap.
    /// `true` while a load/translate is in flight; followers park in `gateWaiters` and are resumed
    /// FIFO. Staying on the main actor avoids crossing any actor boundary with non-`Sendable` state.
    private var gateBusy = false
    private struct GateWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var gateWaiters: [GateWaiter] = []

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
    private func gateAcquire() async throws {
        try Task.checkCancellation()
        if !gateBusy {
            gateBusy = true
            return
        }
        let waiterId = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gateWaiters.append(GateWaiter(id: waiterId, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelGateWaiter(id: waiterId)
            }
        }
        if Task.isCancelled {
            // Once a waiter resumes, the gate has been handed to this task (gateBusy stays true).
            // If cancellation arrives in that narrow window, release the handoff so later requests
            // are not parked forever.
            gateRelease()
            throw CancellationError()
        }
    }

    /// Releases the gate, waking the next waiter (if any).
    private func gateRelease() {
        if gateWaiters.isEmpty {
            gateBusy = false
        } else {
            gateWaiters.removeFirst().continuation.resume(returning: ())
        }
    }

    private func cancelGateWaiter(id: UUID) {
        guard let index = gateWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = gateWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    // MARK: - Load

    /// Ensures `modelId` is loaded and resident, swapping out a different model if needed. The heavy
    /// `LLM(...)` load runs on a detached background task off the main actor.
    func ensureLoaded(modelId: String) async throws {
        try await gateAcquire()
        defer { gateRelease() }
        try Task.checkCancellation()
        try await loadLocked(modelId: modelId)
    }

    /// Loads `modelId` if it isn't already the resident model. Caller must hold the gate.
    private func loadLocked(modelId: String) async throws {
        try Task.checkCancellation()
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

        // No pre-load RAM guard (removed at the user's request). The old guard compared the small
        // per-app `os_proc_available_memory()` headroom against 1.25× the file size and rejected
        // models the device can actually run — llama.cpp mmaps the GGUF (it isn't all resident at
        // once) and the `com.apple.developer.kernel.increased-memory-limit` entitlement raises the
        // cap. We let the load proceed and rely on iOS to manage memory.

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
        try Task.checkCancellation()
        // The synchronous, memory-heavy load is moved off the main actor. `LLM` isn't `Sendable`,
        // so it travels back to the main actor inside an unchecked box; this is safe because the
        // instance is only ever used here (one resident, main-actor-confined) and its heavy state
        // is the internal `LLMCore` actor.
        let boxed = await Task.detached(priority: .userInitiated) { () -> UncheckedBox<LLM?> in
            UncheckedBox(LLM(
                from: url,
                template: template,
                topK: 20,
                topP: 0.9,
                temp: 0.2,
                repeatPenalty: 1.12,
                maxTokenCount: maxCtx
            ))
        }.value
        if Task.isCancelled {
            boxed.value?.stop()
            status = .idle
            throw CancellationError()
        }
        try Task.checkCancellation()
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
        let thinkingTokens: Int

        /// Compact one-line telemetry footer, e.g. "⚡ 12.3 tok/s · 47 tokens · 3.8 s · on-device".
        /// Mirrors Android `OfflineTranslationResult.debugLine()`.
        var debugLine: String {
            String(format: "⚡ %.1f tok/s · %d answer tokens · %d thinking tokens · %.1f s · on-device",
                   tokensPerSecond, approxTokens, thinkingTokens, elapsedSeconds)
        }
    }

    /// Translates `japaneseText` with the active on-device model, loading it on first use.
    func translate(instruction: String, japaneseText: String) async throws -> Result {
        let model = try resolveActiveModel()
        let templateKind = model.templateKind
        let userContent = Self.buildUserContent(
            instruction: instruction,
            japaneseText: japaneseText,
            template: templateKind
        )

        // ChatML reasoning models can think privately when enabled by the user. The thinking stream
        // is hidden and bounded by `thinkingTokenBudget`; disabling the toggle injects an empty think
        // block through the template (`.suppressed`) so the model goes straight to the answer.
        let privateThinkingEnabled = templateKind == .chatML && settings.usePrivateThinking
        let thinkingMode: ThinkingMode = privateThinkingEnabled ? .enabled : (templateKind == .chatML ? .suppressed : .none)
        let requestedResponseTokenBudget = OfflineTranslationSettingsStore.clampedResponseTokenLimit(
            settings.responseTokenLimit
        )

        // Hold the gate across BOTH the (re)load and the generation so a concurrent delete or model
        // swap can't free the model mid-translation.
        try await gateAcquire()
        defer { gateRelease() }

        try Task.checkCancellation()
        try await loadLocked(modelId: model.id)
        try Task.checkCancellation()
        guard let llm = loaded else {
            throw OfflineLlmError(message: "On-device model is not loaded.")
        }

        status = .generating(modelId: model.id)
        tokensPerSecond = nil
        generationProgress = .init(partialText: "", tokens: 0, thinkingTokens: 0, tokensPerSecond: 0)
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
        // Await the reset so the second translation starts from a clean KV cache instead of racing
        // the previous call's fire-and-forget context clear.
        await llm.prepareTemplateForGeneration()
        await llm.reset()
        await llm.core.setThinkingBudget(Self.thinkingBudget(for: thinkingMode))
        await llm.core.setResponseTokenBudget(1)
        await llm.core.setBlocksCJKOnFirstResponseLine(templateKind == .chatML)
        try Task.checkCancellation()

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
        let responsePrefix = templateKind == .chatML ? Self.chatMLResponsePrefix : ""

        let generationTask = Task.detached(priority: .userInitiated) {
            // Drive generation off the main actor (it's CPU-heavy), exactly where the old
            // `getCompletion` ran. `respond(to:with:)` applies `preprocess` and streams token deltas
            // into the output-builder closure, which republishes a throttled live partial + tok/s on
            // the main actor and stashes the final text in `collected`.
            guard !Task.isCancelled else { return }
            @Sendable func publishProgress(_ snapshot: CollectedOutput.Snapshot, at now: Date) async {
                let visible = Self.visibleStreamingText(snapshot.text, template: templateKind)
                let stableVisible = collectedBox.value.setVisibleText(visible)
                let tps = Self.throughput(tokens: snapshot.totalTokens, since: start, until: now)
                await MainActor.run {
                    self.generationProgress = .init(
                        partialText: stableVisible,
                        tokens: snapshot.tokens,
                        thinkingTokens: snapshot.thinkingTokens,
                        tokensPerSecond: tps
                    )
                }
            }

            @Sendable func publishThinkingCount(_ count: Int) async {
                let snapshot = collectedBox.value.setThinkingTokens(count)
                let now = Date()
                if collectedBox.value.shouldEmitProgress(at: now) {
                    await publishProgress(snapshot, at: now)
                }
            }

            @Sendable func streamFinalAnswer(
                prompt: String,
                thinking: ThinkingMode,
                onThinkingTokenCount: (@Sendable (Int) async -> Void)?
            ) async {
                guard let responseTokenBudget = await Self.applyResponseTokenBudget(
                    requested: requestedResponseTokenBudget,
                    prompt: prompt,
                    thinking: thinking,
                    llm: boxed,
                    collected: collectedBox.value
                ) else { return }
                await boxed.value.core.setThinkingBudget(Self.thinkingBudget(for: thinking))
                await boxed.value.respond(
                    to: prompt,
                    thinking: thinking,
                    responsePrefix: responsePrefix,
                    onThinkingTokenCount: onThinkingTokenCount
                ) { stream in
                    var output = ""
                    var tokens = 0
                    for await delta in stream {
                        if Task.isCancelled {
                            boxed.value.stop()
                            break
                        }
                        output += delta
                        tokens += 1
                        let snapshot = collectedBox.value.setResponse(text: output, tokens: tokens)
                        let now = Date()
                        // Throttle live UI updates (~4/s) like Android's 250 ms progress poll.
                        if collectedBox.value.shouldEmitProgress(at: now) {
                            await publishProgress(snapshot, at: now)
                        }
                    }
                    collectedBox.value.setResponse(text: output, tokens: tokens)
                    return output
                }
                collectedBox.value.setResponseBudget(responseTokenBudget)
            }

            @Sendable func resetForFinalRetry() async {
                collectedBox.value.resetResponse()
                let snapshot = collectedBox.value.snapshot()
                await publishProgress(snapshot, at: Date())
                await boxed.value.prepareTemplateForGeneration()
                await boxed.value.reset()
                await boxed.value.core.setThinkingBudget(Self.thinkingBudget(for: .suppressed))
                await boxed.value.core.setResponseTokenBudget(1)
                await boxed.value.core.setBlocksCJKOnFirstResponseLine(templateKind == .chatML)
            }

            if privateThinkingEnabled {
                let hiddenThinking = await boxed.value.think(
                    to: userContent,
                    onThinkingTokenCount: { count in
                        await publishThinkingCount(count)
                    }
                )
                guard !Task.isCancelled else { return }
                await boxed.value.prepareTemplateForGeneration()
                await boxed.value.reset()
                await boxed.value.core.setThinkingBudget(Self.thinkingBudget(for: .suppressed))
                await boxed.value.core.setResponseTokenBudget(1)
                await boxed.value.core.setBlocksCJKOnFirstResponseLine(templateKind == .chatML)
                let finalPrompt = Self.buildFinalAnswerContent(
                    originalUserContent: userContent,
                    hiddenThinking: hiddenThinking
                )
                await streamFinalAnswer(
                    prompt: finalPrompt,
                    thinking: .suppressed,
                    onThinkingTokenCount: nil
                )
                let firstPassText = Self.cleanup(
                    collectedBox.value.snapshot().text,
                    template: templateKind
                )
                if Self.firstAnswerLineContainsCJK(firstPassText) {
                    await resetForFinalRetry()
                    let fallbackPrompt = Self.buildFinalAnswerContent(
                        originalUserContent: userContent,
                        hiddenThinking: ""
                    )
                    await streamFinalAnswer(
                        prompt: fallbackPrompt,
                        thinking: .suppressed,
                        onThinkingTokenCount: nil
                    )
                }
            } else {
                await streamFinalAnswer(
                    prompt: userContent,
                    thinking: thinkingMode,
                    onThinkingTokenCount: { count in
                        let snapshot = collectedBox.value.setThinkingTokens(count)
                        let now = Date()
                        if collectedBox.value.shouldEmitProgress(at: now) {
                            await publishProgress(snapshot, at: now)
                        }
                    }
                )
            }
        }

        await withTaskCancellationHandler {
            await generationTask.value
        } onCancel: {
            generationTask.cancel()
            boxed.value.stop()
        }
        let elapsed = Date().timeIntervalSince(start)
        try Task.checkCancellation()
        if let errorMessage = collected.errorMessage() {
            throw OfflineLlmError(message: errorMessage)
        }

        let finalOutput = collected.snapshot()
        let text = Self.cleanup(finalOutput.text, template: templateKind)
        guard !text.isEmpty else {
            throw OfflineLlmError(
                message: "The on-device model stopped before producing a final answer. Try again."
            )
        }
        if Self.firstAnswerLineContainsCJK(text) {
            throw OfflineLlmError(
                message: "The on-device model answered in the wrong language. Try again, or turn off private thinking in On-device Translation settings."
            )
        }
        if Self.looksTruncated(text, generatedTokens: finalOutput.tokens, budget: finalOutput.responseBudget) {
            throw OfflineLlmError(
                message: "The on-device model hit the answer limit before finishing. Try again, or turn off private thinking in On-device Translation settings."
            )
        }
        // Live token count = streamed deltas (≈ generated tokens). Guard against a zero count from an
        // empty reply so the footer never shows "0 tokens".
        let approxTokens = max(1, finalOutput.tokens)
        let totalTokens = max(1, finalOutput.totalTokens)
        let tps = elapsed > 0 ? Double(totalTokens) / elapsed : 0
        return Result(text: text, modelId: model.id, tokensPerSecond: tps,
                      elapsedSeconds: elapsed, approxTokens: approxTokens,
                      thinkingTokens: finalOutput.thinkingTokens)
    }

    /// Generation throughput so far: streamed tokens ÷ elapsed seconds (0 if no time has passed).
    /// `nonisolated` so the off-main streaming drive can call it without an actor hop.
    nonisolated private static func throughput(tokens: Int, since start: Date, until now: Date) -> Double {
        let elapsed = now.timeIntervalSince(start)
        return elapsed > 0 ? Double(tokens) / elapsed : 0
    }

    nonisolated private static func thinkingBudget(for mode: ThinkingMode) -> Int {
        switch mode {
        case .enabled:
            thinkingTokenBudget
        case .suppressed:
            suppressedThinkingTokenBudget
        case .none:
            0
        }
    }

    nonisolated private static func applyResponseTokenBudget(
        requested: Int,
        prompt: String,
        thinking: ThinkingMode,
        llm: UncheckedBox<LLM>,
        collected: CollectedOutput
    ) async -> Int? {
        let promptTokenCount = await llm.value.processedPromptTokenCount(for: prompt, thinking: thinking)
        let contextTokenLimit = await llm.value.contextTokenLimit()
        guard let budget = effectiveResponseTokenBudget(
            requested: requested,
            contextTokenLimit: contextTokenLimit,
            promptTokenCount: promptTokenCount,
            hiddenTokenReserve: thinkingBudget(for: thinking)
        ) else {
            collected.setError(
                "The on-device model prompt is too long for the loaded model. Shorten the AI instruction or use a model with a larger context window."
            )
            return nil
        }
        await llm.value.core.setResponseTokenBudget(budget)
        collected.setResponseBudget(budget)
        return budget
    }

    nonisolated private static func effectiveResponseTokenBudget(
        requested: Int,
        contextTokenLimit: Int,
        promptTokenCount: Int,
        hiddenTokenReserve: Int
    ) -> Int? {
        let promptAndSafetyReserve = promptTokenCount + 64
        let available = contextTokenLimit - promptAndSafetyReserve - hiddenTokenReserve
        guard available > 0 else { return nil }
        return min(requested, available)
    }

    /// Builds the prompt sent to the local model. ChatML/Qwen models get a stricter wrapper than the
    /// cloud path because small reasoning models otherwise leak untagged chain-of-thought and may never
    /// produce a final answer.
    nonisolated private static func buildUserContent(
        instruction: String,
        japaneseText: String,
        template: LlmTemplateKind
    ) -> String {
        let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard template == .chatML else {
            return trimmedInstruction.isEmpty ? japaneseText : "\(trimmedInstruction)\n\n\(japaneseText)"
        }

        let fallbackInstruction = "You are a helpful Japanese reading tutor. For the manga speech "
            + "bubble below, give a natural English translation, then a short, concise breakdown "
            + "of any tricky vocabulary or grammar."
        let resolvedInstruction = trimmedInstruction.isEmpty ? fallbackInstruction : trimmedInstruction
        return """
        You are answering a manga OCR translation request. If private thinking is enabled by the
        model template, use it internally only; otherwise answer directly.
        Target language is English. The first line must be an English sentence using Latin letters
        and must contain zero Chinese/Japanese/Korean characters. First-line pattern: English ASCII
        words and punctuation only. Bad: "这是什么？" Good: "What is this?"
        Do not answer in Chinese or Japanese, except when quoting the original Japanese vocabulary
        inside later notes.
        Do not reveal internal reasoning, planning, drafts, chain-of-thought, or self-checking.
        Do not write self-talk such as "wait, let's check" or "looking at the comma".
        The assistant response context already starts with "The English answer is:". Continue with only
        the natural English translation, then concise vocabulary or grammar notes if useful.

        User instructions:
        \(resolvedInstruction)

        Manga text:
        \(japaneseText)
        """
    }

    nonisolated private static func buildFinalAnswerContent(
        originalUserContent: String,
        hiddenThinking: String
    ) -> String {
        let notes = hiddenThinking.trimmingCharacters(in: .whitespacesAndNewlines)
        let privateNotesSection: String
        if notes.isEmpty {
            privateNotesSection = "Private hidden notes: none."
        } else {
            privateNotesSection = """
            Private hidden notes from the previous reasoning pass. Use these only as internal context.
            Do not quote, summarize, mention, or continue these notes in the answer:
            \(notes)
            """
        }
        return """
        \(privateNotesSection)

        English-only examples:
        Japanese: これは何？
        Final answer: What is this?

        Japanese: 待って、これは何？
        Final answer: Wait, what is this?

        Now solve this target request:
        \(originalUserContent)

        Output the final answer only. NO MORE THINKING.
        Target language is English. The first line must be an English sentence using Latin letters
        and must contain zero Chinese/Japanese/Korean characters. First-line pattern: English ASCII
        words and punctuation only. Bad: "这是什么？" Good: "What is this?"
        Do not answer in Chinese or Japanese, except when quoting the original Japanese vocabulary
        inside later notes.
        Do not write drafts, checks, plans, "wait", "let's check", analysis, reasoning, or chain-of-thought.
        Start directly with the natural English translation. Then add concise vocabulary or grammar notes
        only if they help the reader.
        """
    }

    /// Cleans streamed partials before they reach the popup. The response stream is already the
    /// visible phase; only strip accidental leading markers/reasoning, never search backward through
    /// the answer because that can erase valid streamed text.
    nonisolated private static func visibleStreamingText(_ raw: String, template: LlmTemplateKind) -> String {
        let stripped = stripLeadingFinalMarker(AiThinkingTextSanitizer.strip(raw))
        guard template == .chatML else { return stripped }
        let visible = stripLeadingFinalMarker(AiThinkingTextSanitizer.stripUntaggedReasoning(stripped))
        return firstAnswerLineContainsCJK(visible) ? "" : visible
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
    nonisolated private static func cleanup(_ raw: String, template: LlmTemplateKind) -> String {
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
        let stripped = AiThinkingTextSanitizer.strip(text)
        if template == .chatML {
            let withoutMarker = stripLeadingFinalMarker(stripped)
            return stripLeadingFinalMarker(AiThinkingTextSanitizer.stripUntaggedReasoning(withoutMarker))
        }
        return stripped
    }

    nonisolated private static func stripLeadingFinalMarker(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let markers = [
            "final answer:",
            "final:",
            "the english answer is:",
            "english answer:",
            "english translation:",
            "translation:"
        ]
        for marker in markers {
            if let range = trimmed.range(of: marker, options: [.caseInsensitive]),
               range.lowerBound == trimmed.startIndex {
                return String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return trimmed
    }

    nonisolated private static func looksTruncated(_ text: String, generatedTokens: Int, budget: Int) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let terminalCharacters = CharacterSet(charactersIn: ".!?。！？)]}\"'”’")
        if let last = trimmed.unicodeScalars.last, terminalCharacters.contains(last) {
            return false
        }
        let words = trimmed.lowercased().split { scalar in
            !scalar.isLetter && !scalar.isNumber && scalar != "'"
        }
        let danglingWords: Set<Substring> = [
            "but", "and", "or", "because", "that", "which", "to", "of",
            "for", "with", "i", "the", "a", "an"
        ]
        if let last = words.last, danglingWords.contains(last) {
            return true
        }
        return generatedTokens >= max(1, budget - 2)
    }

    nonisolated private static func firstAnswerLineContainsCJK(_ text: String) -> Bool {
        guard let firstLine = text.split(separator: "\n")
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) else {
            return false
        }
        return firstLine.unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(Int(scalar.value)) ||
            (0x3400...0x9FFF).contains(Int(scalar.value)) ||
            (0xF900...0xFAFF).contains(Int(scalar.value))
        }
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
nonisolated private final class CollectedOutput: @unchecked Sendable {
    struct Snapshot: Sendable {
        let text: String
        let tokens: Int
        let thinkingTokens: Int
        let responseBudget: Int

        var totalTokens: Int { tokens + thinkingTokens }
    }

    private let lock = NSLock()
    private var text = ""
    private var tokens = 0
    private var thinkingTokens = 0
    private var responseBudget = 10000
    private var visibleText = ""
    private var lastProgressEmit = Date.distantPast
    private var errorText: String?

    func setError(_ message: String) {
        lock.lock()
        errorText = message
        lock.unlock()
    }

    func errorMessage() -> String? {
        lock.lock()
        let message = errorText
        lock.unlock()
        return message
    }

    @discardableResult
    func setResponse(text: String, tokens: Int) -> Snapshot {
        lock.lock()
        self.text = text
        self.tokens = tokens
        let snapshot = Snapshot(
            text: self.text,
            tokens: self.tokens,
            thinkingTokens: thinkingTokens,
            responseBudget: responseBudget
        )
        lock.unlock()
        return snapshot
    }

    @discardableResult
    func setResponseBudget(_ responseBudget: Int) -> Snapshot {
        lock.lock()
        self.responseBudget = responseBudget
        let snapshot = Snapshot(
            text: text,
            tokens: tokens,
            thinkingTokens: thinkingTokens,
            responseBudget: self.responseBudget
        )
        lock.unlock()
        return snapshot
    }

    @discardableResult
    func setThinkingTokens(_ thinkingTokens: Int) -> Snapshot {
        lock.lock()
        self.thinkingTokens = max(self.thinkingTokens, thinkingTokens)
        let snapshot = Snapshot(
            text: text,
            tokens: tokens,
            thinkingTokens: self.thinkingTokens,
            responseBudget: responseBudget
        )
        lock.unlock()
        return snapshot
    }

    func setVisibleText(_ candidate: String) -> String {
        let visible = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        defer { lock.unlock() }
        guard !visible.isEmpty else { return visibleText }
        if !visibleText.isEmpty {
            if visible.count < visibleText.count, !shouldReplaceVisibleText(with: visible) {
                return visibleText
            }
            if !visible.hasPrefix(visibleText), visibleText.count > 12,
               !shouldReplaceVisibleText(with: visible) {
                return visibleText
            }
        }
        visibleText = visible
        return visibleText
    }

    private func shouldReplaceVisibleText(with candidate: String) -> Bool {
        let current = visibleText.lowercased()
        let next = candidate.lowercased()
        let scaffoldNeedles = [
            "thinking process",
            "reasoning:",
            "analysis:",
            "wait, let's check",
            "wait, lets check",
            "wait, looking",
            "draft breakdown",
            "checking the",
            "looking at the comma"
        ]
        let currentLooksLikeScaffold = scaffoldNeedles.contains { current.contains($0) }
        let nextLooksLikeScaffold = scaffoldNeedles.contains { next.contains($0) }
        if currentLooksLikeScaffold && !nextLooksLikeScaffold {
            return true
        }
        return false
    }

    func resetResponse() {
        lock.lock()
        text = ""
        tokens = 0
        visibleText = ""
        lock.unlock()
    }

    func shouldEmitProgress(at now: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard now.timeIntervalSince(lastProgressEmit) >= 0.25 else { return false }
        lastProgressEmit = now
        return true
    }

    func snapshot() -> Snapshot {
        lock.lock()
        let snapshot = Snapshot(
            text: text,
            tokens: tokens,
            thinkingTokens: thinkingTokens,
            responseBudget: responseBudget
        )
        lock.unlock()
        return snapshot
    }
}
