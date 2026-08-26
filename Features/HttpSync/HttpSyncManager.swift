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
import os

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
    /// One-line summary of the last successful reconcile, or nil if none yet.
    private(set) var lastStatus: String?
    /// Last fatal error string (e.g. not configured / transport build failure), or nil.
    private(set) var lastError: String?
    /// Per-key errors collected by the last reconcile, surfaced for a "details" disclosure.
    private(set) var lastErrors: [String] = []

    private let settings: HttpSyncSettingsStore
    private let batchState = HttpSyncBatchState.shared
    /// Agent C makes `AiChatSettingsStore` conform to `AiSettingsSyncing` in Phase 2 and assigns
    /// it here (or via the initializer). Until then this is nil and the AI-settings sync path is
    /// skipped — every other sync path is unaffected.
    var aiSettings: AiSettingsSyncing?

    /// Serializes manual reconciles against each other (a second "Sync now" tap while one is in
    /// flight just no-ops). Fire-and-forget pushes are independent.
    private var reconcileTask: Task<Void, Never>?
    private var bookmarkSyncTask: Task<Void, Never>?

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
        if let reconcileTask {
            await reconcileTask.value
            return
        }
        // `@MainActor in` is load-bearing: without it this Task runs on the cooperative pool, so the
        // whole reconcile (which the author intends to be MainActor-isolated for race-free file IO)
        // executes off the main actor. Every @MainActor closure it then hands to a stdlib generic
        // trips a dynamic executor check and traps the app (EXC_BREAKPOINT). Pinning the task to the
        // main actor keeps the reconcile on main, matching its design and removing that crash class.
        let task = Task { @MainActor in await runReconcile() }
        reconcileTask = task
        await task.value
        reconcileTask = nil
        if batchState.hasPending { scheduleBookmarkSync() }
    }

    private func runReconcile() async {
        guard settings.isConfigured else {
            lastError = "HTTP sync is not configured. Add a base URL and token first."
            log.error("syncNow aborted: not configured")
            return
        }
        let config = settings.currentConfig()
        let cursor = settings.lastSyncedAt

        log.info("syncNow starting (cursor=\(cursor ?? "nil", privacy: .public))")
        isSyncing = true
        lastError = nil
        progress = HttpSyncProgress(
            message: "Starting sync",
            detail: "Preparing to compare this device with the server."
        )
        defer {
            isSyncing = false
            progress = nil
        }

        // Network IO runs off-thread inside URLSession's async methods; the heavy file work (zip,
        // sha256) is offloaded to a nonisolated payload codec. The orchestration awaits here on
        // the main actor, which keeps the @Observable state and shelf/metadata file writes simple
        // and race-free under the project's MainActor-default isolation.
        //
        // The reconciler streams phased progress through `onProgress`; we hop back onto the main
        // actor to update the @Observable `progress` so the settings screen's bar/label tracks it.
        let transport = HttpSyncBatchKvTransport(
            config: config,
            request: batchState.exchangeRequest(),
            cache: batchState.cacheSnapshot()
        )
        do {
            try await transport.prepare()
            if let exchange = await transport.exchangeResponse() {
                batchState.applyExchange(exchange)
                await transport.setPendingKeys(batchState.pendingKeys)
            }
        } catch {
            let message = error.localizedDescription
            lastErrors = [message]
            lastError = message
            log.error("batch exchange failed: \(message, privacy: .public)")
            return
        }
        // Sync the small model/prompt blob FIRST and independently. A corrupt book, a huge payload,
        // or a later rate-limit error must never prevent the user's prompt/model edit from reaching
        // the other device.
        progress = HttpSyncProgress(
            message: "Syncing translation settings",
            detail: "Saving the selected model and prompts before syncing books."
        )
        var appSettingsOutcome = HttpSyncReconciler.AppSettingsOutcome()
        if let aiSettings {
            appSettingsOutcome = await HttpSyncReconciler.syncAppSettings(
                transport: transport,
                settings: aiSettings
            )
        }

        let reconciler = HttpSyncReconciler(transport: transport)
        var result = await reconciler.syncOnce(sinceCursor: cursor) { [weak self] update in
            await MainActor.run { self?.progress = update }
        }
        result.uploadedAppSettings = appSettingsOutcome.uploaded
        result.downloadedAppSettings = appSettingsOutcome.downloaded
        if let error = appSettingsOutcome.error { result.errors.append(error) }
        batchState.saveCache(await transport.cacheSnapshot())
        batchState.resolveLegacyWrites(
            await transport.legacyMutationsToResolve(fullSuccess: result.errors.isEmpty)
        )

        if let newCursor = result.newLastSyncedAt {
            settings.lastSyncedAt = newCursor
        }
        lastErrors = result.errors
        lastStatus = result.summary()
        if result.errors.isEmpty {
            // A successful reconcile proves the server is reachable — reopen the breaker.
            notePushOutcome(success: true)
            log.info("syncNow done: \(result.summary(), privacy: .public)")
        } else {
            lastError = result.errors.first
            log.error("syncNow finished with \(result.errors.count) error(s): \(result.summary(), privacy: .public)")
            for err in result.errors { log.error("syncNow error: \(err, privacy: .public)") }
        }
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
        Task { await exchangeMapsOnly() }
    }

    /// Reader-close fast path: do not leave the final page waiting on the timer.
    func flushBookmarkSync() {
        bookmarkSyncTask?.cancel()
        bookmarkSyncTask = nil
        guard settings.enabled, settings.isConfigured, batchState.hasPending else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.exchangeMapsOnly()
            if self.batchState.hasPending { self.scheduleBookmarkSync() }
        }
    }

    private func scheduleBookmarkSync() {
        guard settings.enabled, settings.isConfigured, bookmarkSyncTask == nil else { return }
        bookmarkSyncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { break }
                await self.exchangeMapsOnly()
            } while self.batchState.hasPending
            self.bookmarkSyncTask = nil
        }
    }

    /// The reader-hot path: upload every queued bookmark and conditionally read
    /// the two maps in one request. Only a changed books map launches the larger
    /// binary/metadata reconcile, and that work remains in the background.
    private func exchangeMapsOnly() async {
        guard settings.enabled, settings.isConfigured else { return }
        do {
            let changes = try await batchState.exchange(config: settings.currentConfig())
            notePushOutcome(success: true)
            if changes.booksChanged { await syncNow() }
        } catch is HttpSyncExchangeUnavailable {
            // The full transport falls back to v1 and resolves only the exact
            // outbox mutations captured before this rolling-deploy attempt.
            await syncNow()
        } catch {
            notePushOutcome(success: false)
            log.error("map exchange failed: \(error.localizedDescription, privacy: .public)")
        }
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
            // Overwrite protection: fetch the remote bookmark; if it out-revisions the local
            // edit (deeper edit chain; timestamps only break rev ties), pull it locally and
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
                    // Deeper remote edit chain: do not clobber. The next manual sync applies it.
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
