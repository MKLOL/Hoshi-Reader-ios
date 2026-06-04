//
//  MangaAiController.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Drives the manga ChatGPT popup: takes a speech-bubble OCR string (or an image crop), builds an
//  optional Yomitan-style dictionary lookup context, calls OpenAI, persists the exchange to the
//  per-book `ai_chat_log.json`, and exposes the result/loading/error state to the popup.
//
//  Ported from the Android reader's ChatGPT view-model glue plus
//  features/ai/AiChatDictionaryLookupBuilder.kt. `onEntryPersisted` is the sync push hook wired by
//  the orchestrator (it forwards the new entry to the HTTP KV chat writer).
//

import Foundation
import SwiftUI
import CHoshiDicts

@Observable
@MainActor
final class MangaAiController {
    enum State: Equatable {
        case idle
        case loading(bubbleText: String)
        case result(AiChatEntry)
        case error(String)

        /// The bubble text the popup is about, for the loading/error header.
        var bubbleText: String {
            switch self {
            case .idle: return ""
            case .loading(let text): return text
            case .result(let entry): return entry.bubbleText
            case .error: return ""
            }
        }
    }

    /// The current popup state. `idle` means the popup is hidden.
    private(set) var state: State = .idle
    /// True while the popup should be presented (any non-idle state).
    var isPresented: Bool { state != .idle }

    /// Called after an exchange is appended to disk — the orchestrator wires this to the HTTP KV
    /// chat push so the new entry syncs to other devices.
    var onEntryPersisted: ((BookMetadata, AiChatEntry) -> Void)?

    private let settings: AiChatSettingsStore
    private let client: OpenAiChatClient
    private let history: AiChatHistoryStore
    private var task: Task<Void, Never>?
    /// Replays the last request for the popup's Retry button (the original bubble text or image
    /// crop is captured here; `State.error` carries no payload to reconstruct it from).
    private var lastRequest: (() -> Void)?

    init(settings: AiChatSettingsStore = .shared,
         client: OpenAiChatClient = OpenAiChatClient(),
         history: AiChatHistoryStore = .shared) {
        self.settings = settings
        self.client = client
        self.history = history
    }

    // MARK: - Requests

    /// Asks ChatGPT about a speech-bubble OCR string. Builds a dictionary lookup context from the
    /// bubble (best-effort), runs the request, persists the exchange, and updates `state`.
    func ask(bubbleText: String, book: BookMetadata) {
        let trimmed = bubbleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastRequest = { [weak self] in self?.ask(bubbleText: trimmed, book: book) }
        let apiKey = settings.apiKey
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state = .error("Set your OpenAI API key in Settings → ChatGPT.")
            return
        }
        let model = settings.model
        let prompt = settings.promptText
        // The lookup engine is synchronous and main-actor-friendly; capture the context up front so
        // the background request closure stays free of UI state.
        let lookup = Self.buildDictionaryLookup(query: trimmed)

        cancel()
        state = .loading(bubbleText: trimmed)
        task = Task { [client] in
            do {
                let response = try await client.complete(
                    apiKey: apiKey, model: model, prompt: prompt, bubbleText: trimmed
                )
                if Task.isCancelled { return }
                let entry = AiChatEntry(
                    bubbleText: trimmed,
                    prompt: prompt,
                    model: model,
                    response: response,
                    timestampSeconds: Date().timeIntervalSinceReferenceDate,
                    dictionaryLookup: lookup
                )
                self.persist(entry, book: book)
                if Task.isCancelled { return }
                self.state = .result(entry)
            } catch {
                if Task.isCancelled { return }
                self.state = .error(Self.message(for: error))
            }
        }
    }

    /// Translates an image crop (rendered manga panel) via the vision endpoint, persists the
    /// exchange with the screenshot attached, and updates `state`.
    func translateCrop(image: AiChatImage, book: BookMetadata) {
        lastRequest = { [weak self] in self?.translateCrop(image: image, book: book) }
        let apiKey = settings.apiKey
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state = .error("Set your OpenAI API key in Settings → ChatGPT.")
            return
        }
        let model = settings.model
        let prompt = settings.imagePromptText
        let label = "Screenshot translation"

        cancel()
        state = .loading(bubbleText: label)
        task = Task { [client] in
            do {
                let response = try await client.completeImage(
                    apiKey: apiKey, model: model, prompt: prompt, image: image
                )
                if Task.isCancelled { return }
                let entry = AiChatEntry(
                    bubbleText: label,
                    prompt: prompt,
                    model: model,
                    response: response,
                    timestampSeconds: Date().timeIntervalSinceReferenceDate,
                    screenshotImage: image
                )
                self.persist(entry, book: book)
                if Task.isCancelled { return }
                self.state = .result(entry)
            } catch {
                if Task.isCancelled { return }
                self.state = .error(Self.message(for: error))
            }
        }
    }

    /// Re-runs the most recent request (the popup's Retry button). No-op if there's nothing to retry.
    func retry() {
        lastRequest?()
    }

    /// Cancels any in-flight request without dismissing the popup.
    func cancel() {
        task?.cancel()
        task = nil
    }

    /// Dismisses the popup and cancels any in-flight request.
    func dismiss() {
        cancel()
        state = .idle
    }

    // MARK: - Persistence

    private func persist(_ entry: AiChatEntry, book: BookMetadata) {
        guard let folder = book.folder else { return }
        let (_, added) = history.append(entry, folder: folder)
        // Only fire the sync hook if the entry was actually new (append dedupes by content).
        if added { onEntryPersisted?(book, entry) }
    }

    private static func message(for error: Error) -> String {
        if let openAi = error as? OpenAiError { return openAi.message }
        return error.localizedDescription
    }

    // MARK: - Dictionary lookup context builder
    //
    // Ported from Android features/ai/AiChatDictionaryLookupBuilder.kt. Builds a compact
    // Yomitan-style lookup snapshot from the bubble text so the stored exchange (and its synced
    // blob) carries dictionary context for the history browser even offline.

    private static let maxResults = 3
    private static let glossariesPerResult = 4

    /// Builds a compact dictionary lookup for `query`, trying the whole bubble then progressively
    /// narrower Japanese spans. Returns `nil` if nothing matched (or the engine isn't ready).
    static func buildDictionaryLookup(query: String) -> AiChatDictionaryLookup? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for candidate in candidateLookupQueries(trimmed) {
            let results = LookupEngine.shared.lookup(candidate, maxResults: maxResults, scanLength: 16)
            if let snapshot = toDictionaryLookup(results, query: candidate) {
                return snapshot
            }
        }
        return nil
    }

    private static func toDictionaryLookup(_ results: [LookupResult], query: String) -> AiChatDictionaryLookup? {
        let compact = results.prefix(maxResults).map(toResult)
        if compact.isEmpty { return nil }
        return AiChatDictionaryLookup(query: query, results: Array(compact))
    }

    private static func toResult(_ result: LookupResult) -> AiChatDictionaryLookupResult {
        let trace = result.trace.reversed().map {
            AiChatDeinflectionStep(name: String($0.name), description: String($0.description))
        }
        let glossaries = result.term.glossaries.prefix(glossariesPerResult).map {
            AiChatGlossary(
                dictionary: String($0.dict_name),
                content: String($0.glossary),
                definitionTags: String($0.definition_tags),
                termTags: String($0.term_tags)
            )
        }
        let frequencies = result.term.frequencies.map { group in
            AiChatFrequencyGroup(
                dictionary: String(group.dict_name),
                frequencies: group.frequencies.map {
                    AiChatFrequency(value: Int($0.value), displayValue: String($0.display_value))
                }
            )
        }
        let pitches = result.term.pitches.map { group -> AiChatPitchGroup in
            var positions: [Int] = []
            for element in group.pitch_positions {
                let position = Int(element)
                if !positions.contains(position) { positions.append(position) }
            }
            return AiChatPitchGroup(dictionary: String(group.dict_name), pitchPositions: positions)
        }
        let rules = String(result.term.rules).split(separator: " ").map(String.init)
        return AiChatDictionaryLookupResult(
            expression: String(result.term.expression),
            reading: String(result.term.reading),
            matched: String(result.matched),
            deinflectionTrace: trace,
            glossaries: Array(glossaries),
            frequencies: frequencies,
            pitches: pitches,
            rules: rules
        )
    }

    /// Candidate lookup queries: the whole string first, then each maximal run of Japanese
    /// characters (trimmed of non-Japanese edges). Order-preserving and de-duplicated.
    static func candidateLookupQueries(_ text: String) -> [String] {
        var candidates: [String] = []
        var seen = Set<String>()
        func add(_ s: String) {
            guard !s.isEmpty, !seen.contains(s) else { return }
            seen.insert(s)
            candidates.append(s)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        add(trimmed)

        let chars = Array(text)
        var start: Int? = nil
        func flush(_ end: Int) {
            if let s = start, end > s {
                let span = String(chars[s..<end]).trimmingJapaneseLookupEdges()
                add(span)
            }
            start = nil
        }
        for (index, ch) in chars.enumerated() {
            if ch.isJapaneseLookupChar {
                if start == nil { start = index }
            } else {
                flush(index)
            }
        }
        flush(chars.count)
        return candidates
    }
}

private extension Character {
    /// Hiragana, katakana, CJK ideographs, and the iteration/long-vowel marks Yomitan treats as
    /// part of a word. Mirrors Android `isJapaneseLookupChar`.
    var isJapaneseLookupChar: Bool {
        if self == "ー" || self == "々" || self == "〆" || self == "〤" { return true }
        for scalar in unicodeScalars {
            let v = scalar.value
            let isJapanese =
                (0x3040...0x309F).contains(v) ||   // Hiragana
                (0x30A0...0x30FF).contains(v) ||   // Katakana
                (0x31F0...0x31FF).contains(v) ||   // Katakana phonetic extensions
                (0x3400...0x4DBF).contains(v) ||   // CJK Ext A
                (0x4E00...0x9FFF).contains(v) ||   // CJK Unified Ideographs
                (0xF900...0xFAFF).contains(v) ||   // CJK Compatibility Ideographs
                (0x20000...0x2A6DF).contains(v)    // CJK Ext B
            if !isJapanese { return false }
        }
        return true
    }
}

private extension String {
    /// Trims leading/trailing characters that aren't Japanese-lookup characters.
    func trimmingJapaneseLookupEdges() -> String {
        let chars = Array(self)
        var lo = 0
        var hi = chars.count
        while lo < hi, !chars[lo].isJapaneseLookupChar { lo += 1 }
        while hi > lo, !chars[hi - 1].isJapaneseLookupChar { hi -= 1 }
        return String(chars[lo..<hi])
    }
}
