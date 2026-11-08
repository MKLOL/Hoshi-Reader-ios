//
//  HttpSyncManager.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Top-level entry point for the v2 KV HTTP sync. Owns:
//   - syncNow(): a full bidirectional reconcile (the "Sync now" button), advancing the cursor.
//   - onPageTurnPersisted(book:): durable bookmark-map write batched within five seconds.
//   - onChatEntryPersisted(book:entry:): fire-and-forget single chat PUT after a chat reply save.
//
//  Bookmark exchange and chat push are gated by HttpSyncSettingsStore.enabled and never throw
//  to the caller — a 401 / offline / 5xx must never affect the reader UI. syncNow() also never
//  throws; failures land in HttpSyncResult.errors and lastError.
//

import Foundation
import CryptoKit
import os
import UIKit

@Observable
@MainActor
final class HttpSyncManager {
    static let shared = HttpSyncManager()

    /// Sync diagnostics. Inspect on a connected device with:
    ///   log stream --predicate 'subsystem == "com.dragosristache.hoshi" && category == "HttpSync"'
    /// or in Console.app filtered to the Hoshi Reader process. Errors are logged at .error so they
    /// survive in the persistent log store even when the app isn't attached to a debugger.
    private let log = Logger(subsystem: "com.dragosristache.hoshi", category: "HttpSync")

    /// True while a `syncNow()` reconcile is in flight (drives the settings screen spinner).
    private(set) var isSyncing = false
    /// Live phased progress for the in-flight reconcile, or nil when idle. Updated on the main
    /// actor as the reconciler streams `HttpSyncProgress` updates; drives the settings screen's
    /// linear progress bar + phase label. Mirrors Android's `SyncStatus.Running(progress)`.
    private(set) var progress: HttpSyncProgress?
    private(set) var transferProgress: HttpSyncTransferProgress?
    private var transferMeter = HttpSyncTransferMeter()
    private var cancellationGeneration: UInt64 = 0
    /// One-line summary of the last successful reconcile, or nil if none yet.
    private(set) var lastStatus: String?
    /// Last fatal error string (e.g. not configured / transport build failure), or nil.
    private(set) var lastError: String?
    /// Per-key errors collected by the last reconcile, surfaced for a "details" disclosure.
    private(set) var lastErrors: [String] = []

    private(set) var tokenRejected = false
    private var readerPreferencesTask: Task<Void, Never>?

    private let settings: HttpSyncSettingsStore
    private let batchState = HttpSyncBatchState.shared
    /// Agent C makes `AiChatSettingsStore` conform to `AiSettingsSyncing` in Phase 2 and assigns
    /// it here (or via the initializer). Until then this is nil and the AI-settings sync path is
    /// skipped — every other sync path is unaffected.
    var aiSettings: AiSettingsSyncing?

    /// Serializes manual reconciles against each other (a second "Sync now" tap while one is in
    /// flight just no-ops). Fire-and-forget pushes are independent.
    private var reconcileTask: Task<Void, Never>?
    private var reconcileTaskId: UUID?
    private var bookmarkSyncTask: Task<Void, Never>?
    private var pollID = UUID()
    private var foreground = true
    private var mapExchangeTask: Task<HttpSyncMapChanges?, Never>?
    private var mapExchangeTaskId: UUID?
    private var fullRetryDeferredForReader = false
    private var fullRetryAfter: Date?

    init(settings: HttpSyncSettingsStore? = nil, aiSettings: AiSettingsSyncing? = nil) {
        self.settings = settings ?? HttpSyncSettingsStore.shared
        // Default to the app's ChatGPT settings store so model/prompt sync works out of the box;
        // tests can inject a stub.
        self.aiSettings = aiSettings ?? AiChatSettingsStore.shared
    }

    // MARK: - Manual reconcile

    /// Runs one full reconcile pass. Safe to call repeatedly; a concurrent call awaits the
    /// in-flight one. Never throws.
    func syncNow() async {
        let generation = cancellationGeneration
        // A manual refresh must inspect state that arrived after an older background snapshot.
        if let previous = reconcileTask {
            let previousID = reconcileTaskId
            await previous.value
            if reconcileTaskId == previousID { reconcileTask = nil; reconcileTaskId = nil }
        }
        if let mapExchangeTask {
            _ = await mapExchangeTask.value
        }
        guard generation == cancellationGeneration else { return }
        await beginReconcile(preflight: nil).value
    }

    func cancelSync() {
        HttpSyncCloudBooks.shared.withdrawRequests()
        cancellationGeneration &+= 1
        reconcileTask?.cancel()
        mapExchangeTask?.cancel()
        fullRetryAfter = Date().addingTimeInterval(60)
        lastStatus = "Sync cancelled. Interrupted downloads can resume next time."
        lastError = nil
        lastErrors = []
    }

    func interruptedDownloadSummary() async -> HttpSyncDownloadCache.Summary {
        guard let books = try? BookStorage.getBooksDirectory() else { return .init() }
        return await HttpSyncBackgroundDownloads.shared.interruptedSummary(books: books)
    }

    func cleanInterruptedDownloads() async -> Int {
        guard let books = try? BookStorage.getBooksDirectory() else { return 0 }
        return await HttpSyncBackgroundDownloads.shared.cleanDownloads(books: books, olderThan: Date())
    }

    @discardableResult
    private func beginReconcile(preflight: HttpSyncMapChanges?) -> Task<Void, Never> {
        if let reconcileTask { return reconcileTask }
        // `@MainActor in` is load-bearing: without it this Task runs on the cooperative pool, so the
        // whole reconcile (which the author intends to be MainActor-isolated for race-free file IO)
        // executes off the main actor. Every @MainActor closure it then hands to a stdlib generic
        // trips a dynamic executor check and traps the app (EXC_BREAKPOINT). Pinning the task to the
        // main actor keeps the reconcile on main, matching its design and removing that crash class.
        let taskId = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runReconcile(preflight: preflight)
        }
        reconcileTaskId = taskId
        reconcileTask = task
        Task { @MainActor [weak self] in
            await task.value
            guard let self, self.reconcileTaskId == taskId else { return }
            self.reconcileTask = nil
            self.reconcileTaskId = nil
            if self.batchState.hasPending { self.scheduleBookmarkSync() }
        }
        return task
    }

    private func runReconcile(preflight: HttpSyncMapChanges?) async {
        tokenRejected = false
        lastError = nil
        lastErrors = []
        lastStatus = nil
        guard settings.isConfigured else {
            lastError = "HTTP sync is not configured. Add a base URL and token first."
            log.error("syncNow aborted: not configured")
            return
        }
        let config = settings.currentConfig()
        HttpSyncCloudBooks.shared.activateScope(config: config)
        let host = URLComponents(string: config.baseURL)?.host ?? ""
        if !["localhost", "127.0.0.1", "::1", "[::1]"].contains(host),
           NetworkReachability.shared.hasObservedPath, !NetworkReachability.shared.isOnline {
            lastError = "No network — try again when you're back online."
            return
        }
        var cursor = settings.lastSyncedAt

        log.info("syncNow starting (cursor=\(cursor ?? "nil", privacy: .public))")
        isSyncing = true
        transferMeter = HttpSyncTransferMeter()
        // Gives the small reconciliation steps time to finish while background URLSession owns
        // the long file transfer. Expiration ends this lease, never the OS-owned download.
        var backgroundLease: UIBackgroundTaskIdentifier = .invalid
        backgroundLease = UIApplication.shared.beginBackgroundTask(withName: "Book sync") {
            if backgroundLease != .invalid { UIApplication.shared.endBackgroundTask(backgroundLease); backgroundLease = .invalid }
        }
        lastError = nil
        progress = HttpSyncProgress(
            message: "Starting sync",
            detail: "Preparing to compare this device with the server."
        )
        defer {
            isSyncing = false
            progress = nil
            transferProgress = nil
            if backgroundLease != .invalid { UIApplication.shared.endBackgroundTask(backgroundLease) }
            if Task.isCancelled {
                lastError = nil; lastErrors = []
                lastStatus = "Sync cancelled. Interrupted downloads can resume next time."
            }
            // The shelf shortcut stays on Books while sync imports/removes titles and positions.
            NotificationCenter.default.post(name: .hoshiLibraryChanged, object: nil)
        }

        // Network IO runs off-thread inside URLSession's async methods; the heavy file work (zip,
        // sha256) is offloaded to a nonisolated payload codec. The orchestration awaits here on
        // the main actor, which keeps the @Observable state and shelf/metadata file writes simple
        // and race-free under the project's MainActor-default isolation.
        //
        // The reconciler streams phased progress through `onProgress`; we hop back onto the main
        // actor to update the @Observable `progress` so the settings screen's bar/label tracks it.
        let operationID = reconcileTaskId
        let transport = HttpSyncWriteTrackingTransport(
            base: HttpSyncKvClient(baseURL: config.baseURL, bearerToken: config.token) { [weak self] sample in
                Task { @MainActor in
                    guard let self, self.isSyncing, self.reconcileTaskId == operationID else { return }
                    HttpSyncCloudBooks.shared.updateTransfer(sample)
                    self.transferProgress = self.transferMeter.update(sample, now: ProcessInfo.processInfo.systemUptime)
                }
            }
        )
        let mapChanges: HttpSyncMapChanges
        if let preflight {
            mapChanges = preflight
        } else {
            do {
                mapChanges = try await batchState.syncMaps(transport: transport)
            } catch {
                tokenRejected = [401, 403].contains((error as? HttpSyncError)?.statusCode ?? 0)
                let message = error.localizedDescription
                lastErrors = [message]
                lastError = lastErrors.first
                noteFullReconcileOutcome(errors: lastErrors)
                log.error("map preflight failed: \(message, privacy: .public)")
                return
            }
        }
        guard !Task.isCancelled else { return }
        let positions = await HttpReadingPositionLane.shared.run(
            transport: transport, listing: mapChanges.statisticsMetadata, scope: statisticsScope(config)
        ) { self.settings.currentConfig() == config }
        // The metadata snapshot is also the availability index for statistics. Without it,
        // an installed tablet with missing history and missing sync state can return here
        // forever with an unchanged book map and an empty streak.
        let statisticsErrors = await HttpStatisticsLane.shared.run(
            transport: transport, listing: mapChanges.statisticsMetadata, scope: statisticsScope(config), flush: true, retryFailed: true
        )
        guard !Task.isCancelled else { return }
        let readerPreferencesOutcome = await HttpReaderPreferencesLane.shared.run(transport: transport, listing: mapChanges.statisticsMetadata, scope: statisticsScope(config)) {
            self.settings.currentConfig() == config
        }
        // Sync the small model/prompt blob FIRST and independently. A corrupt book, a huge payload,
        // or a later rate-limit error must never prevent the user's prompt/model edit from reaching
        // the other device.
        progress = HttpSyncProgress(
            message: "Syncing translation settings",
            detail: "Saving the selected model and prompts before syncing books."
        )
        var appSettingsOutcome = HttpSyncReconciler.AppSettingsOutcome()
        if let aiSettings, mapChanges.needsBootstrap || mapChanges.booksChanged || mapChanges.otherChanged || !statisticsErrors.isEmpty {
            appSettingsOutcome = await HttpSyncReconciler.syncAppSettings(
                transport: transport,
                settings: aiSettings
            )
        }

        if mapChanges.needsBootstrap || mapChanges.booksChanged { cursor = nil }
        if !mapChanges.needsBootstrap && !mapChanges.booksChanged && !mapChanges.otherChanged && !HttpSyncCloudBooks.shared.hasRequestedDownloads {
            var result = HttpSyncResult()
            result.uploadedBookmarks = mapChanges.uploadedBookmarks
            result.downloadedBookmarks = mapChanges.downloadedBookmarks + positions.moved.count
            result.uploadedAppSettings = appSettingsOutcome.uploaded
            result.downloadedAppSettings = appSettingsOutcome.downloaded
            result.errors = statisticsErrors + positions.errors + readerPreferencesOutcome.errors + (appSettingsOutcome.error.map { [$0] } ?? [])
            // A manga installed by a stopped or failed pass is still waiting to be shown.
            guard let revealed = await revealReadyDownloads(transport: transport, config: config) else { return }
            result.downloadedBookmarks += revealed.moved
            for message in revealed.errors where !result.errors.contains(message) { result.errors.append(message) }
            lastErrors = result.errors
            lastError = result.errors.first
            lastStatus = result.summary() + Self.readerPreferencesSummary(readerPreferencesOutcome)
            notePushOutcome(success: true)
            noteFullReconcileOutcome(errors: [])
            await cleanExpiredDownloads()
            log.info("syncNow done from maps: \(result.summary(), privacy: .public)")
            return
        }
        let reconciler = HttpSyncReconciler(transport: transport, exchangeLegacyBookmarks: mapChanges.needsBootstrap)
        var result = await reconciler.syncOnce(sinceCursor: cursor) { [weak self] update in
            await MainActor.run { self?.progress = update; self?.transferProgress = nil }
        }
        result.uploadedAppSettings = appSettingsOutcome.uploaded
        result.downloadedAppSettings = appSettingsOutcome.downloaded
        result.uploadedBookmarks += mapChanges.uploadedBookmarks
        guard !Task.isCancelled else { return }
        result.downloadedBookmarks += mapChanges.downloadedBookmarks + positions.moved.count
        for error in statisticsErrors + positions.errors + readerPreferencesOutcome.errors where !result.errors.contains(error) { result.errors.append(error) }
        if let error = appSettingsOutcome.error { result.errors.append(error) }
        if result.errors.isEmpty {
            do {
                let after = try await batchState.observeLegacyEtags(transport: transport)
                if let expected = transport.expectedLegacyEtags(
                    after: mapChanges.observedLegacyEtags
                ), after == expected {
                    let published = try await batchState.publishMaps(
                        transport: transport,
                        acknowledgedLegacyEtags: expected
                    )
                    result.downloadedBookmarks += published.downloadedBookmarks
                }
            }
            catch { result.errors.append(error.localizedDescription) }
        }

        guard let revealed = await revealReadyDownloads(transport: transport, config: config) else { return }
        result.downloadedBookmarks += revealed.moved
        for message in revealed.errors where !result.errors.contains(message) { result.errors.append(message) }
        if let newCursor = result.newLastSyncedAt {
            settings.recordCursor(newCursor, for: config)
        }
        lastErrors = result.errors
        lastStatus = result.summary() + Self.readerPreferencesSummary(readerPreferencesOutcome)
        noteFullReconcileOutcome(errors: result.errors)
        if result.errors.isEmpty {
            // A successful reconcile proves the server is reachable — reopen the breaker.
            notePushOutcome(success: true)
            await cleanExpiredDownloads()
            log.info("syncNow done: \(result.summary(), privacy: .public)")
        } else {
            lastError = result.errors.first
            log.error("syncNow finished with \(result.errors.count) error(s): \(result.summary(), privacy: .public)")
            for err in result.errors { log.error("syncNow error: \(err, privacy: .public)") }
        }
    }

    /// Shows installed cloud manga once the bookmark maps and position histories have seen them.
    /// As on Android, another book's errors (and position histories, which keep syncing) never
    /// hide a downloaded manga. A stop or failed map exchange leaves it for the next pass to show.
    /// Returns nil when the account changed and the pass must end.
    private func revealReadyDownloads(transport: HttpSyncKvTransport, config: HttpSyncConfig) async -> (moved: Int, errors: [String])? {
        let ready = HttpSyncCloudBooks.shared.readySyncIds
        guard !ready.isEmpty, settings.currentConfig() == config else { return (0, []) }
        do {
            let afterImport = try await batchState.syncMaps(transport: transport)
            let positions = await HttpReadingPositionLane.shared.run(
                transport: transport, listing: afterImport.statisticsMetadata, scope: statisticsScope(config)
            ) { self.settings.currentConfig() == config }
            try Task.checkCancellation()
            guard settings.currentConfig() == config else { return nil }
            HttpSyncCloudBooks.shared.reveal(ready)
            return (positions.moved.count, positions.errors)
        } catch is CancellationError {
            return (0, [])
        } catch {
            return (0, ["Could not finish syncing the downloaded manga's reading position."])
        }
    }

    private func cleanExpiredDownloads() async {
        guard let books = try? BookStorage.getBooksDirectory() else { return }
        _ = await HttpSyncBackgroundDownloads.shared.cleanDownloads(books: books,
            olderThan: Date().addingTimeInterval(-HttpSyncDownloadCache.retention))
    }

    private func noteFullReconcileOutcome(errors: [String]) {
        guard !errors.isEmpty else {
            fullRetryDeferredForReader = false
            fullRetryAfter = nil
            return
        }
        let deferredDeletion = errors.contains {
            $0.localizedCaseInsensitiveContains("deletion deferred while this book is open")
        } && HttpSyncActiveBooks.hasAny
        fullRetryDeferredForReader = deferredDeletion
        fullRetryAfter = deferredDeletion ? nil : Date().addingTimeInterval(60)
    }

    // MARK: - Fire-and-forget circuit breaker

    /// After `maxConsecutiveFailures` failed fire-and-forget pushes, suppress further pushes for
    /// `suppressInterval` so a down server isn't hammered on every page turn / shelf move.
    /// Mirrors Android's HttpSyncReaderHooks breaker. Reset by any success or a manual sync.
    private var consecutiveFailures = 0
    private var suppressedUntil: Date?
    private let maxConsecutiveFailures = 3
    private let suppressInterval: TimeInterval = 5 * 60

    private var pushesSuppressed: Bool {
        if let until = suppressedUntil {
            if Date() < until { return true }
            suppressedUntil = nil
            consecutiveFailures = 0
        }
        return false
    }

    private func notePushOutcome(success: Bool) {
        if success {
            consecutiveFailures = 0
            suppressedUntil = nil
        } else {
            consecutiveFailures += 1
            if consecutiveFailures >= maxConsecutiveFailures {
                suppressedUntil = Date().addingTimeInterval(suppressInterval)
                log.error("auto-push circuit breaker tripped; suppressed for \(Int(self.suppressInterval))s")
            }
        }
    }

    /// True when fire-and-forget hooks may run.
    private var autoPushReady: Bool {
        settings.enabled && settings.isConfigured && !pushesSuppressed
    }

    // MARK: - Fire-and-forget push hooks (reader-hot + metadata edits)

    /// Call after a bookmark has been persisted to disk for `book` (e.g. the page-turn debounce
    /// fired, EPUB or manga). Replaces that book's durable outbox entry; the map exchange sends
    /// all dirty bookmarks together within five seconds. No-ops silently when sync is disabled
    /// or unconfigured; never throws.
    func onPageTurnPersisted(book: BookMetadata) {
        // Persist first, then coalesce every dirty book into one exchange at most five
        // seconds later. The outbox survives process death and is cleared only by an
        // acknowledgement for the exact mutation id.
        batchState.queueBookmark(book: book)
        scheduleBookmarkSync()
    }

    /// Called on app activation so another device's latest bookmark is pulled before
    /// this device gets a chance to keep reading from an old position.
    func syncInBackground() {
        guard settings.enabled, settings.isConfigured else { return }
        scheduleBookmarkSync()
    }

    func resumePolling() {
        foreground = true
        HttpSyncCloudBooks.shared.activateScope(config: settings.currentConfig())
        if settings.isConfigured, HttpSyncCloudBooks.shared.hasRequestedDownloads || HttpSyncCloudBooks.shared.hasReadyDownloads { runCloudDownloads() }
        syncInBackground()
    }

    func requestCloudBookDownload(syncId: String) {
        guard settings.isConfigured, HttpSyncCloudBooks.shared.requestDownload(syncId: syncId) else { return }
        runCloudDownloads()
    }

    private func runCloudDownloads() {
        let catalogue = HttpSyncCloudBooks.shared
        let generation = catalogue.generation
        let requested = Dictionary(uniqueKeysWithValues: catalogue.records.compactMap { record in
            record.downloadRequestedAt.map { (record.syncId, $0) }
        })
        Task {
            await self.syncNow()
            guard !self.isSyncing, catalogue.generation == generation, let message = self.lastError else { return }
            // An installed manga waiting to be shown is past failing; the next exchange shows it.
            for (id, stamp) in requested {
                guard let record = catalogue.record(syncId: id), record.downloadRequestedAt == stamp, !record.awaitingBookmarkMap else { continue }
                catalogue.failDownload(syncId: id, message: message)
            }
        }
    }

    /// A manga still waiting for its turn is skipped by the running pass; only one whose archive
    /// is transferring stops the pass. Other tapped manga keep their requests and continue.
    func cancelCloudBookDownload(syncId: String) {
        let catalogue = HttpSyncCloudBooks.shared
        let transferring = isSyncing && catalogue.transferringSyncId == syncId
        catalogue.cancelRequest(syncId: syncId)
        guard transferring else { return }
        cancellationGeneration &+= 1
        reconcileTask?.cancel()
        if catalogue.hasRequestedDownloads { runCloudDownloads() }
    }

    func suspendPolling() {
        foreground = false
        pollID = UUID()
        bookmarkSyncTask?.cancel()
        bookmarkSyncTask = nil
    }

    /// Reader-open gate: finish the cheap bookmark-map pull before either reader loads its
    /// sidecar, so an upgraded/still-running client cannot re-save a stale in-memory position.
    func syncBookmarksBeforeReading(book: BookMetadata) async {
        // An unstructured task keeps the late bookmark pull alive after the opening budget.
        // A structured task group would wait for URLSession cancellation before returning.
        let gate = ReadingOpenGate()
        await withCheckedContinuation { continuation in
            gate.continuation = continuation
            Task { await self.pullBookmarksBeforeReading(book: book); gate.finish() }
            Task { try? await Task.sleep(for: .milliseconds(1500)); gate.finish() }
        }
    }

    private final class ReadingOpenGate {
        var continuation: CheckedContinuation<Void, Never>?
        func finish() { let pending = continuation; continuation = nil; pending?.resume() }
    }

    private func pullBookmarksBeforeReading(book: BookMetadata) async {
        guard settings.enabled, settings.isConfigured else { return }
        let changes = await exchangeMapsOnly()
        guard changes?.needsBootstrap == true else { return }
        do {
            _ = try await batchState.syncLegacyBookmark(book: book, config: settings.currentConfig())
        } catch {
            log.error("legacy bookmark bootstrap failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Reader-close fast path: do not leave the final page waiting on the timer.
    func flushBookmarkSync() async {
        guard settings.enabled, settings.isConfigured, batchState.hasPending else { return }
        let before = batchState.pendingGeneration
        let joinedExistingFlight = mapExchangeTask != nil
        _ = await exchangeMapsOnly()
        let after = batchState.pendingGeneration
        // A joined flight may have captured its outbox before the final page turn. One more
        // exchange delivers that exact generation while the active-book lease is still held.
        if after != nil, joinedExistingFlight || after != before {
            _ = await exchangeMapsOnly()
        }
    }

    /// One cheap list every five seconds while configured; local turns share one shard PUT.
    private func scheduleBookmarkSync() {
        guard foreground, settings.enabled, settings.isConfigured, bookmarkSyncTask == nil else { return }
        let id = UUID(); pollID = id
        bookmarkSyncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.foreground && self.pollID == id {
                _ = await self.exchangeMapsOnly()
                try? await Task.sleep(for: .seconds(5))
            }
            if self.pollID == id { self.bookmarkSyncTask = nil }
        }
    }

    /// The reader-hot path: upload every queued bookmark and conditionally read
    /// the logical maps in one metadata request. A changed book or non-map ETag launches the
    /// larger binary/metadata reconcile, and that work remains in the background.
    private func exchangeMapsOnly() async -> HttpSyncMapChanges? {
        if let mapExchangeTask {
            return await mapExchangeTask.value
        }
        let taskId = UUID()
        let task: Task<HttpSyncMapChanges?, Never> = Task { @MainActor [weak self] in
            guard let self else { return nil }
            return await self.performMapExchange()
        }
        mapExchangeTaskId = taskId
        mapExchangeTask = task
        let result = await task.value
        if mapExchangeTaskId == taskId {
            mapExchangeTask = nil
            mapExchangeTaskId = nil
        }
        return result
    }

    private func performMapExchange() async -> HttpSyncMapChanges? {
        guard settings.enabled, settings.isConfigured else { return nil }
        do {
            let config = settings.currentConfig()
            HttpSyncCloudBooks.shared.activateScope(config: config)
            let ready = HttpSyncCloudBooks.shared.readySyncIds
            let transport = HttpSyncKvClient(baseURL: config.baseURL, bearerToken: config.token)
            let changes = try await batchState.syncMaps(transport: transport)
            _ = await HttpReadingPositionLane.shared.run(
                transport: transport, listing: changes.statisticsMetadata, scope: statisticsScope(config)
            ) { self.settings.currentConfig() == config }
            // A manga left waiting by a stopped or failed pass is shown once its maps were exchanged.
            if !ready.isEmpty, settings.currentConfig() == config { HttpSyncCloudBooks.shared.reveal(ready) }
            HttpStatisticsLane.shared.poll(transport: transport, listing: changes.statisticsMetadata, scope: statisticsScope(config))
            HttpReaderPreferencesLane.shared.poll(transport: transport, listing: changes.statisticsMetadata, scope: statisticsScope(config)) { self.settings.currentConfig() == config }
            notePushOutcome(success: true)
            guard foreground else { return changes }
            if changes.needsBootstrap || changes.booksChanged || changes.otherChanged {
                if fullRetryDeferredForReader, HttpSyncActiveBooks.hasAny { return changes }
                if fullRetryDeferredForReader { fullRetryDeferredForReader = false }
                if let fullRetryAfter, Date() < fullRetryAfter { return changes }
                beginReconcile(preflight: changes)
            } else {
                fullRetryDeferredForReader = false
                fullRetryAfter = nil
            }
            return changes
        } catch {
            notePushOutcome(success: false)
            HttpStatisticsLane.shared.markFailed(error)
            log.error("map exchange failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func onReaderPreferencesChanged() {
        readerPreferencesTask?.cancel()
        readerPreferencesTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard let self, self.settings.isConfigured else { return }
            let config = self.settings.currentConfig()
            let transport = HttpSyncKvClient(baseURL: config.baseURL, bearerToken: config.token)
            _ = await HttpReaderPreferencesLane.shared.run(transport: transport) { self.settings.currentConfig() == config }
        }
    }

    private static func readerPreferencesSummary(_ outcome: HttpReaderPreferencesLane.Outcome) -> String {
        var parts: [String] = []
        if outcome.uploaded { parts.append("reader preferences up") }
        if outcome.downloaded { parts.append("reader preferences down") }
        return parts.isEmpty ? "" : "; " + parts.joined(separator: ", ")
    }

    private func statisticsScope(_ config: HttpSyncConfig) -> String {
        config.baseURL + ":" + SHA256.hash(data: Data(config.token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Call after the user moves `book` onto `shelfName` (nil = unshelved). Records the placement
    /// in the shelf-state sidecar, bumps the metadata key's rev, and pushes the metadata blob.
    func onShelfPlacementChanged(book: BookMetadata, shelfName: String?) {
        guard let bookSyncId = syncId(for: book) else { return }
        // Record placement locally even when offline/disabled — the next manual sync uses it.
        let now = rfc3339Now()
        var shelfState = HttpSyncShelfStateStore.load()
        shelfState[bookSyncId] = HttpSyncShelfPlacementRecord(shelfName: shelfName, updatedAt: now)
        HttpSyncShelfStateStore.save(shelfState)
        let localRev = HttpSyncRevisionStore.bumpForLocalEdit(SyncKeys.metadata(bookSyncId))
        guard autoPushReady else { return }
        let config = settings.currentConfig()
        let upload = MetadataUpload(
            syncId: bookSyncId, title: book.title ?? bookSyncId, contentType: book.resolvedContentType,
            shelfName: shelfName, shelfUpdatedAt: now, importedAt: book.importedAt,
            deletedAt: nil, localRev: localRev
        )
        Task {
            let ok = await Self.pushMetadata(config: config, upload: upload)
            self.notePushOutcome(success: ok)
        }
    }

    /// Call right after a successful import. Publishes the book's metadata immediately so other
    /// devices see it; the (large) payload still uploads on the next manual sync only.
    func onBookImported(book: BookMetadata) {
        guard let bookSyncId = syncId(for: book) else { return }
        let localRev = HttpSyncRevisionStore.bumpForLocalEdit(SyncKeys.metadata(bookSyncId))
        if let folder = book.folder, let books = try? BookStorage.getBooksDirectory() {
            let root = books.appendingPathComponent(folder)
            Task {
                let codec = HttpSyncPayloadCodec()
                if (try? await codec.ensurePayloadContentSha(bookRoot: root)) != nil {
                    codec.markPayloadContentDirty(bookRoot: root)
                }
                self.syncInBackground()
            }
        } else {
            syncInBackground()
        }
        guard autoPushReady else { return }
        let config = settings.currentConfig()
        let upload = MetadataUpload(
            syncId: bookSyncId, title: book.title ?? bookSyncId, contentType: book.resolvedContentType,
            shelfName: nil, shelfUpdatedAt: nil, importedAt: book.importedAt,
            deletedAt: nil, localRev: localRev
        )
        Task {
            let ok = await Self.pushMetadata(config: config, upload: upload)
            self.notePushOutcome(success: ok)
        }
    }

    /// Call after a local delete has been staged in HttpSyncDeletedBookStore. Pushes the
    /// tombstone immediately (the staged record stays as the retry path for manual sync).
    func onBookDeleted(syncId bookSyncId: String, title: String, contentType: ContentType, deletedAt: String) {
        let localRev = HttpSyncRevisionStore.bumpForLocalEdit(SyncKeys.metadata(bookSyncId))
        syncInBackground()
        guard autoPushReady else { return }
        let config = settings.currentConfig()
        let upload = MetadataUpload(
            syncId: bookSyncId, title: title, contentType: contentType,
            shelfName: nil, shelfUpdatedAt: nil, importedAt: nil,
            deletedAt: deletedAt, localRev: localRev
        )
        Task {
            let ok = await Self.pushMetadata(config: config, upload: upload)
            self.notePushOutcome(success: ok)
        }
    }

    /// Call after the translation model/prompt settings change. Debounced because prompt fields
    /// edit per keystroke. This deliberately bypasses the book-push circuit breaker: one failed
    /// bookmark must not suppress a later prompt/model save.
    private var aiSettingsPushTask: Task<Void, Never>?
    func onAiSettingsChanged() {
        guard settings.enabled, settings.isConfigured, let aiSettings else { return }
        aiSettingsPushTask?.cancel()
        aiSettingsPushTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, settings.enabled, settings.isConfigured else { return }
            let config = settings.currentConfig()
            let transport = HttpSyncKvClient(baseURL: config.baseURL, bearerToken: config.token)
            _ = await HttpSyncReconciler.syncAppSettings(transport: transport, settings: aiSettings)
        }
    }

    /// Call after a chat entry has been appended to `ai_chat_log.json` for `book`. PUTs the single
    /// content-addressed chat key. Idempotent (re-pushes write identical bytes). No-ops when sync
    /// is disabled / unconfigured; never throws.
    func onChatEntryPersisted(book: BookMetadata, entry: AiChatEntry) {
        guard let bookSyncId = syncId(for: book), autoPushReady else { return }
        let config = settings.currentConfig()
        Task {
            let ok = await Self.pushChatEntry(config: config, syncId: bookSyncId, entry: entry)
            self.notePushOutcome(success: ok)
        }
    }

    // MARK: - Push implementations

    /// One fire-and-forget metadata upload. The hook that constructs it has already bumped the
    /// key's local rev; the changed field's freshness (e.g. shelfUpdatedAt = now) makes the
    /// shelf-LWW merge below keep the local change while preserving fresher remote fields.
    nonisolated struct MetadataUpload: Sendable {
        let syncId: String
        let title: String
        let contentType: ContentType
        let shelfName: String?
        let shelfUpdatedAt: String?
        let importedAt: String?
        let deletedAt: String?
        let localRev: Int
    }

    /// Returns true on success (incl. "remote out-revisions us, push correctly skipped").
    private static func pushBookmark(config: HttpSyncConfig, syncId: String, root: URL, localRev: Int) async -> Bool {
        let transport = HttpSyncKvClient(baseURL: config.baseURL, bearerToken: config.token)
        let key = SyncKeys.bookmark(syncId)
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        do {
            guard let local = BookStorage.loadBookmark(root: root) else { return true }
            // Overwrite protection: fetch the remote bookmark; if its reading event is newer,
            // pull it locally and
            // skip the push. Mirrors Android HttpSyncPusher.pushBookmark.
            if let remote = try await transport.get(key: key),
               let remoteBlob = try? decoder.decode(HttpSyncBookmarkBlob.self, from: remote.body) {
                let localStamp = local.lastModified.map { rfc3339(from: $0) }
                if compareRevisioned(localRev: localRev, remoteRev: remoteBlob.rev,
                                     localStamp: localStamp, remoteStamp: remoteBlob.lastModified) == .remoteWins {
                    let bookmark = Bookmark(
                        chapterIndex: remoteBlob.chapterIndex,
                        progress: remoteBlob.progress,
                        characterCount: remoteBlob.characterCount,
                        lastModified: Date(timeIntervalSinceReferenceDate: rfc3339ToAppleSeconds(remoteBlob.lastModified))
                    )
                    try? BookStorage.save(bookmark, inside: root, as: FileNames.bookmark)
                    HttpSyncRevisionStore.noteRemote(key, rev: remoteBlob.rev, appliedLocally: true)
                    return true
                }
            }
            // A newer local edit may have superseded this push while the GET was in flight —
            // let its own push deliver the deeper rev instead of racing it with stale content.
            guard HttpSyncRevisionStore.current(key).localRev == localRev else { return true }
            var blob = local.toBlob()
            blob.rev = localRev
            _ = try await transport.put(
                key: key,
                contentType: "application/json; charset=utf-8",
                body: try encoder.encode(blob)
            )
            HttpSyncRevisionStore.noteRemote(key, rev: localRev, appliedLocally: true)
            return true
        } catch {
            // Fire-and-forget: swallow. The next reconcile or page turn retries.
            return false
        }
    }

    /// Fire-and-forget metadata PUT with the same merge rules as the reconciler's outbound pass:
    /// honour a winning remote tombstone, keep a fresher remote shelf placement, advance
    /// importedAt — then push only if the local edit out-revisions the remote blob.
    private static func pushMetadata(config: HttpSyncConfig, upload: MetadataUpload) async -> Bool {
        let transport = HttpSyncKvClient(baseURL: config.baseURL, bearerToken: config.token)
        let key = SyncKeys.metadata(upload.syncId)
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        do {
            var remoteBlob: HttpSyncMetadataBlob?
            if let remote = try await transport.get(key: key) {
                remoteBlob = try? decoder.decode(HttpSyncMetadataBlob.self, from: remote.body)
            }
            if let remoteBlob {
                switch compareRevisioned(localRev: upload.localRev, remoteRev: remoteBlob.rev,
                                         localStamp: upload.shelfUpdatedAt ?? upload.deletedAt,
                                         remoteStamp: remoteBlob.shelfUpdatedAt ?? remoteBlob.deletedAt) {
                case .remoteWins:
                    // Newer remote edit: do not clobber. The next manual sync applies it.
                    HttpSyncRevisionStore.noteRemote(key, rev: remoteBlob.rev, appliedLocally: false)
                    return true
                case .localWins, .tie:
                    break
                }
            }
            // Merge: keep the fresher shelf placement, advance importedAt, honour tombstones.
            var shelfName = upload.shelfName
            var shelfUpdatedAt = upload.shelfUpdatedAt
            if let remoteBlob, upload.deletedAt == nil,
               shouldApplyRemoteShelfPlacement(remoteShelfUpdatedAt: remoteBlob.shelfUpdatedAt,
                                               localShelvesUpdatedAt: shelfUpdatedAt) {
                shelfName = remoteBlob.shelfName
                shelfUpdatedAt = remoteBlob.shelfUpdatedAt
            }
            // A remote tombstone the local re-import has overridden must NOT be carried —
            // re-publishing it at a deeper rev would delete the book on peers.
            var carriedDeletedAt = upload.deletedAt ?? remoteBlob?.deletedAt
            if upload.deletedAt == nil,
               localImportedAtOverridesRemoteDeletion(localImportedAt: upload.importedAt,
                                                      remoteDeletedAt: remoteBlob?.deletedAt) {
                carriedDeletedAt = nil
            }
            let blob = HttpSyncMetadataBlob(
                title: upload.title,
                contentType: upload.contentType,
                shelfName: shelfName,
                shelfUpdatedAt: shelfUpdatedAt,
                importedAt: maxRfc(remoteBlob?.importedAt, upload.importedAt),
                deletedAt: carriedDeletedAt,
                rev: upload.localRev
            )
            if let remoteBlob {
                var unrevisionedRemote = remoteBlob
                unrevisionedRemote.rev = blob.rev
                if unrevisionedRemote == blob {
                    // Content identical — skip the PUT (and the rev-inflation it would cause).
                    HttpSyncRevisionStore.noteRemote(key, rev: remoteBlob.rev, appliedLocally: true)
                    return true
                }
            }
            guard HttpSyncRevisionStore.current(key).localRev == upload.localRev else { return true }
            _ = try await transport.put(
                key: key,
                contentType: "application/json; charset=utf-8",
                body: try encoder.encode(blob)
            )
            HttpSyncRevisionStore.noteRemote(key, rev: upload.localRev, appliedLocally: true)
            return true
        } catch {
            return false
        }
    }

    private static func pushChatEntry(config: HttpSyncConfig, syncId: String, entry: AiChatEntry) async -> Bool {
        let transport = HttpSyncKvClient(baseURL: config.baseURL, bearerToken: config.token)
        let suffix = chatEntryKeySuffix(timestampAppleSeconds: entry.timestampSeconds, bubbleText: entry.bubbleText, response: entry.response)
        let encoder = JSONEncoder()
        do {
            _ = try await transport.put(
                key: SyncKeys.chat(syncId, suffix: suffix),
                contentType: "application/json; charset=utf-8",
                body: try encoder.encode(entry.toBlob())
            )
            return true
        } catch {
            // Fire-and-forget: swallow.
            return false
        }
    }
}
