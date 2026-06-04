//
//  HttpSyncManager.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Top-level entry point for the v2 KV HTTP sync. Owns:
//   - syncNow(): a full bidirectional reconcile (the "Sync now" button), advancing the cursor.
//   - onPageTurnPersisted(book:): fire-and-forget single bookmark PUT after a page-turn save.
//   - onChatEntryPersisted(book:entry:): fire-and-forget single chat PUT after a chat reply save.
//
//  The two push hooks mirror Android's HttpSyncPusher: one PUT each, no listing, no cursor. They
//  are gated by HttpSyncSettingsStore.enabled and never throw to the caller — a 401 / offline /
//  5xx must never affect the reader UI. syncNow() also never throws; failures land in
//  HttpSyncResult.errors and lastError.
//

import Foundation

@Observable
@MainActor
final class HttpSyncManager {
    static let shared = HttpSyncManager()

    /// True while a `syncNow()` reconcile is in flight (drives the settings screen spinner).
    private(set) var isSyncing = false
    /// One-line summary of the last successful reconcile, or nil if none yet.
    private(set) var lastStatus: String?
    /// Last fatal error string (e.g. not configured / transport build failure), or nil.
    private(set) var lastError: String?
    /// Per-key errors collected by the last reconcile, surfaced for a "details" disclosure.
    private(set) var lastErrors: [String] = []

    private let settings: HttpSyncSettingsStore
    /// Agent C makes `AiChatSettingsStore` conform to `AiSettingsSyncing` in Phase 2 and assigns
    /// it here (or via the initializer). Until then this is nil and the AI-settings sync path is
    /// skipped — every other sync path is unaffected.
    var aiSettings: AiSettingsSyncing?

    /// Serializes manual reconciles against each other (a second "Sync now" tap while one is in
    /// flight just no-ops). Fire-and-forget pushes are independent.
    private var reconcileTask: Task<Void, Never>?

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
        let task = Task { await runReconcile() }
        reconcileTask = task
        await task.value
        reconcileTask = nil
    }

    private func runReconcile() async {
        guard settings.isConfigured else {
            lastError = "HTTP sync is not configured. Add a base URL and token first."
            return
        }
        let config = settings.currentConfig()
        let cursor = settings.lastSyncedAt

        isSyncing = true
        lastError = nil
        defer { isSyncing = false }

        // Network IO runs off-thread inside URLSession's async methods; the heavy file work (zip,
        // sha256) is offloaded to a nonisolated payload codec. The orchestration awaits here on
        // the main actor, which keeps the @Observable state and shelf/metadata file writes simple
        // and race-free under the project's MainActor-default isolation.
        let transport = HttpSyncKvClient(baseURL: config.baseURL, bearerToken: config.token)
        let reconciler = HttpSyncReconciler(transport: transport)
        var result = await reconciler.syncOnce(sinceCursor: cursor)

        // App-level AI chat settings LWW — drives the non-Sendable AiChatSettingsStore. One GET +
        // maybe one PUT; cheap.
        if let aiSettings {
            let outcome = await HttpSyncReconciler.syncAppSettings(transport: transport, settings: aiSettings)
            result.uploadedAppSettings = outcome.uploaded
            result.downloadedAppSettings = outcome.downloaded
            if let error = outcome.error { result.errors.append(error) }
        }

        if let newCursor = result.newLastSyncedAt {
            settings.lastSyncedAt = newCursor
        }
        lastErrors = result.errors
        lastStatus = result.summary()
        if !result.errors.isEmpty {
            lastError = result.errors.first
        }
    }

    // MARK: - Fire-and-forget push hooks (reader-hot)

    /// Call after a bookmark has been persisted to disk for `book` (e.g. the page-turn debounce
    /// fired). PUTs `books/{syncId}/bookmark` if the local bookmark is strictly newer than the
    /// server's. No-ops silently when sync is disabled / unconfigured; never throws. Returns
    /// immediately — the PUT happens in a detached task (network IO is off-thread).
    func onPageTurnPersisted(book: BookMetadata) {
        guard let title = book.title, let folder = book.folder,
              settings.enabled, settings.isConfigured, deriveSyncId(title) != nil,
              let booksDir = try? BookStorage.getBooksDirectory() else { return }
        let config = settings.currentConfig()
        let root = booksDir.appendingPathComponent(folder)
        Task { await Self.pushBookmark(config: config, title: title, root: root) }
    }

    /// Call after a chat entry has been appended to `ai_chat_log.json` for `book`. PUTs the single
    /// content-addressed chat key. Idempotent (re-pushes write identical bytes). No-ops when sync
    /// is disabled / unconfigured; never throws.
    func onChatEntryPersisted(book: BookMetadata, entry: AiChatEntry) {
        guard let title = book.title,
              settings.enabled, settings.isConfigured, let syncId = deriveSyncId(title) else { return }
        let config = settings.currentConfig()
        Task { await Self.pushChatEntry(config: config, syncId: syncId, entry: entry) }
    }

    // MARK: - Push implementations

    private static func pushBookmark(config: HttpSyncConfig, title: String, root: URL) async {
        guard let syncId = deriveSyncId(title) else { return }
        let transport = HttpSyncKvClient(baseURL: config.baseURL, bearerToken: config.token)
        let key = SyncKeys.bookmark(syncId)
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        do {
            guard let local = BookStorage.loadBookmark(root: root) else { return }
            // Overwrite protection: fetch the remote bookmark; if it's newer, pull it locally and
            // skip the push, exactly like Android HttpSyncPusher.pushBookmark.
            if let remote = try await transport.get(key: key),
               let remoteBlob = try? decoder.decode(HttpSyncBookmarkBlob.self, from: remote.body) {
                let localStamp = local.lastModified.map { rfc3339(from: $0) }
                if compareRfc3339(remoteBlob.lastModified, localStamp) > 0 {
                    let bookmark = Bookmark(
                        chapterIndex: remoteBlob.chapterIndex,
                        progress: remoteBlob.progress,
                        characterCount: remoteBlob.characterCount,
                        lastModified: Date(timeIntervalSinceReferenceDate: rfc3339ToAppleSeconds(remoteBlob.lastModified))
                    )
                    try? BookStorage.save(bookmark, inside: root, as: FileNames.bookmark)
                    return
                }
            }
            _ = try await transport.put(
                key: key,
                contentType: "application/json; charset=utf-8",
                body: try encoder.encode(local.toBlob())
            )
        } catch {
            // Fire-and-forget: swallow. The next reconcile or page turn retries.
        }
    }

    private static func pushChatEntry(config: HttpSyncConfig, syncId: String, entry: AiChatEntry) async {
        let transport = HttpSyncKvClient(baseURL: config.baseURL, bearerToken: config.token)
        let suffix = chatEntryKeySuffix(timestampAppleSeconds: entry.timestampSeconds, bubbleText: entry.bubbleText, response: entry.response)
        let encoder = JSONEncoder()
        do {
            _ = try await transport.put(
                key: SyncKeys.chat(syncId, suffix: suffix),
                contentType: "application/json; charset=utf-8",
                body: try encoder.encode(entry.toBlob())
            )
        } catch {
            // Fire-and-forget: swallow.
        }
    }
}
