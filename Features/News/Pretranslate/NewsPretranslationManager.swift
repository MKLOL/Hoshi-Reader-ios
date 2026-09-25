//
//  NewsPretranslationManager.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Process-wide queue of pre-translation jobs and their states. Jobs run one at a time (the cloud
//  clients have no rate limiting and the on-device model is strictly serial) inside a Task that
//  holds a UIKit background task, so leaving the app mid-job gives it the platform's grace period
//  instead of stopping it instantly. Partial results are written (and uploaded when sync is
//  configured) when a job fails or is cancelled, unless a sidecar from another model or prompt,
//  partial or complete, already exists.
//

import Foundation
import UIKit

struct PretranslationRequest: Equatable {
    let bookId: UUID
    let articleId: String
    let title: String
    let config: PretranslationConfig
}

@Observable
@MainActor
final class NewsPretranslationManager {
    static let shared = NewsPretranslationManager()

    /// Job state per book id.
    private(set) var jobs: [UUID: PretranslationJobState] = [:]

    private var queue: [PretranslationRequest] = []
    private var current: (request: PretranslationRequest, task: Task<Void, Never>)?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    func enqueue(_ request: PretranslationRequest) {
        if queue.contains(where: { $0.bookId == request.bookId }) || current?.request.bookId == request.bookId { return }
        queue.append(request)
        jobs[request.bookId] = .queued
        drainIfIdle()
    }

    func cancel(bookId: UUID) {
        if let index = queue.firstIndex(where: { $0.bookId == bookId }) {
            queue.remove(at: index)
            jobs[bookId] = .cancelled(savedTranslations: 0)
        }
        if let current, current.request.bookId == bookId {
            // The in-flight request cannot be interrupted; tell the UI the stop is on its way.
            if case .running(let completed, let total, let label, _) = jobs[bookId] {
                jobs[bookId] = .running(completed: completed, total: total, engineLabel: label, cancelling: true)
            }
            current.task.cancel()
        }
    }

    /// Forgets a terminal state so the tab stops showing it.
    func dismiss(bookId: UUID) {
        if jobs[bookId]?.isActive == false { jobs.removeValue(forKey: bookId) }
    }

    private func drainIfIdle() {
        guard current == nil, !queue.isEmpty else { return }
        let request = queue.removeFirst()
        beginBackgroundTask()
        let task = Task { [weak self] in
            await self?.execute(request)
            self?.current = nil
            self?.drainIfIdle()
        }
        current = (request, task)
    }

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "news-pretranslation") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func publish(_ bookId: UUID, _ state: PretranslationJobState) {
        // A cancel request already marked the running state; keep that flag.
        if case .running(let completed, let total, let label, _) = state,
           case .running(_, _, _, let cancelling) = jobs[bookId], cancelling {
            jobs[bookId] = .running(completed: completed, total: total, engineLabel: label, cancelling: true)
        } else {
            jobs[bookId] = state
        }
    }

    private func execute(_ request: PretranslationRequest) async {
        defer { if queue.isEmpty { endBackgroundTask() } }
        let bookId = request.bookId
        let label = request.config.engine.label
        let promptId = SentenceBatchPrompt.promptId(includeExplanations: request.config.includeExplanations, customInstructions: request.config.effectiveInstructions)
        let sink = PretranslationSink()
        var plan: PretranslationPlan?
        var root: URL?
        var existingCount = 0

        /// Keeps what was already paid for when a job stops early: writes (and, when sync is
        /// configured, uploads) the entries in the sink. A complete sidecar produced with another
        /// model or prompt is never replaced by a partial one. Returns how many new entries were saved.
        func persistPartial() async -> Int {
            guard let plan, let root, sink.count > existingCount else { return 0 }
            if SentenceTranslationsWriter.hasSidecarForOtherConfiguration(bookRoot: root, syncId: plan.syncId, model: label, promptId: promptId) { return 0 }
            let blob = SentenceTranslationsWriter.buildBlob(plan: plan, translations: sink.snapshot, model: label, promptId: promptId)
            guard SentenceTranslationsWriter.validationError(blob) == nil, let data = try? SentenceTranslationsWriter.encode(blob) else { return 0 }
            do { try SentenceTranslationsWriter.write(data, bookRoot: root) } catch { return 0 }
            let config = HttpSyncSettingsStore.shared.currentConfig()
            if config.isConfigured {
                // This runs inside a job that may already be cancelled, and a cancelled Task fails
                // URLSession immediately; an unstructured Task is not cancelled with its creator.
                let syncId = plan.syncId
                let transport = HttpSyncKvClient(baseURL: config.baseURL, bearerToken: config.token)
                _ = await Task { try? await SentenceTranslationsUploader(transport: transport).upload(syncId: syncId, blob: data) }.value
            }
            return sink.count - existingCount
        }

        do {
            guard let book = ((try? BookStorage.loadAllBooks()) ?? []).first(where: { $0.id == bookId }), let folder = book.folder else {
                throw PretranslationFailure("The article is no longer on the shelf.")
            }
            let bookRoot = try BookStorage.getBooksDirectory().appendingPathComponent(folder, isDirectory: true)
            root = bookRoot
            guard let bookSyncId = syncId(for: book) else { throw PretranslationFailure("The article has no sync identity.") }
            let config = request.config.withEffectiveBatchSize()
            let translator: any SentenceTranslating
            switch config.engine {
            case .cloud(let modelId):
                let provider = ChatModelCatalog.provider(forModelId: modelId)
                let apiKey = AiChatSettingsStore.shared.apiKey(for: provider)
                guard !apiKey.isEmpty else { throw PretranslationFailure("Add a \(provider.displayName) API key in Settings › AI before starting.") }
                translator = CloudSentenceTranslator(provider: provider, apiKey: apiKey, modelId: modelId, customInstructions: config.effectiveInstructions)
            case .onDevice(let modelId):
                // The offline manager always runs the model selected in settings.
                let selected = OfflineTranslationSettingsStore.shared.selectedModel
                guard selected.id == modelId, ModelDownloadManager.shared.isDownloaded(selected) else {
                    throw PretranslationFailure("Select and download \(modelId) as the offline translation model in Settings first.")
                }
                translator = OnDeviceSentenceTranslator()
            }
            let built = try await Task.detached { try PretranslationPlanner.plan(bookId: bookId, syncId: bookSyncId, bookRoot: bookRoot, config: config) }.value
            plan = built
            guard !built.sentences.isEmpty else { throw PretranslationFailure("The article has no sentences to translate.") }
            let existing = SentenceTranslationsWriter.existingTranslations(bookRoot: bookRoot, plan: built, model: label, promptId: promptId)
            existingCount = existing.count
            publish(bookId, .running(completed: existing.count, total: built.sentences.count, engineLabel: label, cancelling: false))
            let runner = PretranslationRunner(translator: translator, config: config)
            let translations = try await runner.run(sentences: built.sentences, existing: existing, sink: sink) { done, total in
                await MainActor.run { self.publish(bookId, .running(completed: done, total: total, engineLabel: label, cancelling: false)) }
            }
            let blob = SentenceTranslationsWriter.buildBlob(plan: built, translations: translations, model: label, promptId: promptId)
            if let error = SentenceTranslationsWriter.validationError(blob) { throw PretranslationFailure("The translations could not be saved: \(error)") }
            let data = try SentenceTranslationsWriter.encode(blob)
            guard try SentenceTranslationsWriter.writeResult(blob, sentenceCount: built.sentences.count, bookRoot: bookRoot) else {
                throw PretranslationFailure("The replacement is incomplete. Your previous translations were kept.")
            }

            var uploaded = false
            let syncConfig = HttpSyncSettingsStore.shared.currentConfig()
            let uploadAttempted = syncConfig.isConfigured
            if syncConfig.isConfigured {
                publish(bookId, .uploading)
                let transport = HttpSyncKvClient(baseURL: syncConfig.baseURL, bearerToken: syncConfig.token)
                if (try? await SentenceTranslationsUploader(transport: transport).upload(syncId: bookSyncId, blob: data)) != nil { uploaded = true }
            }
            NewsStore.shared.recordTranslation(
                articleId: request.articleId,
                record: NewsTranslationRecord(model: label, sentenceCount: built.sentences.count, translatedCount: translations.count, completedAt: nowEpochMillis(), uploaded: uploaded)
            )
            publish(bookId, .finished(translated: translations.count, total: built.sentences.count, uploadAttempted: uploadAttempted, uploaded: uploaded, engineLabel: label))
        } catch is CancellationError {
            let saved = await persistPartial()
            publish(bookId, .cancelled(savedTranslations: saved))
        } catch let failure as PretranslationFailure {
            let saved = await persistPartial()
            publish(bookId, .failed(message: failure.message, savedTranslations: saved))
        } catch let failure as PretranslationTooManyFailures {
            let saved = await persistPartial()
            publish(bookId, .failed(message: "Too many requests failed. \(failure.message)", savedTranslations: saved))
        } catch {
            let saved = await persistPartial()
            publish(bookId, .failed(message: error.localizedDescription, savedTranslations: saved))
        }
    }
}

struct PretranslationFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
