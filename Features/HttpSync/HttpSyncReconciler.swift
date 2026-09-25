//
//  HttpSyncReconciler.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Full bidirectional reconciliation against the v2 KV server, ported from the Android
//  HttpSyncReconciler over the SAME wire blobs. Called from "Sync now" in HttpSyncSettingsView.
//
//  Algorithm (inbound first so a newer server bookmark isn't stomped by our outbound push):
//   1. Inbound: list `books/` (paginated), bucket keys, then in dependency order:
//        - apply metadata tombstones (deletedAt vs local importedAt guard),
//        - import remote-only books from payload manifests,
//        - apply metadata shelf placement (shelfUpdatedAt LWW),
//        - apply bookmarks (LWW by lastModified) and chat entries (write-once set-union).
//   2. Outbound: walk every local book, PUT bookmark (only if local newer) + metadata, PUT each
//      chat entry the server doesn't already have, upload payload if the server lacks a manifest.
//   3. App-level AI chat settings: LWW via the AiSettingsSyncing protocol.
//   4. Compute the new cursor and return it for the caller to persist.
//
//  Per-key errors are collected so one corrupt book never kills the whole pass.
//

import EPUBKit
import Foundation

// MARK: - AI settings sync seam

/// The two operations the reconciler needs from Agent C's AiChatSettingsStore. Defined here as a
/// protocol so this module compiles independently; the orchestrator makes `AiChatSettingsStore`
/// conform in Phase 2 (the store already has both methods with matching signatures — see report).
///
/// `@MainActor` because the conforming store is an `@Observable` class that mutates UserDefaults
/// and observable state; the manager drives this path on the main actor (one GET + maybe one PUT),
/// keeping the heavier per-book reconcile in a detached task.
@MainActor
protocol AiSettingsSyncing {
    /// The current local settings as a sync blob, or `nil` if the user has never edited settings
    /// (in which case there's nothing to push and the remote always wins).
    func currentBlob() -> HttpSyncAiChatSettingsBlob?

    /// Applies remote settings locally if they're still newer than local state at write time
    /// (compare-and-set). Returns `true` if applied, `false` if a concurrent local edit won.
    @discardableResult
    func applyFromSync(model: String, promptText: String, imagePromptText: String, remoteLastEditedAt: String) -> Bool
}

// MARK: - Progress

/// One phased progress update emitted by the reconciler while a manual "Sync now" runs. Mirrors
/// Android's `HttpSyncProgress`: a top-level `message` (the phase), an optional finer-grained
/// `detail`, and an optional `completed`/`total` pair so the UI can render a determinate bar.
///
/// `Sendable` so it can cross the reconcile's `await` boundaries back to the main-actor `onProgress`
/// callback (the manager mirrors it onto its `@Observable` `progress`).
struct HttpSyncProgress: Sendable, Equatable {
    var message: String
    var detail: String?
    var completed: Int?
    var total: Int?

    init(message: String, detail: String? = nil, completed: Int? = nil, total: Int? = nil) {
        self.message = message
        self.detail = detail
        self.completed = completed
        self.total = total
    }

    /// Fraction in `0...1` for a determinate bar, or `nil` (indeterminate) when no counter is set.
    /// Matches Android: `(completed + 1) / total` so the final item reads as 100%.
    var fraction: Double? {
        guard let completed, let total, total > 0 else { return nil }
        return min(max(Double(completed + 1) / Double(total), 0), 1)
    }
}

// MARK: - Result

/// Outcome of one reconcile pass. Granular counts so the UI can show a one-line summary.
struct HttpSyncResult: Sendable {
    var uploadedBookmarks = 0
    var uploadedChatEntries = 0
    var uploadedMetadata = 0
    var uploadedPayloads = 0
    var uploadedAppSettings = false
    var downloadedBookmarks = 0
    var downloadedChatEntries = 0
    var downloadedPayloads = 0
    /// Books whose offline pre-translation blob was pulled this pass.
    var downloadedPretranslations = 0
    var downloadedAppSettings = false
    var remoteOnlyBooks = 0
    var errors: [String] = []
    /// New cursor for `lastSyncedAt`; `nil` means "no change, leave the stored cursor alone."
    var newLastSyncedAt: String?

    func summary() -> String {
        var parts: [String] = []
        if uploadedBookmarks > 0 { parts.append("\(uploadedBookmarks) bookmark\(plural(uploadedBookmarks)) up") }
        if uploadedChatEntries > 0 { parts.append("\(uploadedChatEntries) chat\(plural(uploadedChatEntries)) up") }
        if uploadedPayloads > 0 { parts.append("\(uploadedPayloads) book payload\(plural(uploadedPayloads)) up") }
        if uploadedAppSettings { parts.append("translation settings up") }
        if downloadedBookmarks > 0 { parts.append("\(downloadedBookmarks) bookmark\(plural(downloadedBookmarks)) down") }
        if downloadedChatEntries > 0 { parts.append("\(downloadedChatEntries) chat\(plural(downloadedChatEntries)) down") }
        if downloadedPayloads > 0 { parts.append("\(downloadedPayloads) book payload\(plural(downloadedPayloads)) down") }
        if downloadedPretranslations > 0 {
            parts.append("\(downloadedPretranslations) offline translation set\(plural(downloadedPretranslations)) down")
        }
        if downloadedAppSettings { parts.append("translation settings down") }
        if remoteOnlyBooks > 0 { parts.append("\(remoteOnlyBooks) remote-only book\(plural(remoteOnlyBooks))") }
        if parts.isEmpty { parts.append("nothing to sync") }
        return parts.joined(separator: ", ")
    }

    private func plural(_ n: Int) -> String { n == 1 ? "" : "s" }
}

// MARK: - Reconciler

// MainActor-isolated (the project default): the reconciler makes many synchronous BookStorage /
// FileManager calls and mutates shelves/metadata sidecars, so keeping it on the main actor avoids
// data races on local on-disk state. Network IO is awaited (URLSession runs it off-thread) and the
// genuinely heavy CPU work (payload zip + sha256) is offloaded inside HttpSyncPayloadCodec's
// detached tasks, so the main actor is never blocked on the expensive path.
struct HttpSyncReconciler {
    private let transport: HttpSyncKvTransport
    private let payloadCodec = HttpSyncPayloadCodec()

    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()

    private static let jsonContentType = "application/json; charset=utf-8"

    init(transport: HttpSyncKvTransport) {
        self.transport = transport
    }

    /// One per-book reconciliation pass (inbound then outbound). The app-level AI-chat-settings
    /// LWW is handled separately by `HttpSyncManager` on the main actor (it owns the non-Sendable
    /// settings store); see `HttpSyncManager.syncAppSettings`.
    ///
    /// `onProgress` is invoked at the start of each phase (and per-item within the counted phases)
    /// so the settings screen can show a live phase label + linear bar. It mirrors Android's
    /// `onProgress` callback. Defaults to a no-op so tests and the push hooks are unaffected.
    func syncOnce(
        sinceCursor: String?,
        onProgress: @escaping @Sendable (HttpSyncProgress) async -> Void = { _ in }
    ) async -> HttpSyncResult {
        var result = HttpSyncResult()

        await onProgress(HttpSyncProgress(
            message: "Preparing sync",
            detail: "Connecting to the HTTP sync server."
        ))
        let inbound = await pullChangedKeys(sinceCursor: sinceCursor, into: &result, onProgress: onProgress)
        // A partial/failed listing is not a safe snapshot of the server. Do not push local state
        // against it: that could overwrite remote changes the failed listing never revealed.
        if inbound.listingSucceeded {
            await pushAllLocal(into: &result, onProgress: onProgress)
        }

        await onProgress(HttpSyncProgress(message: "Finishing sync", detail: "Saving the sync cursor."))
        result.newLastSyncedAt = safeNewCursor(currentCursor: sinceCursor, inbound: inbound)
        if result.newLastSyncedAt == sinceCursor { result.newLastSyncedAt = nil }
        return result
    }

    // MARK: - Cursor

    private struct InboundCursor {
        var maxHandled: String?
        var minUnhandled: String?
        var listingSucceeded = true
    }

    // Plain loops, NOT compactMap/filter/reduce. Under the project's default-MainActor isolation
    // (SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor) every closure here is @MainActor, and handing a
    // @MainActor closure to a stdlib generic inserts a *dynamic* executor check
    // (swift_task_isCurrentExecutor). When the reconcile resumes off the main actor after an
    // `await`, that check trips dispatch_assert_queue and traps (EXC_BREAKPOINT — the sync crash).
    // Plain loops carry no such check, so this pure string/date math runs safely on any executor.
    private func safeNewCursor(currentCursor: String?, inbound: InboundCursor) -> String? {
        var result: String? = nil
        let firstUnhandled = inbound.minUnhandled
        for candidate in [currentCursor, inbound.maxHandled] {
            guard let candidate else { continue }
            if let firstUnhandled, compareRfc3339(candidate, firstUnhandled) >= 0 { continue }
            result = maxRfc(result, candidate)
        }
        return result
    }

    // MARK: - Key parsing

    private enum BookKeyKind {
        case bookmark, chat, metadata, payloadManifest, payloadZip, pretranslations
        /// EPUB-only keys. Separate from `payload*` so Android — whose parser skips unknown
        /// suffixes without fetching them — never sees a novel. See SyncCore.epubZip.
        case epubManifest, epubZip, sentences
    }
    private struct ParsedBookKey { let syncId: String; let kind: BookKeyKind }

    /// Lowercase phase-detail label for a key kind (mirrors Android's `kind.name.lowercase()`).
    private func kindLabel(_ kind: BookKeyKind) -> String {
        switch kind {
        case .bookmark: return "bookmark"
        case .chat: return "chat"
        case .metadata: return "metadata"
        case .payloadManifest: return "payload manifest"
        case .payloadZip: return "payload zip"
        case .pretranslations: return "offline translations"
        case .epubManifest: return "book manifest"
        case .epubZip: return "book payload"
        case .sentences: return "sentence translations"
        }
    }

    private func parseBookKey(_ key: String) -> ParsedBookKey? {
        guard key.hasPrefix(SyncKeys.allBooksPrefix) else { return nil }
        let rest = String(key.dropFirst(SyncKeys.allBooksPrefix.count))
        guard let slash = rest.firstIndex(of: "/"), slash != rest.startIndex else { return nil }
        let syncId = String(rest[rest.startIndex..<slash])
        let suffix = String(rest[rest.index(after: slash)...])
        let kind: BookKeyKind
        switch suffix {
        case "bookmark": kind = .bookmark
        case "metadata": kind = .metadata
        case "payload.manifest": kind = .payloadManifest
        case "payload.zip": kind = .payloadZip
        case "pretranslations": kind = .pretranslations
        case "epub.manifest": kind = .epubManifest
        case "epub.zip": kind = .epubZip
        case "sentences": kind = .sentences
        default:
            if suffix.hasPrefix("chat/") { kind = .chat } else { return nil }
        }
        return ParsedBookKey(syncId: syncId, kind: kind)
    }

    // MARK: - Local snapshot

    private struct LocalBook {
        let id: UUID
        let title: String
        let syncId: String
        let root: URL
        let contentType: ContentType
        let importedAt: String?
    }

    /// Reads every local book directory once, deriving syncIds. Skips blank-titled books.
    private func loadLocalBooks() -> [LocalBook] {
        guard let booksDir = try? BookStorage.getBooksDirectory(),
              let metadatas = try? BookStorage.loadAllBooks() else { return [] }
        var out: [LocalBook] = []
        for meta in metadatas {
            guard let title = meta.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let folder = meta.folder, let bookSyncId = syncId(for: meta) else { continue }
            let root = booksDir.appendingPathComponent(folder)
            // Backfill a missing importedAt (legacy books predating the field) ONCE, PERSISTED, so the
            // tombstone-vs-local guard has a stable value. A nil importedAt makes the delete win and
            // silently removes a present book the user still wants — but recomputing now() every
            // reconcile would make a legacy book always beat any tombstone (deletes never propagate,
            // and the outbound pass resurrects it). Persisting it once gives a fixed first-seen stamp:
            // a future delete (deletedAt > stamp) then correctly wins.
            var importedAt = meta.importedAt
            var updated = meta
            var shouldPersistMetadata = false
            if importedAt == nil {
                let stamp = rfc3339Now()
                importedAt = stamp
                updated.importedAt = stamp
                shouldPersistMetadata = true
            }
            if updated.syncId == nil {
                updated.syncId = bookSyncId
                shouldPersistMetadata = true
            }
            if shouldPersistMetadata {
                try? BookStorage.save(updated, inside: root, as: FileNames.metadata)
            }
            out.append(LocalBook(
                id: meta.id,
                title: title,
                syncId: bookSyncId,
                root: root,
                contentType: ContentType.detect(bookDir: root),
                importedAt: importedAt
            ))
        }
        return out
    }

    // MARK: - Inbound

    private func pullChangedKeys(
        sinceCursor: String?,
        into result: inout HttpSyncResult,
        onProgress: @escaping @Sendable (HttpSyncProgress) async -> Void
    ) async -> InboundCursor {
        var cursor = InboundCursor()
        var appliedKeys = HttpSyncAppliedKeyStore.load()
        var unflushedAppliedKeyCount = 0

        func flushAppliedKeys() {
            guard unflushedAppliedKeyCount > 0 else { return }
            HttpSyncAppliedKeyStore.save(appliedKeys)
            unflushedAppliedKeyCount = 0
        }

        func markHandled(
            _ meta: HttpSyncKvKeyMeta,
            localArtifact: HttpSyncAppliedLocalArtifact? = nil
        ) {
            cursor.maxHandled = maxRfc(cursor.maxHandled, meta.lastModified)
            appliedKeys[meta.key] = HttpSyncAppliedKeyRecord(
                meta: meta,
                localArtifact: localArtifact
            )
            unflushedAppliedKeyCount += 1
            if unflushedAppliedKeyCount >= 25 { flushAppliedKeys() }
        }
        func markUnhandled(_ meta: HttpSyncKvKeyMeta) {
            if compareRfc3339(meta.lastModified, sinceCursor) <= 0 { return }
            if cursor.minUnhandled == nil || compareRfc3339(meta.lastModified, cursor.minUnhandled) < 0 {
                cursor.minUnhandled = meta.lastModified
            }
        }

        await onProgress(HttpSyncProgress(
            message: "Scanning local books",
            detail: "Preparing to match local and remote sync IDs."
        ))
        let localBooks = loadLocalBooks()
        var rootsBySyncId: [String: URL] = [:]
        var importedAtBySyncId: [String: String?] = [:]
        for book in localBooks {
            rootsBySyncId[book.syncId] = book.root
            importedAtBySyncId[book.syncId] = book.importedAt
        }
        // SyncIds the user deleted locally but whose tombstone hasn't been pushed yet. Pass 3 must
        // NOT re-import these from the server's not-yet-tombstoned payload manifests — otherwise the
        // book resurrects, the outbound push then sees a live local book, prunes the tombstone, and
        // overwrites the server with `deletedAt = null`. The outbound pass in this same syncOnce
        // turns the remote metadata into a tombstone instead. Mirrors Android's pendingTombstoneSyncIds.
        let pendingTombstoneSyncIds = Set(HttpSyncDeletedBookStore.all().keys)

        // Pass 1: always list the complete namespace. A timestamp cursor alone is unsafe when the
        // server paginates, when equal timestamps straddle a page, or when an older client stored a
        // bad cursor. The durable per-key identity ledger below gives retries their speed without
        // sacrificing the complete remote snapshot needed for reconciliation.
        var statisticsMetas: [String: HttpSyncKvKeyMeta] = [:]
        var payloadManifests: [HttpSyncKvKeyMeta] = []
        /// EPUB manifests import through the same pass, but with the `epub.*` key pair.
        var epubManifests: [HttpSyncKvKeyMeta] = []
        var metadataKeys: [(ParsedBookKey, HttpSyncKvKeyMeta)] = []
        var bookmarksAndChats: [(ParsedBookKey, HttpSyncKvKeyMeta)] = []
        var remoteSyncIds: Set<String> = []

        await onProgress(HttpSyncProgress(
            message: "Listing remote changes",
            detail: "Asking the server what changed."
        ))
        do {
            try await transport.listAll(prefix: SyncKeys.allBooksPrefix, since: nil) { meta in
                if meta.key.hasSuffix("/statistics") || meta.key.hasSuffix("/manga_statistics") {
                    statisticsMetas[meta.key] = meta
                    return
                }
                guard let parsed = parseBookKey(meta.key) else {
                    markHandled(meta)
                    return
                }
                remoteSyncIds.insert(parsed.syncId)
                switch parsed.kind {
                case .payloadManifest: payloadManifests.append(meta)
                case .epubManifest: epubManifests.append(meta)
                case .bookmark, .chat, .pretranslations, .sentences:
                    if let root = rootsBySyncId[parsed.syncId],
                       let applied = appliedKeys[meta.key],
                       applied.matches(meta),
                       localReadingArtifactIsPresent(
                           root: root,
                           parsed: parsed,
                           key: meta.key,
                           applied: applied
                       ) {
                        // This exact immutable remote value was already committed to local disk.
                        // It is omitted from the pending counter, so a retry after item 478 resumes
                        // at the first unfinished reading item instead of visibly starting at zero.
                        markHandled(meta, localArtifact: applied.localArtifact)
                    } else {
                        bookmarksAndChats.append((parsed, meta))
                    }
                case .payloadZip, .epubZip: markHandled(meta) // followed via the manifest
                case .metadata: metadataKeys.append((parsed, meta))
                }
            }
        } catch {
            result.errors.append("list: \(errorText(error))")
            cursor.listingSucceeded = false
            flushAppliedKeys()
            return cursor
        }

        // Pass 2: apply metadata tombstones before payload import so a deleted remote book never
        // causes a fresh device to download a payload just to delete it.
        var shelfState = HttpSyncShelfStateStore.load()
        var remoteFormatBySyncId: [String: ContentType] = [:]
        var deletedSyncIds: Set<String> = []
        var placementMetadataKeys: [(ParsedBookKey, HttpSyncKvKeyMeta)] = []
        for (parsed, meta) in metadataKeys {
            do {
                guard let remote = try await fetchRemoteMetadata(key: meta.key) else {
                    throw HttpSyncError("Metadata at \(meta.key): missing.")
                }
                remoteFormatBySyncId[parsed.syncId] = remote.blob.contentType
                if let remoteDeletedAt = remote.blob.deletedAt {
                    let localImportedAt = importedAtBySyncId[parsed.syncId] ?? nil
                    if localImportedAtOverridesRemoteDeletion(localImportedAt: localImportedAt, remoteDeletedAt: remoteDeletedAt) {
                        // Re-import after tombstone: the live local copy wins. Keep it; leave the
                        // tombstone unhandled so the cursor doesn't advance past it until the
                        // outbound push re-publishes metadata with deletedAt = nil.
                        markUnhandled(meta)
                    } else if HttpSyncActiveBooks.contains(parsed.syncId) {
                        result.errors.append("metadata \(parsed.syncId): deletion deferred while this book is open")
                        markUnhandled(meta)
                    } else {
                        if let root = rootsBySyncId[parsed.syncId] { deleteBook(root: root, bookId: localBookId(localBooks, parsed.syncId)) }
                        rootsBySyncId.removeValue(forKey: parsed.syncId)
                        shelfState.removeValue(forKey: parsed.syncId)
                        deletedSyncIds.insert(parsed.syncId)
                        markHandled(meta)
                    }
                } else {
                    placementMetadataKeys.append((parsed, meta))
                }
            } catch {
                result.errors.append("metadata \(parsed.syncId): \(errorText(error))")
                markUnhandled(meta)
            }
        }

        // Pass 3: import remote-only books by their payload manifests, BEFORE bookmarks/chats.
        // A stale server can contain both key pairs for one syncId. Metadata is authoritative when
        // present; without it, ambiguity is rejected instead of silently preferring mokuro because
        // that list happened to be concatenated first.
        var manifestsBySyncId: [String: (mokuro: HttpSyncKvKeyMeta?, epub: HttpSyncKvKeyMeta?)] = [:]
        for meta in payloadManifests {
            guard let parsed = parseBookKey(meta.key) else { continue }
            var pair = manifestsBySyncId[parsed.syncId] ?? (nil, nil)
            pair.mokuro = meta
            manifestsBySyncId[parsed.syncId] = pair
        }
        for meta in epubManifests {
            guard let parsed = parseBookKey(meta.key) else { continue }
            var pair = manifestsBySyncId[parsed.syncId] ?? (nil, nil)
            pair.epub = meta
            manifestsBySyncId[parsed.syncId] = pair
        }
        var allManifests: [(HttpSyncKvKeyMeta, ContentType)] = []
        for bookSyncId in manifestsBySyncId.keys.sorted() {
            guard let pair = manifestsBySyncId[bookSyncId] else { continue }
            if let mokuro = pair.mokuro, let epub = pair.epub {
                switch remoteFormatBySyncId[bookSyncId] {
                case .some(.mokuro):
                    allManifests.append((mokuro, .mokuro))
                    markHandled(epub)
                case .some(.epub):
                    allManifests.append((epub, .epub))
                    markHandled(mokuro)
                case .none:
                    result.errors.append(
                        "payload \(bookSyncId): both payload.manifest and epub.manifest exist without authoritative metadata."
                    )
                    markUnhandled(mokuro)
                    markUnhandled(epub)
                }
            } else if let mokuro = pair.mokuro {
                allManifests.append((mokuro, .mokuro))
            } else if let epub = pair.epub {
                allManifests.append((epub, .epub))
            }
        }
        for (index, entry) in allManifests.enumerated() {
            let (meta, format) = entry
            guard let parsed = parseBookKey(meta.key) else { continue }
            await onProgress(HttpSyncProgress(
                message: "Checking remote book payloads",
                detail: "Book \(index + 1) of \(allManifests.count): \(parsed.syncId)",
                completed: index,
                total: allManifests.count
            ))
            if deletedSyncIds.contains(parsed.syncId) { markHandled(meta); continue }
            if pendingTombstoneSyncIds.contains(parsed.syncId) { markHandled(meta); continue }
            if let declared = remoteFormatBySyncId[parsed.syncId], declared != format {
                result.errors.append(
                    "payload \(parsed.syncId): metadata declares \(declared.rawValue), "
                    + "but only \(format.rawValue) manifest was selected."
                )
                markUnhandled(meta)
                continue
            }
            if let existingRoot = rootsBySyncId[parsed.syncId] {
                do {
                    if try await refreshExistingBookPayload(
                        syncId: parsed.syncId,
                        format: format,
                        root: existingRoot
                    ) {
                        result.downloadedPayloads += 1
                    }
                    markHandled(meta)
                } catch {
                    result.errors.append("payload \(parsed.syncId): \(errorText(error))")
                    markUnhandled(meta)
                }
                continue
            }
            do {
                if let imported = try await importRemoteOnlyBook(syncId: parsed.syncId, format: format) {
                    rootsBySyncId[parsed.syncId] = imported
                    result.downloadedPayloads += 1
                    markHandled(meta)
                } else {
                    markUnhandled(meta)
                }
            } catch {
                result.errors.append("payload \(parsed.syncId): \(errorText(error))")
                // A `skip` error (e.g. can't ever fit this book) advances the cursor so we don't
                // re-list and re-download it every sync; transient errors stay unhandled to retry.
                if (error as? HttpSyncError)?.skip == true {
                    markHandled(meta)
                } else {
                    markUnhandled(meta)
                }
            }
        }

        // Pass 4: metadata shelf placement now that local roots exist.
        let shelfSnapshot = ShelfSnapshot.load()
        for (index, pair) in placementMetadataKeys.enumerated() {
            let (parsed, meta) = pair
            await onProgress(HttpSyncProgress(
                message: "Applying bookshelf folders",
                detail: "Book \(index + 1) of \(placementMetadataKeys.count): \(parsed.syncId)",
                completed: index,
                total: placementMetadataKeys.count
            ))
            do {
                let applied = try await applyShelfPlacementFromRemote(
                    syncId: parsed.syncId,
                    bookId: localBookId(localBooks, parsed.syncId),
                    meta: meta,
                    snapshot: shelfSnapshot,
                    shelfState: &shelfState
                )
                if applied == .missingLocal { markUnhandled(meta) } else { markHandled(meta) }
            } catch {
                result.errors.append("metadata \(parsed.syncId): \(errorText(error))")
                markUnhandled(meta)
            }
        }
        HttpSyncShelfStateStore.save(shelfState)

        // Pass 5: bookmarks and chats now find their local roots.
        for (index, pair) in bookmarksAndChats.enumerated() {
            let (parsed, meta) = pair
            await onProgress(HttpSyncProgress(
                message: "Applying remote reading data",
                detail: "Item \(index + 1) of \(bookmarksAndChats.count): \(kindLabel(parsed.kind)) for \(parsed.syncId)",
                completed: index,
                total: bookmarksAndChats.count
            ))
            if deletedSyncIds.contains(parsed.syncId) { markHandled(meta); continue }
            guard let root = rootsBySyncId[parsed.syncId] else { markUnhandled(meta); continue }
            do {
                switch parsed.kind {
                case .bookmark:
                    if try await applyBookmarkFromRemote(root: root, meta: meta) { result.downloadedBookmarks += 1 }
                case .chat:
                    if try await applyChatEntryFromRemote(root: root, meta: meta) { result.downloadedChatEntries += 1 }
                case .pretranslations:
                    if try await applyPretranslationsFromRemote(root: root, meta: meta) { result.downloadedPretranslations += 1 }
                case .sentences:
                    if try await applySentenceTranslationsFromRemote(
                        root: root,
                        syncId: parsed.syncId,
                        meta: meta
                    ) { result.downloadedPretranslations += 1 }
                default: break
                }
                markHandled(
                    meta,
                    localArtifact: localArtifactAfterApplying(root: root, kind: parsed.kind)
                )
            } catch {
                result.errors.append("\(parsed.syncId): \(errorText(error))")
                markUnhandled(meta)
            }
        }

        for (id, root) in rootsBySyncId where !deletedSyncIds.contains(id) && !pendingTombstoneSyncIds.contains(id) {
            do {
                try await HttpReadingStatisticsSync.shared.exchange(root: root, syncId: id, transport: transport, listing: statisticsMetas)
                for key in ["books/\(id)/statistics", "books/\(id)/manga_statistics"] {
                    if let meta = statisticsMetas[key] { markHandled(meta) }
                }
            } catch { result.errors.append("Statistics \(id): \(errorText(error))") }
        }

        // Plain loop, not `.filter{}.count`: a @MainActor closure into a stdlib generic carries a
        // dynamic executor check that traps if this runs off the main actor (see safeNewCursor).
        var remoteOnly = 0
        for id in remoteSyncIds where rootsBySyncId[id] == nil && !deletedSyncIds.contains(id) {
            remoteOnly += 1
        }
        result.remoteOnlyBooks = remoteOnly
        flushAppliedKeys()
        return cursor
    }

    private func localBookId(_ books: [LocalBook], _ syncId: String) -> UUID? {
        // Plain loop, not `.first {…}` — a @MainActor closure into a stdlib generic traps when this
        // runs off the main actor (this exact site crashed; see safeNewCursor).
        for book in books where book.syncId == syncId { return book.id }
        return nil
    }

    /// The applied-key ledger is only an optimization; it cannot stand in for the local data it
    /// claims was committed. This check is deliberately specific to each reading-data kind.
    private func localReadingArtifactIsPresent(
        root: URL,
        parsed: ParsedBookKey,
        key: String,
        applied: HttpSyncAppliedKeyRecord
    ) -> Bool {
        switch parsed.kind {
        case .bookmark:
            return BookStorage.loadBookmark(root: root) != nil
        case .chat:
            guard ContentType.detect(bookDir: root) == .mokuro else { return true }
            for entry in loadChatLog(root: root).entries {
                let suffix = chatEntryKeySuffix(
                    timestampAppleSeconds: entry.timestampSeconds,
                    bubbleText: entry.bubbleText,
                    response: entry.response
                )
                if SyncKeys.chat(parsed.syncId, suffix: suffix) == key { return true }
            }
            return false
        case .pretranslations:
            guard ContentType.detect(bookDir: root) == .mokuro else { return true }
            return applied.localArtifact?.matches(
                root.appendingPathComponent(FileNames.pretranslations)
            ) == true
        case .sentences:
            guard ContentType.detect(bookDir: root) == .epub else { return true }
            return applied.localArtifact?.matches(
                root.appendingPathComponent(FileNames.sentenceTranslations)
            ) == true
        default:
            return false
        }
    }

    private func localArtifactAfterApplying(
        root: URL,
        kind: BookKeyKind
    ) -> HttpSyncAppliedLocalArtifact? {
        switch kind {
        case .pretranslations:
            return HttpSyncAppliedLocalArtifact(
                fileURL: root.appendingPathComponent(FileNames.pretranslations)
            )
        case .sentences:
            return HttpSyncAppliedLocalArtifact(
                fileURL: root.appendingPathComponent(FileNames.sentenceTranslations)
            )
        default:
            return nil
        }
    }

    private struct RemoteMetadata { let blob: HttpSyncMetadataBlob; let hasShelfName: Bool }

    private func fetchRemoteMetadata(key: String) async throws -> RemoteMetadata? {
        guard let fetched = try await transport.get(key: key) else { return nil }
        do {
            let blob = try jsonDecoder.decode(HttpSyncMetadataBlob.self, from: fetched.body)
            let hasShelfName = jsonHasKey(fetched.body, "shelfName")
            return RemoteMetadata(blob: blob, hasShelfName: hasShelfName)
        } catch {
            throw HttpSyncError("Metadata at \(key): malformed JSON.")
        }
    }

    private func applyBookmarkFromRemote(root: URL, meta: HttpSyncKvKeyMeta) async throws -> Bool {
        guard let fetched = try await transport.get(key: meta.key) else { return false }
        let blob: HttpSyncBookmarkBlob
        do {
            blob = try jsonDecoder.decode(HttpSyncBookmarkBlob.self, from: fetched.body)
        } catch {
            throw HttpSyncError("Bookmark at \(meta.key): malformed JSON.")
        }
        let local = BookStorage.loadBookmark(root: root)
        var localModified: String? = nil
        if let lm = local?.lastModified { localModified = rfc3339(from: lm) }
        let localRev = HttpSyncRevisionStore.current(meta.key).localRev
        // Don't downgrade: apply only when the remote edit chain is deeper (timestamps break
        // ties; legacy blobs without rev keep the old pure-timestamp behavior).
        guard compareRevisioned(localRev: localRev, remoteRev: blob.rev,
                                localStamp: localModified, remoteStamp: blob.lastModified) == .remoteWins else {
            HttpSyncRevisionStore.noteRemote(meta.key, rev: blob.rev, appliedLocally: false)
            return false
        }
        let bookmark = Bookmark(
            chapterIndex: blob.chapterIndex,
            progress: blob.progress,
            characterCount: blob.characterCount,
            lastModified: Date(timeIntervalSinceReferenceDate: rfc3339ToAppleSeconds(blob.lastModified))
        )
        try BookStorage.save(bookmark, inside: root, as: FileNames.bookmark)
        HttpSyncRevisionStore.noteRemote(meta.key, rev: blob.rev, appliedLocally: true)
        if let parsed = parseBookKey(meta.key), case .bookmark = parsed.kind {
            NotificationCenter.default.post(
                name: .httpSyncBookmarkApplied,
                object: nil,
                userInfo: ["syncId": parsed.syncId]
            )
        }
        return true
    }

    private func applyChatEntryFromRemote(root: URL, meta: HttpSyncKvKeyMeta) async throws -> Bool {
        guard ContentType.detect(bookDir: root) == .mokuro else { return false }
        guard let fetched = try await transport.get(key: meta.key) else { return false }
        let blob: HttpSyncChatEntryBlob
        do {
            blob = try jsonDecoder.decode(HttpSyncChatEntryBlob.self, from: fetched.body)
        } catch {
            throw HttpSyncError("Chat entry at \(meta.key): malformed JSON.")
        }
        let incoming = blob.toEntry()
        var log = loadChatLog(root: root)
        for existingEntry in log.entries where existingEntry.matchesEntry(incoming) { return false }
        log.entries.append(incoming)
        try saveChatLog(log, root: root)
        return true
    }

    /// Pulls a volume's offline pre-translation blob to `pretranslations.json` in the book dir.
    ///
    /// Download-only by design: these are produced by the desktop tool, never edited on device, so
    /// there is no push side and no conflict resolution — the server copy always wins. Writing the
    /// raw body avoids a decode/re-encode round-trip on a file that can hold thousands of entries;
    /// it is validated by decoding into the blob type first so a truncated download can't replace
    /// a good local cache.
    private func applyPretranslationsFromRemote(root: URL, meta: HttpSyncKvKeyMeta) async throws -> Bool {
        // Not a manga book: this key can never apply here, so returning false (→ markHandled) is
        // correct and stops it being re-listed forever.
        guard ContentType.detect(bookDir: root) == .mokuro else { return false }
        let target = root.appendingPathComponent(FileNames.pretranslations)
        // Identity is the listed ETag recorded in the applied-key ledger. Byte length is not an
        // identity check: a replacement translation set can be different but exactly the same size.
        // A 404 on a key the server JUST listed is anomalous — throw so the caller marks it
        // UNHANDLED and retries next sync. Returning false here would write the key into the
        // durable applied-key ledger, and because pretranslations are download-only with no push
        // side, nothing would ever fetch it again.
        guard let fetched = try await transport.get(key: meta.key) else {
            throw HttpSyncError("Offline translations at \(meta.key): listed but missing.")
        }
        let blob: HttpSyncPretranslationsBlob
        do {
            blob = try jsonDecoder.decode(HttpSyncPretranslationsBlob.self, from: fetched.body)
        } catch {
            throw HttpSyncError("Offline translations at \(meta.key): malformed JSON.")
        }
        // Every field decodes leniently, so "valid JSON" alone is far too weak a check: an `{}`
        // body, or a proxy error page returned with HTTP 200, would decode to an empty blob and
        // overwrite a perfectly good local cache. Require the payload to actually carry entries
        // and to be a version this build understands.
        guard blob.version <= HttpSyncPretranslationsBlob.supportedVersion else {
            throw HttpSyncError("Offline translations at \(meta.key): unsupported version \(blob.version).")
        }
        guard !blob.entries.isEmpty else {
            throw HttpSyncError("Offline translations at \(meta.key): no entries.")
        }
        try fetched.body.write(to: target, options: .atomic)
        PretranslationStore.invalidate(root: root)
        return true
    }

    /// Pulls a novel's offline sentence-translation blob to `sentence_translations.json`.
    ///
    /// The EPUB counterpart of `applyPretranslationsFromRemote`, with one deliberate difference:
    /// the validate-and-write happens on a detached task. A novel's blob is 1–5 MB against a manga
    /// volume's few hundred KB, and this reconciler is `@MainActor` — decoding that inline would
    /// visibly hitch the UI mid-"Sync now".
    private func applySentenceTranslationsFromRemote(
        root: URL,
        syncId expectedSyncId: String,
        meta: HttpSyncKvKeyMeta
    ) async throws -> Bool {
        guard ContentType.detect(bookDir: root) == .epub else { return false }
        guard let localMetadata = BookStorage.loadMetadata(root: root),
              syncId(for: localMetadata) == expectedSyncId else {
            throw HttpSyncError(
                "Sentence translations at \(meta.key): key syncId does not match the local book."
            )
        }
        guard let document = try? BookStorage.loadEpub(root) else {
            throw HttpSyncError(
                "Sentence translations at \(meta.key): local EPUB cannot be parsed."
            )
        }
        let expectedSpineCount = document.spine.items.count
        let target = root.appendingPathComponent(FileNames.sentenceTranslations)
        guard let fetched = try await transport.get(key: meta.key) else {
            throw HttpSyncError("Sentence translations at \(meta.key): listed but missing.")
        }
        let body = fetched.body
        let key = meta.key
        try await Task.detached(priority: .utility) {
            let blob: HttpSyncSentencesBlob
            do {
                blob = try JSONDecoder().decode(HttpSyncSentencesBlob.self, from: body)
            } catch {
                throw HttpSyncError("Sentence translations at \(key): malformed JSON.")
            }
            if let violation = blob.validationError(
                expectedSyncId: expectedSyncId,
                spineCount: expectedSpineCount
            ) {
                throw HttpSyncError("Sentence translations at \(key): \(violation).")
            }
            try body.write(to: target, options: .atomic)
        }.value
        EpubTranslationStore.invalidate(root: root)
        return true
    }

    // MARK: - Shelf placement

    private enum ShelfApplyResult { case applied, noop, missingLocal }

    private func applyShelfPlacementFromRemote(
        syncId: String,
        bookId: UUID?,
        meta: HttpSyncKvKeyMeta,
        snapshot: ShelfSnapshot,
        shelfState: inout [String: HttpSyncShelfPlacementRecord]
    ) async throws -> ShelfApplyResult {
        guard let remote = try await fetchRemoteMetadata(key: meta.key) else {
            throw HttpSyncError("Metadata at \(meta.key): missing.")
        }
        if remote.blob.deletedAt != nil {
            // Tombstones were already applied in pass 2; nothing to place.
            return .noop
        }
        guard let bookId else { return .missingLocal }
        guard remote.hasShelfName else { return .noop }

        let localShelfName = snapshot.shelfName(for: bookId)
        let localUpdatedAt = localShelfUpdatedAt(syncId: syncId, shelfName: localShelfName, snapshot: snapshot, state: shelfState)
        if shouldApplyRemoteShelfPlacement(remoteShelfUpdatedAt: remote.blob.shelfUpdatedAt, localShelvesUpdatedAt: localUpdatedAt) {
            let normalized = normalizeShelfName(remote.blob.shelfName)
            applyShelfPlacement(bookId: bookId, shelfName: normalized)
            if let stamp = remoteShelfPlacementStamp(shelfName: normalized, shelfUpdatedAt: remote.blob.shelfUpdatedAt, metadataModifiedAt: meta.lastModified) {
                shelfState[syncId] = HttpSyncShelfPlacementRecord(shelfName: normalized, updatedAt: stamp)
            } else {
                shelfState.removeValue(forKey: syncId)
            }
            return .applied
        }
        return .noop
    }

    private func localShelfUpdatedAt(
        syncId: String,
        shelfName: String?,
        snapshot: ShelfSnapshot,
        state: [String: HttpSyncShelfPlacementRecord]
    ) -> String? {
        if let record = state[syncId], record.shelfName == shelfName { return record.updatedAt }
        if state[syncId] != nil || shelfName != nil {
            return snapshot.shelvesUpdatedAt ?? rfc3339Now()
        }
        return nil
    }

    private func normalizeShelfName(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Mutates `shelves.json`: remove `bookId` from every shelf, then add it to the target shelf
    /// (creating the shelf if needed). `nil` shelfName leaves the book unshelved.
    private func applyShelfPlacement(bookId: UUID, shelfName: String?) {
        var shelves = BookStorage.loadShelves() ?? []
        // Plain loops, not removeAll{…}/firstIndex(where:) — @MainActor closures into stdlib
        // generics trap when this runs off the main actor (see safeNewCursor).
        for i in shelves.indices {
            var kept: [UUID] = []
            for id in shelves[i].bookIds where id != bookId { kept.append(id) }
            shelves[i].bookIds = kept
        }
        if let shelfName {
            var targetIdx: Int? = nil
            for i in shelves.indices where shelves[i].name == shelfName { targetIdx = i; break }
            if let idx = targetIdx {
                if !shelves[idx].bookIds.contains(bookId) { shelves[idx].bookIds.append(bookId) }
            } else {
                shelves.append(BookShelf(name: shelfName, bookIds: [bookId]))
            }
        }
        guard let booksDir = try? BookStorage.getBooksDirectory() else { return }
        try? BookStorage.save(shelves, inside: booksDir, as: FileNames.shelves)
    }

    // MARK: - Remote-only import

    private func importRemoteOnlyBook(syncId: String, format: ContentType) async throws -> URL? {
        guard let booksDir = try? BookStorage.getBooksDirectory() else { return nil }
        let keys = HttpSyncPayloadKeys.forFormat(format, syncId: syncId)
        // Free-space preflight: refuse a multi-GB download we could never unpack. Without this, a
        // low-storage device downloads the whole payload, fails to unzip (disk full), deletes it,
        // and — because the cursor never advances past it — re-downloads the SAME GB on every sync,
        // forever. Throwing `skip: true` makes Pass 3 advance the cursor and surface an error instead.
        if let manifest = try await payloadCodec.fetchManifest(transport: transport, keys: keys) {
            guard manifest.format == format else {
                throw HttpSyncError(
                    "Payload manifest for \(syncId) declares \(manifest.format.rawValue), "
                    + "but its key requires \(format.rawValue)."
                )
            }
            if manifest.sizeBytes > 0 {
                // 3× the compressed zip size: zip on disk during download + the unzipped copy
                // (which can be larger for text/JSON) + headroom.
                let needed = Int64(Double(manifest.sizeBytes) * 3.0)
                if let free = availableCapacityBytes(at: booksDir), free < needed {
                    let needGB = String(format: "%.1f", Double(needed) / 1_000_000_000)
                    let freeGB = String(format: "%.1f", Double(free) / 1_000_000_000)
                    throw HttpSyncError(
                        "Skipped \(syncId): need ~\(needGB) GB free to import, "
                        + "only \(freeGB) GB available.",
                        skip: true
                    )
                }
            }
        }
        let targetRoot = booksDir.appendingPathComponent(syncId, isDirectory: true)
        // Avoid colliding with an existing directory; uniquify if needed.
        let root = uniqueDirectory(base: targetRoot)
        do {
            let manifest = try await payloadCodec.downloadAndUnpack(
                transport: transport,
                syncId: syncId,
                keys: keys,
                expectedFormat: format,
                targetDir: root
            )
            let detected = ContentType.detect(bookDir: root)
            guard detected == format else {
                throw HttpSyncError(
                    "Payload for \(syncId) unpacked as \(detected.rawValue), expected \(format.rawValue)."
                )
            }
            // Prefer a cover.jpg shipped in the payload; otherwise generate one from page 1 (mokuro)
            // so synced books show a cover like locally-imported ones do. Cross-platform / ッツ
            // payloads frequently omit cover.jpg, which is why synced book covers were blank.
            // An EPUB is parsed once here and reused for both the cover and bookinfo below.
            // `resolveImportedCoverPath` only knows how to find a literal `cover.jpg`, but a local
            // EPUB import copies the cover under its manifest href's basename (e.g. `00023.jpeg`),
            // so a synced novel arrived with a blank shelf tile until we ask the document itself.
            let epubDocument: EPUBDocument?
            if format == .epub {
                guard let parsed = try? BookStorage.loadEpub(root) else {
                    throw HttpSyncError("Payload for \(syncId) is not a parseable EPUB.")
                }
                epubDocument = parsed
            } else {
                epubDocument = nil
            }
            let cover = resolveImportedCoverPath(root: root, folder: root.lastPathComponent)
                ?? epubCoverPath(document: epubDocument, root: root)
                ?? generateMokuroCoverIfMissing(root: root, contentType: detected)
            let metadata = BookMetadata(
                id: UUID(),
                title: manifest.originalName,
                cover: cover,
                folder: root.lastPathComponent,
                lastAccess: Date(timeIntervalSince1970: 0),
                contentType: detected,
                importedAt: rfc3339Now(),
                syncId: syncId
            )
            try BookStorage.save(metadata, inside: root, as: FileNames.metadata)
            // Character counts for EPUB. Without `bookinfo.json` the book opens with
            // `characterCount == 0`: no progress on the shelf, and `resolveCharacterPosition`
            // cannot place an incoming bookmark from another device.
            if detected == .epub, let document = epubDocument, BookStorage.loadBookInfo(root: root) == nil {
                try? BookStorage.save(BookProcessor.process(document: document), inside: root, as: FileNames.bookinfo)
            }
            // Page-based progress for mokuro so the shelf shows a progress bar before first open.
            if detected == .mokuro, BookStorage.loadBookInfo(root: root) == nil {
                let pageCount = countImages(in: root.appendingPathComponent(FileNames.mokuroImages))
                if pageCount > 0 {
                    let info = BookInfo(characterCount: pageCount, chapterInfo: [:])
                    try? BookStorage.save(info, inside: root, as: FileNames.bookinfo)
                }
            }
            return root
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    /// Replaces an existing book only when its one-time local content hash differs from a
    /// current-format remote manifest. Pre-map books compute that baseline once on upgrade.
    private func refreshExistingBookPayload(syncId: String, format: ContentType, root: URL) async throws -> Bool {
        // Reader persistence does not share the reconciler's directory-swap lock. Defer until
        // onDisappear closes the registry and immediately schedules another cheap preflight.
        if HttpSyncActiveBooks.contains(syncId) { return false }
        let keys = HttpSyncPayloadKeys.forFormat(format, syncId: syncId)
        guard let remote = try await payloadCodec.fetchManifest(transport: transport, keys: keys) else {
            return false
        }
        if payloadCodec.hasPayloadContentDirty(bookRoot: root) { return false }
        let cachedSha: String
        if let cached = payloadCodec.cachedPayloadSha(bookRoot: root) {
            cachedSha = cached
        } else {
            cachedSha = try await payloadCodec.ensurePayloadContentSha(bookRoot: root)
        }
        if let remoteContentSha = remote.contentSha256, cachedSha == remoteContentSha { return false }
        // The server still points at the exact archive this install uploaded or installed, so the
        // content-hash disagreement is a derivation difference between clients, never new content.
        // Chasing it with a download would have two clients that hash differently trade the same
        // archive back and forth forever. (A manifest with no content hash at all is still
        // downloaded once so the verified hash gets published.)
        if remote.contentSha256 != nil, remote.sha256 == payloadCodec.cachedZipSha(bookRoot: root) { return false }
        // The cached baseline disagrees with the server. Re-derive it from the bytes on disk
        // before paying for a download: a stale or mis-derived sidecar (every one written by
        // builds through 0.11.3) is far cheaper to fix locally than a replacement that installs
        // identical content.
        let localSha = try await payloadCodec.refreshPayloadContentSha(bookRoot: root)
        if let remoteContentSha = remote.contentSha256, localSha == remoteContentSha {
            // The bytes on disk are the archive the manifest describes, so a book that predates
            // the archive sidecar gains the baseline the guard above needs.
            payloadCodec.rememberZipSha(bookRoot: root, sha: remote.sha256)
            return false
        }
        if let remoteContentSha = remote.contentSha256 {
            // Candidate receiver-materialized covers: the mokuro convention plus whatever file
            // this book's metadata actually points at (EPUB covers use the manifest basename).
            var candidates = ["cover.jpg"]
            if let cover = BookStorage.loadMetadata(root: root)?.cover {
                let name = URL(fileURLWithPath: cover).lastPathComponent
                if !candidates.contains(name) { candidates.append(name) }
            }
            if payloadCodec.migrateLegacyGeneratedCover(
                bookRoot: root, expectedSha: remoteContentSha, candidateNames: candidates
            ) {
                if var metadata = BookStorage.loadMetadata(root: root) {
                    metadata.cover = "Books/\(root.lastPathComponent)/\(FileNames.generatedCover)"
                    try? BookStorage.save(metadata, inside: root, as: FileNames.metadata)
                }
                return false
            }
        }
        guard let booksDir = try? BookStorage.getBooksDirectory() else { return false }
        let staging = uniqueDirectory(
            base: booksDir.appendingPathComponent(".hoshi-sync-update-\(UUID().uuidString)", isDirectory: true)
        )
        do {
            let manifest = try await payloadCodec.downloadAndUnpack(
                transport: transport,
                syncId: syncId,
                keys: keys,
                expectedFormat: format,
                targetDir: staging
            )
            let detected = ContentType.detect(bookDir: staging)
            guard detected == manifest.format else {
                throw HttpSyncError(
                    "Payload for \(syncId) unpacked as \(detected.rawValue), expected \(manifest.format.rawValue)."
                )
            }
            var replacementBookInfo: BookInfo?
            if format == .epub {
                guard let document = try? BookStorage.loadEpub(staging) else {
                    throw HttpSyncError("Payload for \(syncId) is not a parseable EPUB.")
                }
                replacementBookInfo = BookProcessor.process(document: document)
            }
            // downloadAndUnpack already republished the manifest if its declared hash was
            // missing or wrong, so the remote note now matches this verified value.
            guard let verifiedRemoteSha = manifest.contentSha256 else {
                throw HttpSyncError("Downloaded payload did not produce a verified content hash.")
            }
            if localSha == verifiedRemoteSha {
                // Staging is discarded here; the real book root holds this exact archive, so
                // remember it there or the next foreign hash costs this download again.
                payloadCodec.rememberZipSha(bookRoot: root, sha: manifest.sha256)
                try? FileManager.default.removeItem(at: staging)
                return false
            }
            if let replacementBookInfo {
                // Derived state belongs to the staged generation so directory swap + crash
                // recovery publish it atomically with the EPUB bytes.
                try BookStorage.save(replacementBookInfo, inside: staging, as: FileNames.bookinfo)
            }
            // The reader may have opened while the replacement archive downloaded.
            if HttpSyncActiveBooks.contains(syncId) {
                try? FileManager.default.removeItem(at: staging)
                return false
            }
            try payloadCodec.installReplacement(bookRoot: root, stagingRoot: staging, sha: verifiedRemoteSha)
            return true
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// Generates a cover from the first mokuro page when the synced payload didn't ship one, so
    /// synced manga show a cover instead of a blank placeholder. Writes the hash-excluded
    /// `FileNames.generatedCover` (never `cover.jpg`) so the local payload keeps matching the
    /// origin's manifest. Returns the relative cover path, or nil (non-mokuro / no pages /
    /// generation failed — the shelf tolerates a nil cover).
    private func generateMokuroCoverIfMissing(root: URL, contentType: ContentType) -> String? {
        guard contentType == .mokuro else { return nil }
        let target = root.appendingPathComponent(FileNames.generatedCover)
        if FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) {
            return "Books/\(root.lastPathComponent)/\(FileNames.generatedCover)"
        }
        let imagesDir = root.appendingPathComponent(FileNames.mokuroImages)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: imagesDir.path(percentEncoded: false)) else { return nil }
        // First image by sorted filename ≈ page 1 (manga pages are zero-padded). Plain loop, no
        // stdlib closure (off-main executor-trap safety).
        var firstName: String? = nil
        for name in names.sorted() where !name.hasPrefix(".") { firstName = name; break }
        guard let firstName else { return nil }
        do {
            try MokuroCover.generateThumbnail(
                from: imagesDir.appendingPathComponent(firstName),
                to: target
            )
            return "Books/\(root.lastPathComponent)/\(FileNames.generatedCover)"
        } catch {
            return nil
        }
    }

    /// Bytes the OS will let us use on the volume backing `url` (accounts for purgeable space).
    private func availableCapacityBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private func resolveImportedCoverPath(root: URL, folder: String) -> String? {
        let cover = root.appendingPathComponent("cover.jpg")
        if FileManager.default.fileExists(atPath: cover.path(percentEncoded: false)) {
            return "Books/\(folder)/cover.jpg"
        }
        return nil
    }

    /// Resolves (and materializes) a synced EPUB's cover the way a local import does.
    ///
    /// A local import copies the manifest's cover image to `Books/{folder}/{basename}` and stores
    /// that relative path. The synced copy already contains the image somewhere inside the unpacked
    /// book, so we copy it up to the same place rather than inventing a second convention.
    private func epubCoverPath(document: EPUBDocument?, root: URL) -> String? {
        guard let document, let coverPath = findEpubCoverInManifest(document: document) else { return nil }
        guard let source = document.resourceURL(for: coverPath) else { return nil }
        let name = source.lastPathComponent
        let shipped = root.appendingPathComponent(name)
        let fileManager = FileManager.default
        // A root-level copy that arrived inside the payload is origin content — keep using it.
        if fileManager.fileExists(atPath: shipped.path(percentEncoded: false)) {
            return "Books/\(root.lastPathComponent)/\(name)"
        }
        // Materialize receiver-side under the hash-excluded name so the local payload keeps
        // matching the origin's manifest (same rule as generated mokuro covers). The extension
        // mismatch is fine — image loading sniffs content, not the filename.
        let generated = root.appendingPathComponent(FileNames.generatedCover)
        if !fileManager.fileExists(atPath: generated.path(percentEncoded: false)) {
            guard fileManager.fileExists(atPath: source.path(percentEncoded: false)),
                  (try? fileManager.copyItem(at: source, to: generated)) != nil else { return nil }
        }
        return "Books/\(root.lastPathComponent)/\(FileNames.generatedCover)"
    }

    /// Mirror of `BookshelfViewModel.findCoverInManifest` — EPUB3 `cover-image`, then the EPUB2
    /// `meta name="cover"` id, then loose fallbacks for files that follow neither.
    private func findEpubCoverInManifest(document: EPUBDocument) -> String? {
        if let item = document.manifest.items.values.first(where: { $0.property?.contains("cover-image") == true }) {
            return item.path
        }
        if let coverId = document.metadata.coverId, let item = document.manifest.items[coverId] {
            return item.path
        }
        let imageTypes: [EPUBMediaType] = [.jpeg, .png, .gif, .svg]
        if let item = document.manifest.items.values.first(where: { $0.id.lowercased().contains("cover") }),
           imageTypes.contains(item.mediaType) {
            return item.path
        }
        return document.manifest.items.values.first(where: { imageTypes.contains($0.mediaType) })?.path
    }

    private func countImages(in dir: URL) -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false)).count) ?? 0
    }

    private func uniqueDirectory(base: URL) -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: base.path(percentEncoded: false)) { return base }
        var i = 2
        while true {
            let candidate = base.deletingLastPathComponent()
                .appendingPathComponent("\(base.lastPathComponent)_\(i)", isDirectory: true)
            if !fm.fileExists(atPath: candidate.path(percentEncoded: false)) { return candidate }
            i += 1
        }
    }

    // MARK: - Outbound

    private func pushAllLocal(
        into result: inout HttpSyncResult,
        onProgress: @escaping @Sendable (HttpSyncProgress) async -> Void
    ) async {
        let localBooks = loadLocalBooks()
        let snapshot = ShelfSnapshot.load()
        var shelfState = HttpSyncShelfStateStore.load()
        var payloadBookCount = 0
        // Both formats now upload a payload, so the progress denominator must count both — a
        // mokuro-only count made the bar run past its total as soon as a novel was uploaded.
        for _ in localBooks { payloadBookCount += 1 }
        var payloadBookIndex = 0

        // Pass 0: push pending deleted-book tombstones. For each staged delete, PUT a metadata
        // blob with `deletedAt` set so the deletion propagates to other devices; clear the record
        // only after a successful PUT (so a transient failure retries next sync). A tombstone whose
        // syncId now matches a live local book (delete-then-re-import before sync) is pruned without
        // a push so the live book's normal metadata push wins. Mirrors Android's tombstone loop.
        let pendingDeleted = HttpSyncDeletedBookStore.all()
        if !pendingDeleted.isEmpty {
            var liveLocalSyncIds: Set<String> = []
            for b in localBooks { liveLocalSyncIds.insert(b.syncId) }
            for syncId in pendingDeleted.keys where liveLocalSyncIds.contains(syncId) {
                HttpSyncDeletedBookStore.remove(syncId: syncId)
                shelfState.removeValue(forKey: syncId)
            }
            for (syncId, record) in pendingDeleted where !liveLocalSyncIds.contains(syncId) {
                await onProgress(HttpSyncProgress(
                    message: "Uploading deleted book markers",
                    detail: record.title
                ))
                do {
                    let metadataKey = SyncKeys.metadata(syncId)
                    // The fire-and-forget delete hook usually already pushed this tombstone at a
                    // bumped rev: skip the redundant PUT (which would also regress the server's
                    // rev to 0) when the remote already carries the same deletedAt.
                    var remoteBlob: HttpSyncMetadataBlob?
                    if let remote = try await transport.get(key: metadataKey) {
                        remoteBlob = try? jsonDecoder.decode(HttpSyncMetadataBlob.self, from: remote.body)
                    }
                    if let remoteBlob, remoteBlob.deletedAt == record.deletedAt {
                        HttpSyncRevisionStore.noteRemote(metadataKey, rev: remoteBlob.rev, appliedLocally: true)
                        HttpSyncDeletedBookStore.remove(syncId: syncId)
                        shelfState.removeValue(forKey: syncId)
                        continue
                    }
                    let uploadRev = max(HttpSyncRevisionStore.current(metadataKey).localRev, remoteBlob?.rev ?? 0)
                    let blob = HttpSyncMetadataBlob(
                        title: record.title,
                        contentType: record.contentType,
                        importedAt: nil,
                        deletedAt: record.deletedAt,
                        rev: uploadRev
                    )
                    _ = try await transport.put(
                        key: metadataKey,
                        contentType: Self.jsonContentType,
                        body: try jsonEncoder.encode(blob)
                    )
                    HttpSyncRevisionStore.noteRemote(metadataKey, rev: uploadRev, appliedLocally: true)
                    result.uploadedMetadata += 1
                    // Only clear after the PUT succeeds — atomic remove re-reads disk so a delete
                    // staged for a different syncId mid-sync survives.
                    HttpSyncDeletedBookStore.remove(syncId: syncId)
                    shelfState.removeValue(forKey: syncId)
                } catch {
                    result.errors.append("\(record.title): \(errorText(error))")
                }
            }
        }

        for (index, book) in localBooks.enumerated() {
            do {
                await onProgress(HttpSyncProgress(
                    message: "Uploading local book state",
                    detail: "Book \(index + 1) of \(localBooks.count): \(book.title)",
                    completed: index,
                    total: localBooks.count
                ))
                let remoteMetadata = try await fetchRemoteMetadataForUpload(key: SyncKeys.metadata(book.syncId))
                let remoteDeletedAt = remoteMetadata?.blob.deletedAt
                let tombstoneOverridden = remoteDeletedAt != nil &&
                    localImportedAtOverridesRemoteDeletion(localImportedAt: book.importedAt, remoteDeletedAt: remoteDeletedAt)
                if remoteDeletedAt != nil && !tombstoneOverridden {
                    // Server says deleted and we didn't re-import after the tombstone: honour it.
                    if HttpSyncActiveBooks.contains(book.syncId) {
                        result.errors.append("\(book.title): deletion deferred while this book is open")
                        continue
                    }
                    deleteBook(root: book.root, bookId: book.id)
                    shelfState.removeValue(forKey: book.syncId)
                    continue
                }

                // Shelf placement to upload (with LWW against a fresher remote placement).
                var uploadShelfName = snapshot.shelfName(for: book.id)
                var uploadShelfUpdatedAt = localShelfUpdatedAt(
                    syncId: book.syncId, shelfName: uploadShelfName, snapshot: snapshot, state: shelfState
                )
                if let remoteMetadata, remoteMetadata.hasShelfName,
                   shouldApplyRemoteShelfPlacement(remoteShelfUpdatedAt: remoteMetadata.blob.shelfUpdatedAt, localShelvesUpdatedAt: uploadShelfUpdatedAt) {
                    uploadShelfName = normalizeShelfName(remoteMetadata.blob.shelfName)
                    uploadShelfUpdatedAt = remoteShelfPlacementStamp(shelfName: uploadShelfName, shelfUpdatedAt: remoteMetadata.blob.shelfUpdatedAt, metadataModifiedAt: remoteMetadata.lastModified)
                    applyShelfPlacement(bookId: book.id, shelfName: uploadShelfName)
                    if let stamp = uploadShelfUpdatedAt {
                        shelfState[book.syncId] = HttpSyncShelfPlacementRecord(shelfName: uploadShelfName, updatedAt: stamp)
                    } else {
                        shelfState.removeValue(forKey: book.syncId)
                    }
                }

                // Bookmark — only if local is strictly newer than the server's.
                if let bookmark = BookStorage.loadBookmark(root: book.root) {
                    if try await pushBookmarkIfLocalNewer(syncId: book.syncId, local: bookmark, root: book.root) {
                        result.uploadedBookmarks += 1
                    }
                }

                // Metadata — preserve / advance importedAt; clear deletedAt iff we overrode the tombstone.
                let uploadImportedAt = tombstoneOverridden
                    ? book.importedAt
                    : maxRfc(remoteMetadata?.blob.importedAt, book.importedAt)
                let uploadDeletedAt = tombstoneOverridden ? nil : remoteMetadata?.blob.deletedAt
                let metadataKey = SyncKeys.metadata(book.syncId)
                let localRev = HttpSyncRevisionStore.current(metadataKey).localRev
                // Reconcile pushes merged state, not a new edit: carry the max of both revs
                // forward without bumping (only deliberate edits bump, via the hooks).
                let uploadRev = max(localRev, remoteMetadata?.blob.rev ?? 0)
                let metaBlob = HttpSyncMetadataBlob(
                    title: book.title,
                    contentType: book.contentType,
                    shelfName: uploadShelfName,
                    shelfUpdatedAt: uploadShelfUpdatedAt,
                    importedAt: uploadImportedAt,
                    deletedAt: uploadDeletedAt,
                    rev: uploadRev
                )
                var remoteForCompare = remoteMetadata?.blob
                remoteForCompare?.rev = metaBlob.rev
                if remoteForCompare == metaBlob {
                    // Content identical to the server's — skip the PUT entirely.
                    HttpSyncRevisionStore.noteRemote(metadataKey, rev: uploadRev, appliedLocally: true)
                } else {
                    _ = try await transport.put(
                        key: metadataKey,
                        contentType: Self.jsonContentType,
                        body: try jsonEncoder.encode(metaBlob)
                    )
                    HttpSyncRevisionStore.noteRemote(metadataKey, rev: uploadRev, appliedLocally: true)
                    result.uploadedMetadata += 1
                }
                if let uploadShelfUpdatedAt {
                    shelfState[book.syncId] = HttpSyncShelfPlacementRecord(shelfName: uploadShelfName, updatedAt: uploadShelfUpdatedAt)
                } else {
                    shelfState.removeValue(forKey: book.syncId)
                }

                // Payload — upload once if the server lacks a manifest. Mokuro goes to
                // `payload.*`, EPUB to `epub.*` (see HttpSyncPayloadKeys).
                do {
                    let currentPayloadIndex = payloadBookIndex
                    payloadBookIndex += 1
                    await onProgress(HttpSyncProgress(
                        message: book.contentType == .mokuro
                            ? "Checking manga payload upload"
                            : "Checking book payload upload",
                        detail: "Book \(currentPayloadIndex + 1) of \(payloadBookCount): \(book.title)",
                        completed: currentPayloadIndex,
                        total: payloadBookCount
                    ))
                    let uploaded = try await payloadCodec.uploadIfChanged(
                        transport: transport,
                        syncId: book.syncId,
                        bookRoot: book.root,
                        originalName: book.title,
                        format: book.contentType
                    )
                    if uploaded { result.uploadedPayloads += 1 }
                }

                // Chat entries (mokuro only) — push only entries the server doesn't already have.
                if book.contentType == .mokuro {
                    let entries = loadChatLog(root: book.root).entries
                    if !entries.isEmpty {
                        var existing: Set<String> = []
                        try await transport.listAll(prefix: SyncKeys.chatPrefix(book.syncId), since: nil) { meta in
                            existing.insert(meta.key)
                        }
                        // Plain loop (not compactMap) so no @MainActor closure hits a stdlib generic
                        // and trips the off-main executor check — same crash class as safeNewCursor.
                        var missing: [(key: String, entry: AiChatEntry)] = []
                        for entry in entries {
                            let suffix = chatEntryKeySuffix(timestampAppleSeconds: entry.timestampSeconds, bubbleText: entry.bubbleText, response: entry.response)
                            let key = SyncKeys.chat(book.syncId, suffix: suffix)
                            if !existing.contains(key) { missing.append((key, entry)) }
                        }
                        for (chatIndex, upload) in missing.enumerated() {
                            await onProgress(HttpSyncProgress(
                                message: "Uploading manga chat history",
                                detail: "\(book.title): chat \(chatIndex + 1) of \(missing.count)",
                                completed: chatIndex,
                                total: missing.count
                            ))
                            _ = try await transport.put(
                                key: upload.key,
                                contentType: Self.jsonContentType,
                                body: try jsonEncoder.encode(upload.entry.toBlob())
                            )
                            result.uploadedChatEntries += 1
                        }
                    }
                }
            } catch {
                result.errors.append("\(book.title): \(errorText(error))")
            }
        }
        HttpSyncShelfStateStore.save(shelfState)
    }

    private struct RemoteMetadataFetched { let blob: HttpSyncMetadataBlob; let hasShelfName: Bool; let lastModified: String }

    private func fetchRemoteMetadataForUpload(key: String) async throws -> RemoteMetadataFetched? {
        guard let fetched = try await transport.get(key: key) else { return nil }
        do {
            let blob = try jsonDecoder.decode(HttpSyncMetadataBlob.self, from: fetched.body)
            return RemoteMetadataFetched(blob: blob, hasShelfName: jsonHasKey(fetched.body, "shelfName"), lastModified: fetched.lastModified)
        } catch {
            throw HttpSyncError("metadata decode: malformed JSON.")
        }
    }

    /// Fetches the remote bookmark; if it's newer, applies it locally and returns `false` (no
    /// push). Otherwise PUTs the local bookmark and returns `true`.
    private func pushBookmarkIfLocalNewer(syncId: String, local: Bookmark, root: URL) async throws -> Bool {
        let key = SyncKeys.bookmark(syncId)
        let localRev = HttpSyncRevisionStore.current(key).localRev
        if let remote = try await transport.get(key: key),
           let remoteBlob = try? jsonDecoder.decode(HttpSyncBookmarkBlob.self, from: remote.body) {
            var localStamp: String? = nil
            if let lm = local.lastModified { localStamp = rfc3339(from: lm) }
            // The actual edit timestamp wins; revision only makes equal-time decisions stable.
            switch compareRevisioned(localRev: localRev, remoteRev: remoteBlob.rev,
                                     localStamp: localStamp, remoteStamp: remoteBlob.lastModified) {
            case .remoteWins:
                let bookmark = Bookmark(
                    chapterIndex: remoteBlob.chapterIndex,
                    progress: remoteBlob.progress,
                    characterCount: remoteBlob.characterCount,
                    lastModified: Date(timeIntervalSinceReferenceDate: rfc3339ToAppleSeconds(remoteBlob.lastModified))
                )
                try BookStorage.save(bookmark, inside: root, as: FileNames.bookmark)
                HttpSyncRevisionStore.noteRemote(key, rev: remoteBlob.rev, appliedLocally: true)
                return false
            case .tie:
                // Same depth, same stamp: nothing to push (avoids ping-pong PUTs).
                HttpSyncRevisionStore.noteRemote(key, rev: remoteBlob.rev, appliedLocally: true)
                return false
            case .localWins:
                break
            }
        }
        var blob = local.toBlob()
        blob.rev = localRev
        _ = try await transport.put(
            key: key,
            contentType: Self.jsonContentType,
            body: try jsonEncoder.encode(blob)
        )
        HttpSyncRevisionStore.noteRemote(key, rev: localRev, appliedLocally: true)
        return true
    }

    // MARK: - App-level AI chat settings (LWW)

    /// Outcome of one AI-chat-settings reconcile, applied to a `HttpSyncResult` by the caller.
    struct AppSettingsOutcome { var uploaded = false; var downloaded = false; var error: String? }

    /// Bidirectional LWW sync of the cross-device ChatGPT settings (`model` + prompts). Runs on the
    /// MAIN ACTOR because `settings` is a non-Sendable `@Observable` store. The API key is never
    /// read or written here — that field stays per-device. Mirrors Android's `syncAppSettings`.
    @MainActor
    static func syncAppSettings(transport: HttpSyncKvTransport, settings: AiSettingsSyncing) async -> AppSettingsOutcome {
        var outcome = AppSettingsOutcome()
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        let local = settings.currentBlob()

        let remoteFetched: HttpSyncKvFetched?
        do {
            remoteFetched = try await transport.get(key: SyncKeys.aiChatSettingsKey)
        } catch {
            outcome.error = "ai_chat_settings GET: \((error as? HttpSyncError)?.message ?? error.localizedDescription)"
            return outcome
        }

        var remoteBlob: HttpSyncAiChatSettingsBlob? = nil
        var remoteHasImagePrompt = false
        if let remoteFetched {
            if let blob = try? decoder.decode(HttpSyncAiChatSettingsBlob.self, from: remoteFetched.body) {
                remoteBlob = blob
                remoteHasImagePrompt = (try? JSONSerialization.jsonObject(with: remoteFetched.body) as? [String: Any])?
                    .keys.contains("imagePromptText") ?? false
            } else {
                outcome.error = "ai_chat_settings decode: malformed JSON."
                return outcome
            }
        }

        func push(_ blob: HttpSyncAiChatSettingsBlob) async {
            do {
                _ = try await transport.put(
                    key: SyncKeys.aiChatSettingsKey,
                    contentType: jsonContentType,
                    body: try encoder.encode(blob)
                )
                outcome.uploaded = true
            } catch {
                outcome.error = "ai_chat_settings PUT: \((error as? HttpSyncError)?.message ?? error.localizedDescription)"
            }
        }

        let localStamp = local?.lastModified
        let remoteStamp = remoteBlob?.lastModified

        // Only one side has a value → that side wins. Both → higher lastModified wins. Equal → no-op.
        if remoteBlob == nil, let local {
            await push(local)
            return outcome
        }
        if let remoteBlob, localStamp == nil {
            let imagePrompt = remoteHasImagePrompt ? remoteBlob.imagePromptText : (local?.imagePromptText ?? remoteBlob.imagePromptText)
            if settings.applyFromSync(model: remoteBlob.model, promptText: remoteBlob.promptText,
                                      imagePromptText: imagePrompt, remoteLastEditedAt: remoteBlob.lastModified) {
                outcome.downloaded = true
            }
            return outcome
        }
        guard let remoteBlob, let local else { return outcome }
        let cmp = compareRfc3339(localStamp, remoteStamp)
        if cmp > 0 {
            await push(local)
        } else if cmp < 0 {
            let imagePrompt = remoteHasImagePrompt ? remoteBlob.imagePromptText : local.imagePromptText
            if settings.applyFromSync(model: remoteBlob.model, promptText: remoteBlob.promptText,
                                      imagePromptText: imagePrompt, remoteLastEditedAt: remoteBlob.lastModified) {
                outcome.downloaded = true
            }
        }
        return outcome
    }

    // MARK: - Local chat-log file IO

    private func chatLogURL(root: URL) -> URL { root.appendingPathComponent(FileNames.aiChatLog) }

    private func loadChatLog(root: URL) -> AiChatLog {
        BookStorage.load(AiChatLog.self, from: chatLogURL(root: root)) ?? AiChatLog()
    }

    private func saveChatLog(_ log: AiChatLog, root: URL) throws {
        try BookStorage.save(log, inside: root, as: FileNames.aiChatLog)
    }

    // MARK: - Book deletion

    private func deleteBook(root: URL, bookId: UUID?) {
        try? BookStorage.delete(at: root)
        if let bookId {
            var shelves = BookStorage.loadShelves() ?? []
            var changed = false
            for i in shelves.indices {
                let before = shelves[i].bookIds.count
                var kept: [UUID] = []
                for id in shelves[i].bookIds where id != bookId { kept.append(id) }
                shelves[i].bookIds = kept
                if shelves[i].bookIds.count != before { changed = true }
            }
            if changed, let booksDir = try? BookStorage.getBooksDirectory() {
                try? BookStorage.save(shelves, inside: booksDir, as: FileNames.shelves)
            }
        }
    }

    // MARK: - JSON helpers

    /// Whether a JSON object body explicitly contains `key` (distinguishes "omitted" from "null"
    /// for the shelf/imagePrompt fields — matches Android's `jsonObject.containsKey(...)`).
    private func jsonHasKey(_ data: Data, _ key: String) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return obj.keys.contains(key)
    }

    private func errorText(_ error: Error) -> String {
        (error as? HttpSyncError)?.message ?? error.localizedDescription
    }
}

// MARK: - Durable inbound per-key checkpoint

/// Identity of a remote value that has been fully committed to local disk. ETag is preferred; the
/// server timestamp is the compatibility fallback for servers that do not emit ETags.
nonisolated struct HttpSyncAppliedKeyRecord: Codable, Equatable {
    var etag: String?
    var lastModified: String
    /// Signature of a separately stored reading artifact. Old ledgers decode this as nil and do one
    /// safe re-fetch; new ledgers can cheaply detect deletion/re-import without decoding a 5 MB blob.
    var localArtifact: HttpSyncAppliedLocalArtifact?

    init(meta: HttpSyncKvKeyMeta, localArtifact: HttpSyncAppliedLocalArtifact? = nil) {
        let trimmedETag = meta.etag?.trimmingCharacters(in: .whitespacesAndNewlines)
        etag = trimmedETag?.isEmpty == false ? trimmedETag : nil
        lastModified = meta.lastModified
        self.localArtifact = localArtifact
    }

    func matches(_ meta: HttpSyncKvKeyMeta) -> Bool {
        let remoteETag = meta.etag?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let etag, !etag.isEmpty, let remoteETag, !remoteETag.isEmpty {
            return etag == remoteETag
        }
        return !lastModified.isEmpty && lastModified == meta.lastModified
    }
}

/// Cheap coherence marker for large download-only files. Atomic replacement changes both the file
/// metadata and this ledger record; a missing or replaced artifact therefore defeats an ETag skip.
nonisolated struct HttpSyncAppliedLocalArtifact: Codable, Equatable {
    let size: Int64
    let modificationTime: TimeInterval

    init?(fileURL: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: fileURL.path(percentEncoded: false)
        ),
        let size = attributes[.size] as? NSNumber,
        size.int64Value > 0,
        let modificationDate = attributes[.modificationDate] as? Date else { return nil }
        self.size = size.int64Value
        modificationTime = modificationDate.timeIntervalSinceReferenceDate
    }

    func matches(_ fileURL: URL) -> Bool {
        guard let current = HttpSyncAppliedLocalArtifact(fileURL: fileURL) else { return false }
        return current == self
    }
}

/// Sidecar used only as a retry optimization. A failed write causes harmless reprocessing on the
/// next sync; it can never make a remote value appear applied when its local write failed because
/// callers record a key only after the critical local write succeeds.
enum HttpSyncAppliedKeyStore {
    private static let filename = ".http_sync_applied_keys.json"

    private static func fileURL() -> URL? {
        (try? BookStorage.getBooksDirectory())?.appendingPathComponent(filename)
    }

    static func load() -> [String: HttpSyncAppliedKeyRecord] {
        guard let url = fileURL(), let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: HttpSyncAppliedKeyRecord].self, from: data)) ?? [:]
    }

    static func save(_ state: [String: HttpSyncAppliedKeyRecord]) {
        guard let url = fileURL(), let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Shelf snapshot

/// One read of `shelves.json` into a bookId → shelf-name map plus the file's mtime as the
/// "shelves last modified" timestamp (the iOS analogue of Android's `shelvesLastModifiedMillis`).
private struct ShelfSnapshot {
    private let namesByBookId: [UUID: String]
    let shelvesUpdatedAt: String?

    func shelfName(for bookId: UUID) -> String? { namesByBookId[bookId] }

    static func load() -> ShelfSnapshot {
        var names: [UUID: String] = [:]
        for shelf in BookStorage.loadShelves() ?? [] {
            for id in shelf.bookIds where names[id] == nil { names[id] = shelf.name }
        }
        var updatedAt: String? = nil
        if let booksDir = try? BookStorage.getBooksDirectory() {
            let url = booksDir.appendingPathComponent(FileNames.shelves)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)),
               let mtime = attrs[.modificationDate] as? Date {
                updatedAt = rfc3339(from: mtime)
            }
        }
        return ShelfSnapshot(namesByBookId: names, shelvesUpdatedAt: updatedAt)
    }
}

// MARK: - Shelf placement sidecar (per-syncId LWW state)

/// Per-syncId shelf placement timestamp, persisted in a JSON sidecar in the Books directory.
/// Mirrors Android's `HttpSyncShelfPlacementRecord` + `HttpSyncShelfStateStore`: it lets a remote
/// shelf move for one book win without making stale folder data for another book win.
struct HttpSyncShelfPlacementRecord: Codable, Equatable {
    var shelfName: String?
    var updatedAt: String
}

enum HttpSyncShelfStateStore {
    private static let filename = ".http_sync_shelf_state.json"

    private static func fileURL() -> URL? {
        (try? BookStorage.getBooksDirectory())?.appendingPathComponent(filename)
    }

    static func load() -> [String: HttpSyncShelfPlacementRecord] {
        guard let url = fileURL() else { return [:] }
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: HttpSyncShelfPlacementRecord].self, from: data)) ?? [:]
    }

    static func save(_ state: [String: HttpSyncShelfPlacementRecord]) {
        guard let url = fileURL() else { return }
        // Merge-on-save: a fire-and-forget shelf hook can write a fresher record while a long
        // reconcile holds an in-memory copy of the whole map — a blind overwrite here would
        // silently lose that move (and the stale snapshot could then revert it via LWW). Per
        // key, the newer `updatedAt` wins; disk-only keys are kept (a hook may have created
        // them mid-sync). The cost is that records removed for tombstoned books can linger as
        // harmless orphans until the book's syncId is reused.
        var merged = state
        if let data = try? Data(contentsOf: url),
           let disk = try? JSONDecoder().decode([String: HttpSyncShelfPlacementRecord].self, from: data) {
            for (key, diskRecord) in disk {
                if let memory = merged[key] {
                    if compareRfc3339(diskRecord.updatedAt, memory.updatedAt) > 0 {
                        merged[key] = diskRecord
                    }
                } else {
                    merged[key] = diskRecord
                }
            }
        }
        guard let data = try? JSONEncoder().encode(merged) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Deleted-book tombstone sidecar (pending local deletes to push)

/// One locally-staged book deletion, persisted in a JSON sidecar in the Books directory until the
/// next outbound sync turns it into a remote `metadata` tombstone. Mirrors Android's
/// `HttpSyncDeletedBookRecord`: keeps just enough to re-publish the metadata blob with `deletedAt`.
nonisolated struct HttpSyncDeletedBookRecord: Codable, Equatable {
    var title: String
    var contentType: ContentType
    var deletedAt: String
}

/// Per-syncId pending book deletions. When the user deletes a book locally we stage a record here
/// so the next `pushAllLocal` PUTs `books/{syncId}/metadata` with `deletedAt` set (propagating the
/// delete to other devices) and so `pullChangedKeys` Pass 3 skips re-importing it before the push
/// runs. Mirrors Android's `HttpSyncDeletedBookStateStore` + `.http_sync_deleted_books.json`.
///
/// The atomic `record`/`remove` helpers re-read disk before writing so a delete staged mid-sync
/// (e.g. while `pushAllLocal` is clearing other records) is not clobbered — the iOS analogue of
/// Android's locked `recordDeletedBook` / `removeDeletedBook` (Bug 3 fix).
enum HttpSyncDeletedBookStore {
    private static let filename = ".http_sync_deleted_books.json"

    private static func fileURL() -> URL? {
        (try? BookStorage.getBooksDirectory())?.appendingPathComponent(filename)
    }

    static func load() -> [String: HttpSyncDeletedBookRecord] {
        guard let url = fileURL() else { return [:] }
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: HttpSyncDeletedBookRecord].self, from: data)) ?? [:]
    }

    static func save(_ state: [String: HttpSyncDeletedBookRecord]) {
        guard let url = fileURL() else { return }
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// All staged tombstones (convenience for iterating in the push pass).
    static func all() -> [String: HttpSyncDeletedBookRecord] { load() }

    /// Atomically add (or replace) the tombstone for `syncId`, re-reading disk first.
    static func record(syncId: String, title: String, contentType: ContentType, deletedAt: String) {
        var state = load()
        state[syncId] = HttpSyncDeletedBookRecord(title: title, contentType: contentType, deletedAt: deletedAt)
        save(state)
    }

    /// Atomically remove the tombstone for `syncId` (no-op if absent), re-reading disk first.
    static func remove(syncId: String) {
        var state = load()
        guard state.removeValue(forKey: syncId) != nil else { return }
        save(state)
    }
}
