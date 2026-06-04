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
        if uploadedAppSettings { parts.append("ChatGPT settings up") }
        if downloadedBookmarks > 0 { parts.append("\(downloadedBookmarks) bookmark\(plural(downloadedBookmarks)) down") }
        if downloadedChatEntries > 0 { parts.append("\(downloadedChatEntries) chat\(plural(downloadedChatEntries)) down") }
        if downloadedPayloads > 0 { parts.append("\(downloadedPayloads) book payload\(plural(downloadedPayloads)) down") }
        if downloadedAppSettings { parts.append("ChatGPT settings down") }
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
    func syncOnce(sinceCursor: String?) async -> HttpSyncResult {
        var result = HttpSyncResult()

        let inbound = await pullChangedKeys(sinceCursor: sinceCursor, into: &result)
        await pushAllLocal(into: &result)

        result.newLastSyncedAt = safeNewCursor(currentCursor: sinceCursor, inbound: inbound)
        if result.newLastSyncedAt == sinceCursor { result.newLastSyncedAt = nil }
        return result
    }

    // MARK: - Cursor

    private struct InboundCursor {
        var maxHandled: String?
        var minUnhandled: String?
    }

    private func safeNewCursor(currentCursor: String?, inbound: InboundCursor) -> String? {
        let candidates = [currentCursor, inbound.maxHandled].compactMap { $0 }
        let firstUnhandled = inbound.minUnhandled
        let safe: [String]
        if let firstUnhandled {
            safe = candidates.filter { compareRfc3339($0, firstUnhandled) < 0 }
        } else {
            safe = candidates
        }
        return safe.reduce(nil) { acc, ts in maxRfc(acc, ts) }
    }

    // MARK: - Key parsing

    private enum BookKeyKind { case bookmark, chat, metadata, payloadManifest, payloadZip }
    private struct ParsedBookKey { let syncId: String; let kind: BookKeyKind }

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
                  let folder = meta.folder, let syncId = deriveSyncId(title) else { continue }
            let root = booksDir.appendingPathComponent(folder)
            out.append(LocalBook(
                id: meta.id,
                title: title,
                syncId: syncId,
                root: root,
                contentType: ContentType.detect(bookDir: root),
                importedAt: meta.importedAt
            ))
        }
        return out
    }

    // MARK: - Inbound

    private func pullChangedKeys(sinceCursor: String?, into result: inout HttpSyncResult) async -> InboundCursor {
        var cursor = InboundCursor()

        func markHandled(_ meta: HttpSyncKvKeyMeta) {
            cursor.maxHandled = maxRfc(cursor.maxHandled, meta.lastModified)
        }
        func markUnhandled(_ meta: HttpSyncKvKeyMeta) {
            if compareRfc3339(meta.lastModified, sinceCursor) <= 0 { return }
            if cursor.minUnhandled == nil || compareRfc3339(meta.lastModified, cursor.minUnhandled) < 0 {
                cursor.minUnhandled = meta.lastModified
            }
        }

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

        // Pass 1: page through the entire listing and bucket keys by kind. We always do a full
        // list (since=nil) on a manual sync — see the Android rationale: an incremental `since`
        // can silently swallow new books under server clock skew. Per-key GETs are still
        // short-circuited by the LWW checks below, so this is one list pass, not a re-download.
        var payloadManifests: [HttpSyncKvKeyMeta] = []
        var metadataKeys: [(ParsedBookKey, HttpSyncKvKeyMeta)] = []
        var bookmarksAndChats: [(ParsedBookKey, HttpSyncKvKeyMeta)] = []
        var remoteSyncIds: Set<String> = []

        do {
            try await transport.listAll(prefix: SyncKeys.allBooksPrefix, since: nil) { meta in
                guard let parsed = parseBookKey(meta.key) else {
                    markHandled(meta)
                    return
                }
                remoteSyncIds.insert(parsed.syncId)
                switch parsed.kind {
                case .payloadManifest: payloadManifests.append(meta)
                case .bookmark, .chat: bookmarksAndChats.append((parsed, meta))
                case .payloadZip: markHandled(meta) // followed via the manifest
                case .metadata: metadataKeys.append((parsed, meta))
                }
            }
        } catch {
            result.errors.append("list: \(errorText(error))")
            return cursor
        }

        // Pass 2: apply metadata tombstones before payload import so a deleted remote book never
        // causes a fresh device to download a payload just to delete it.
        var shelfState = HttpSyncShelfStateStore.load()
        var deletedSyncIds: Set<String> = []
        var placementMetadataKeys: [(ParsedBookKey, HttpSyncKvKeyMeta)] = []
        for (parsed, meta) in metadataKeys {
            do {
                guard let remote = try await fetchRemoteMetadata(key: meta.key) else {
                    throw HttpSyncError("Metadata at \(meta.key): missing.")
                }
                if let remoteDeletedAt = remote.blob.deletedAt {
                    let localImportedAt = importedAtBySyncId[parsed.syncId] ?? nil
                    if localImportedAtOverridesRemoteDeletion(localImportedAt: localImportedAt, remoteDeletedAt: remoteDeletedAt) {
                        // Re-import after tombstone: the live local copy wins. Keep it; leave the
                        // tombstone unhandled so the cursor doesn't advance past it until the
                        // outbound push re-publishes metadata with deletedAt = nil.
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
        for meta in payloadManifests {
            guard let parsed = parseBookKey(meta.key) else { continue }
            if deletedSyncIds.contains(parsed.syncId) { markHandled(meta); continue }
            if rootsBySyncId[parsed.syncId] != nil { markHandled(meta); continue }
            if pendingTombstoneSyncIds.contains(parsed.syncId) { markHandled(meta); continue }
            do {
                if let imported = try await importRemoteOnlyBook(syncId: parsed.syncId) {
                    rootsBySyncId[parsed.syncId] = imported
                    result.downloadedPayloads += 1
                    markHandled(meta)
                } else {
                    markUnhandled(meta)
                }
            } catch {
                result.errors.append("payload \(parsed.syncId): \(errorText(error))")
                markUnhandled(meta)
            }
        }

        // Pass 4: metadata shelf placement now that local roots exist.
        let shelfSnapshot = ShelfSnapshot.load()
        for (parsed, meta) in placementMetadataKeys {
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
        for (parsed, meta) in bookmarksAndChats {
            if deletedSyncIds.contains(parsed.syncId) { markHandled(meta); continue }
            guard let root = rootsBySyncId[parsed.syncId] else { markUnhandled(meta); continue }
            do {
                switch parsed.kind {
                case .bookmark:
                    if try await applyBookmarkFromRemote(root: root, meta: meta) { result.downloadedBookmarks += 1 }
                case .chat:
                    if try await applyChatEntryFromRemote(root: root, meta: meta) { result.downloadedChatEntries += 1 }
                default: break
                }
                markHandled(meta)
            } catch {
                result.errors.append("\(parsed.syncId): \(errorText(error))")
                markUnhandled(meta)
            }
        }

        result.remoteOnlyBooks = remoteSyncIds.filter { rootsBySyncId[$0] == nil && !deletedSyncIds.contains($0) }.count
        return cursor
    }

    private func localBookId(_ books: [LocalBook], _ syncId: String) -> UUID? {
        books.first { $0.syncId == syncId }?.id
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
        let localModified = local?.lastModified.map { rfc3339(from: $0) }
        if compareRfc3339(blob.lastModified, localModified) <= 0 { return false } // don't downgrade
        let bookmark = Bookmark(
            chapterIndex: blob.chapterIndex,
            progress: blob.progress,
            characterCount: blob.characterCount,
            lastModified: Date(timeIntervalSinceReferenceDate: rfc3339ToAppleSeconds(blob.lastModified))
        )
        try? BookStorage.save(bookmark, inside: root, as: FileNames.bookmark)
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
        if log.entries.contains(where: { $0.matchesEntry(incoming) }) { return false }
        log.entries.append(incoming)
        saveChatLog(log, root: root)
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
            shelfState[syncId] = HttpSyncShelfPlacementRecord(
                shelfName: normalized,
                updatedAt: remote.blob.shelfUpdatedAt ?? meta.lastModified
            )
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

    private func shouldApplyRemoteShelfPlacement(remoteShelfUpdatedAt: String?, localShelvesUpdatedAt: String?) -> Bool {
        guard let localShelvesUpdatedAt else { return true }
        guard let remoteShelfUpdatedAt else { return false }
        return compareRfc3339(remoteShelfUpdatedAt, localShelvesUpdatedAt) >= 0
    }

    private func normalizeShelfName(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Mutates `shelves.json`: remove `bookId` from every shelf, then add it to the target shelf
    /// (creating the shelf if needed). `nil` shelfName leaves the book unshelved.
    private func applyShelfPlacement(bookId: UUID, shelfName: String?) {
        var shelves = BookStorage.loadShelves() ?? []
        for i in shelves.indices { shelves[i].bookIds.removeAll { $0 == bookId } }
        if let shelfName {
            if let idx = shelves.firstIndex(where: { $0.name == shelfName }) {
                if !shelves[idx].bookIds.contains(bookId) { shelves[idx].bookIds.append(bookId) }
            } else {
                shelves.append(BookShelf(name: shelfName, bookIds: [bookId]))
            }
        }
        guard let booksDir = try? BookStorage.getBooksDirectory() else { return }
        try? BookStorage.save(shelves, inside: booksDir, as: FileNames.shelves)
    }

    // MARK: - Remote-only import

    private func importRemoteOnlyBook(syncId: String) async throws -> URL? {
        guard let booksDir = try? BookStorage.getBooksDirectory() else { return nil }
        let targetRoot = booksDir.appendingPathComponent(syncId, isDirectory: true)
        // Avoid colliding with an existing directory; uniquify if needed.
        let root = uniqueDirectory(base: targetRoot)
        do {
            let manifest = try await payloadCodec.downloadAndUnpack(transport: transport, syncId: syncId, targetDir: root)
            let detected = ContentType.detect(bookDir: root)
            let cover = resolveImportedCoverPath(root: root, folder: root.lastPathComponent)
            let metadata = BookMetadata(
                id: UUID(),
                title: manifest.originalName,
                cover: cover,
                folder: root.lastPathComponent,
                lastAccess: Date(timeIntervalSince1970: 0),
                contentType: detected,
                importedAt: rfc3339Now()
            )
            try? BookStorage.save(metadata, inside: root, as: FileNames.metadata)
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

    private func resolveImportedCoverPath(root: URL, folder: String) -> String? {
        let cover = root.appendingPathComponent("cover.jpg")
        if FileManager.default.fileExists(atPath: cover.path(percentEncoded: false)) {
            return "Books/\(folder)/cover.jpg"
        }
        return nil
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

    private func pushAllLocal(into result: inout HttpSyncResult) async {
        let localBooks = loadLocalBooks()
        let snapshot = ShelfSnapshot.load()
        var shelfState = HttpSyncShelfStateStore.load()

        // Pass 0: push pending deleted-book tombstones. For each staged delete, PUT a metadata
        // blob with `deletedAt` set so the deletion propagates to other devices; clear the record
        // only after a successful PUT (so a transient failure retries next sync). A tombstone whose
        // syncId now matches a live local book (delete-then-re-import before sync) is pruned without
        // a push so the live book's normal metadata push wins. Mirrors Android's tombstone loop.
        let pendingDeleted = HttpSyncDeletedBookStore.all()
        if !pendingDeleted.isEmpty {
            let liveLocalSyncIds = Set(localBooks.map { $0.syncId })
            for syncId in pendingDeleted.keys where liveLocalSyncIds.contains(syncId) {
                HttpSyncDeletedBookStore.remove(syncId: syncId)
                shelfState.removeValue(forKey: syncId)
            }
            for (syncId, record) in pendingDeleted where !liveLocalSyncIds.contains(syncId) {
                let blob = HttpSyncMetadataBlob(
                    title: record.title,
                    contentType: record.contentType,
                    importedAt: nil,
                    deletedAt: record.deletedAt
                )
                do {
                    _ = try await transport.put(
                        key: SyncKeys.metadata(syncId),
                        contentType: Self.jsonContentType,
                        body: try jsonEncoder.encode(blob)
                    )
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

        for book in localBooks {
            do {
                let remoteMetadata = try await fetchRemoteMetadataForUpload(key: SyncKeys.metadata(book.syncId))
                let remoteDeletedAt = remoteMetadata?.blob.deletedAt
                let tombstoneOverridden = remoteDeletedAt != nil &&
                    localImportedAtOverridesRemoteDeletion(localImportedAt: book.importedAt, remoteDeletedAt: remoteDeletedAt)
                if remoteDeletedAt != nil && !tombstoneOverridden {
                    // Server says deleted and we didn't re-import after the tombstone: honour it.
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
                    uploadShelfUpdatedAt = remoteMetadata.blob.shelfUpdatedAt ?? remoteMetadata.lastModified
                    applyShelfPlacement(bookId: book.id, shelfName: uploadShelfName)
                    shelfState[book.syncId] = HttpSyncShelfPlacementRecord(shelfName: uploadShelfName, updatedAt: uploadShelfUpdatedAt!)
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
                let metaBlob = HttpSyncMetadataBlob(
                    title: book.title,
                    contentType: book.contentType,
                    shelfName: uploadShelfName,
                    shelfUpdatedAt: uploadShelfUpdatedAt,
                    importedAt: uploadImportedAt,
                    deletedAt: uploadDeletedAt
                )
                _ = try await transport.put(
                    key: SyncKeys.metadata(book.syncId),
                    contentType: Self.jsonContentType,
                    body: try jsonEncoder.encode(metaBlob)
                )
                result.uploadedMetadata += 1
                if let uploadShelfUpdatedAt {
                    shelfState[book.syncId] = HttpSyncShelfPlacementRecord(shelfName: uploadShelfName, updatedAt: uploadShelfUpdatedAt)
                } else {
                    shelfState.removeValue(forKey: book.syncId)
                }

                // Payload (mokuro only for v2.0) — upload once if the server lacks a manifest.
                if book.contentType == .mokuro {
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
                        for entry in entries {
                            let suffix = chatEntryKeySuffix(timestampAppleSeconds: entry.timestampSeconds, bubbleText: entry.bubbleText, response: entry.response)
                            let key = SyncKeys.chat(book.syncId, suffix: suffix)
                            if existing.contains(key) { continue }
                            _ = try await transport.put(
                                key: key,
                                contentType: Self.jsonContentType,
                                body: try jsonEncoder.encode(entry.toBlob())
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
        if let remote = try await transport.get(key: key),
           let remoteBlob = try? jsonDecoder.decode(HttpSyncBookmarkBlob.self, from: remote.body) {
            let localStamp = local.lastModified.map { rfc3339(from: $0) }
            if compareRfc3339(remoteBlob.lastModified, localStamp) > 0 {
                let bookmark = Bookmark(
                    chapterIndex: remoteBlob.chapterIndex,
                    progress: remoteBlob.progress,
                    characterCount: remoteBlob.characterCount,
                    lastModified: Date(timeIntervalSinceReferenceDate: rfc3339ToAppleSeconds(remoteBlob.lastModified))
                )
                try? BookStorage.save(bookmark, inside: root, as: FileNames.bookmark)
                return false
            }
        }
        _ = try await transport.put(
            key: key,
            contentType: Self.jsonContentType,
            body: try jsonEncoder.encode(local.toBlob())
        )
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

    private func saveChatLog(_ log: AiChatLog, root: URL) {
        try? BookStorage.save(log, inside: root, as: FileNames.aiChatLog)
    }

    // MARK: - Book deletion

    private func deleteBook(root: URL, bookId: UUID?) {
        try? BookStorage.delete(at: root)
        if let bookId {
            var shelves = BookStorage.loadShelves() ?? []
            var changed = false
            for i in shelves.indices {
                let before = shelves[i].bookIds.count
                shelves[i].bookIds.removeAll { $0 == bookId }
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
        guard let data = try? JSONEncoder().encode(state) else { return }
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
