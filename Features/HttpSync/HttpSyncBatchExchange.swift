//
//  HttpSyncBatchExchange.swift
//  Hoshi Reader
//
//  Fast KV metadata preflight plus durable, per-install bookmark-map shards.
//

import CryptoKit
import Foundation
import UIKit

nonisolated let httpSyncMapPrefix = "sync/maps/"
nonisolated let httpSyncBooksMapKey = "sync/maps/books.json"
// Read-only migration key used by early development builds.
nonisolated func httpNeedsFullReconcile(_ key: String) -> Bool {
    !key.hasPrefix("sync/maps/") && !(key.hasPrefix("books/") && ["/statistics", "/manga_statistics", "/bookmark"].contains { key.hasSuffix($0) })
}
nonisolated let httpSyncBookmarksMapKey = "sync/maps/bookmarks.json"
nonisolated let httpSyncBookmarksMapPrefix = "sync/maps/bookmarks/"

extension Notification.Name {
    static let httpSyncBookmarkApplied = Notification.Name("HttpSyncBookmarkApplied")
}

nonisolated private struct HttpSyncCachedMapState: Codable, Sendable {
    var booksEtag: String?
    var books: [String: String]
    var bookmarkEtags: [String: String]
    var bookmarkShards: [String: [String: HttpSyncBookmarkMapEntry]]
    var ownedBookmarks: [String: HttpSyncBookmarkMapEntry]
    var legacyEtags: [String: String]
    var initialized: Bool

    init(
        booksEtag: String? = nil,
        books: [String: String] = [:],
        bookmarkEtags: [String: String] = [:],
        bookmarkShards: [String: [String: HttpSyncBookmarkMapEntry]] = [:],
        ownedBookmarks: [String: HttpSyncBookmarkMapEntry] = [:],
        legacyEtags: [String: String] = [:],
        initialized: Bool = false
    ) {
        self.booksEtag = booksEtag
        self.books = books
        self.bookmarkEtags = bookmarkEtags
        self.bookmarkShards = bookmarkShards
        self.ownedBookmarks = ownedBookmarks
        self.legacyEtags = legacyEtags
        self.initialized = initialized
    }
}

nonisolated private struct HttpSyncPendingBookmark: Codable, Sendable {
    let key: String
    let mutationId: String
    let bodyBase64: String
}

nonisolated struct HttpSyncMapChanges: Sendable {
    var needsBootstrap = false
    var booksChanged = false
    var otherChanged = false
    var uploadedBookmarks = 0
    var downloadedBookmarks = 0
    var observedLegacyEtags: [String: String] = [:]
    // Reuse the map preflight's metadata to recover a lost local sidecar even when the
    // library map is unchanged. Converged statistics still need no per-book requests.
    var statisticsMetadata: [String: HttpSyncKvKeyMeta] = [:]
}

/// A logical bookmark map is physically sharded by installation. Each client only overwrites its
/// own key, so two devices can upload simultaneously without one erasing the other's positions.
@MainActor
final class HttpSyncBatchState {
    static let shared = HttpSyncBatchState()

    private let cacheFilename = ".http_sync_exchange_cache.json"
    private let pendingFilename = ".http_sync_pending_bookmarks.json"
    private let encoder: JSONEncoder = {
        let value = JSONEncoder()
        value.outputFormatting = [.sortedKeys]
        return value
    }()
    private let decoder = JSONDecoder()
    private var operationBusy = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private lazy var installationId: String =
        UIDevice.current.identifierForVendor?.uuidString.lowercased()
        ?? UUID().uuidString.lowercased()

    private init() {
        if let books = try? BookStorage.getBooksDirectory() {
            HttpSyncPayloadCodec().recoverInterruptedReplacements(booksDirectory: books)
        }
    }

    func queueBookmark(book: BookMetadata) {
        guard let id = syncId(for: book), let folder = book.folder,
              let books = try? BookStorage.getBooksDirectory() else { return }
        let root = books.appendingPathComponent(folder)
        guard let bookmark = BookStorage.loadBookmark(root: root) else { return }
        let key = SyncKeys.bookmark(id)
        let rev = HttpSyncRevisionStore.bumpForLocalEdit(key)
        var blob = bookmark.toBlob()
        blob.rev = rev
        guard let body = try? encoder.encode(blob) else { return }
        let entry = HttpSyncBookmarkMapEntry(
            etag: sha256Etag(body), lastModified: blob.lastModified, value: blob
        )

        var pending = loadPending()
        pending.removeAll { $0.key == key }
        pending.append(HttpSyncPendingBookmark(
            key: key, mutationId: UUID().uuidString, bodyBase64: body.base64EncodedString()
        ))
        savePending(pending.sorted { $0.key < $1.key })
        var state = loadState()
        state.ownedBookmarks[id] = entry
        saveState(state)
    }

    var hasPending: Bool { !loadPending().isEmpty }

    /// Stable identity of the exact bookmark outbox snapshot. Close-flush uses this to detect a
    /// page turn that arrived while it was joining an already-running map exchange.
    var pendingGeneration: String? {
        let pending = loadPending().sorted { $0.key < $1.key }
        guard !pending.isEmpty else { return nil }
        return pending.map { "\($0.key):\($0.mutationId)" }.joined(separator: "|")
    }

    /// Migration-only pull for the book being opened when maps do not exist yet. This closes the
    /// upgrade window without waiting for a full all-books reconcile in the background.
    func syncLegacyBookmark(book: BookMetadata, config: HttpSyncConfig) async throws -> Bool {
        try await syncLegacyBookmark(
            book: book,
            transport: HttpSyncKvClient(baseURL: config.baseURL, bearerToken: config.token)
        )
    }

    func syncLegacyBookmark(book: BookMetadata, transport: HttpSyncKvTransport) async throws -> Bool {
        await acquireOperation()
        defer { releaseOperation() }
        guard let id = syncId(for: book), let folder = book.folder,
              let books = try? BookStorage.getBooksDirectory() else { return false }
        let key = SyncKeys.bookmark(id)
        guard let fetched = try await transport.get(key: key) else { return false }
        let blob: HttpSyncBookmarkBlob
        do { blob = try decoder.decode(HttpSyncBookmarkBlob.self, from: fetched.body) }
        catch { throw HttpSyncError("Bookmark at \(key): malformed JSON.") }
        guard blob.isValid, let date = parseRfc3339(blob.lastModified) else {
            throw HttpSyncError("Bookmark at \(key): invalid position or lastModified.")
        }
        let remote = HttpSyncBookmarkMapEntry(
            etag: fetched.etag.isEmpty ? sha256Etag(fetched.body) : fetched.etag,
            lastModified: blob.lastModified,
            value: blob
        )
        let root = books.appendingPathComponent(folder)
        if let bookmark = BookStorage.loadBookmark(root: root) {
            var localBlob = bookmark.toBlob()
            localBlob.rev = HttpSyncRevisionStore.current(key).localRev
            if let body = try? encoder.encode(localBlob) {
                let local = HttpSyncBookmarkMapEntry(
                    etag: sha256Etag(body), lastModified: localBlob.lastModified, value: localBlob
                )
                guard compareEntries(remote, local) > 0 else {
                    HttpSyncRevisionStore.noteRemote(key, rev: blob.rev, appliedLocally: false)
                    return false
                }
            }
        }
        try BookStorage.save(Bookmark(
            chapterIndex: blob.chapterIndex,
            progress: blob.progress,
            characterCount: blob.characterCount,
            lastModified: date
        ), inside: root, as: FileNames.bookmark)
        HttpSyncRevisionStore.noteRemote(key, rev: blob.rev, appliedLocally: true)
        NotificationCenter.default.post(
            name: .httpSyncBookmarkApplied,
            object: nil,
            userInfo: ["syncId": id]
        )
        return true
    }

    func syncMaps(config: HttpSyncConfig) async throws -> HttpSyncMapChanges {
        try await syncMaps(transport: HttpSyncKvClient(baseURL: config.baseURL, bearerToken: config.token))
    }

    /// No-change is one list request. Any number of local turns add one PUT of this device's shard.
    func syncMaps(transport: HttpSyncKvTransport) async throws -> HttpSyncMapChanges {
        await acquireOperation()
        defer { releaseOperation() }
        return try await syncMapsLocked(transport: transport)
    }

    private func syncMapsLocked(transport: HttpSyncKvTransport) async throws -> HttpSyncMapChanges {
        let before = loadState()
        let listing = try await listAllMetadata(transport: transport)
        let legacyPairs: [(String, String)] = listing.keys.compactMap { meta -> (String, String)? in
            guard httpNeedsFullReconcile(meta.key), let etag = meta.etag else { return nil }
            return (meta.key, etag)
        }
        let legacyKeyEtags = Dictionary(uniqueKeysWithValues: legacyPairs)
        let statisticsMetadata = Dictionary(uniqueKeysWithValues: listing.keys.map { ($0.key, $0) })
        guard let booksMeta = listing.keys.first(where: { $0.key == httpSyncBooksMapKey }) else {
            return HttpSyncMapChanges(
                needsBootstrap: true,
                observedLegacyEtags: legacyKeyEtags,
                statisticsMetadata: statisticsMetadata
            )
        }
        let bookmarkMetas = listing.keys.filter {
            $0.key == httpSyncBookmarksMapKey || $0.key.hasPrefix(httpSyncBookmarksMapPrefix)
        }
        guard !bookmarkMetas.isEmpty else {
            return HttpSyncMapChanges(
                needsBootstrap: true,
                observedLegacyEtags: legacyKeyEtags,
                statisticsMetadata: statisticsMetadata
            )
        }

        let remoteBooks: [String: String]
        if !before.initialized || before.booksEtag != booksMeta.etag {
            guard let fetched = try await transport.get(key: httpSyncBooksMapKey) else {
                throw HttpSyncError("The server's book map disappeared during sync.")
            }
            do { remoteBooks = try decoder.decode([String: String].self, from: fetched.body) }
            catch { throw HttpSyncError("The server's book map is malformed.") }
        } else {
            remoteBooks = before.books
        }

        var shards: [String: [String: HttpSyncBookmarkMapEntry]] = [:]
        for meta in bookmarkMetas {
            if before.initialized, before.bookmarkEtags[meta.key] == meta.etag {
                shards[meta.key] = before.bookmarkShards[meta.key] ?? [:]
            } else {
                guard let fetched = try await transport.get(key: meta.key) else {
                    throw HttpSyncError("A bookmark-map shard disappeared during sync.")
                }
                do {
                    let decoded = try decoder.decode([String: HttpSyncBookmarkMapEntry].self, from: fetched.body)
                    shards[meta.key] = decoded.filter { _, entry in
                        parseRfc3339(entry.lastModified) != nil && (entry.value?.isValid ?? true)
                    }
                } catch {
                    throw HttpSyncError("A server bookmark-map shard is malformed.")
                }
            }
        }

        let remote = mergeShards(Array(shards.values))
        let listedLegacyFingerprint = legacyKeyEtags
        let legacyChangedBeforeWrites = before.initialized &&
            before.legacyEtags.filter { httpNeedsFullReconcile($0.key) } != listedLegacyFingerprint
        let localBooks = (try? BookStorage.loadAllBooks()) ?? []
        let local = readLocalBookmarks(books: localBooks)
        let downloaded = try applyRemoteWinners(remote: remote, local: local, books: localBooks)
        let deviceKey = bookmarkMapKey(deviceId())
        let serverOwned = shards[deviceKey] ?? [:]
        var owned = merge(remote: serverOwned, local: before.ownedBookmarks)
        for (id, entry) in local {
            let newerThanRemote = remote[id].map { compareEntries(entry, $0) > 0 } ?? true
            let newerThanOwned = owned[id].map { compareEntries(entry, $0) > 0 } ?? true
            if newerThanRemote && newerThanOwned { owned[id] = entry }
        }

        let captured = loadPending()
        var ownEtag = bookmarkMetas.first(where: { $0.key == deviceKey })?.etag
        var uploaded = 0
        if owned != serverOwned {
            let response = try await transport.put(
                key: deviceKey,
                contentType: "application/json; charset=utf-8",
                body: try encoder.encode(owned)
            )
            ownEtag = response.etag
            shards[deviceKey] = owned
            uploaded = captured.count
        }
        let completed = Dictionary(uniqueKeysWithValues: captured.map { ($0.key, $0.mutationId) })
        savePending(loadPending().filter { completed[$0.key] != $0.mutationId })
        let latest = loadState()
        let acknowledgedLegacy = legacyChangedBeforeWrites
            ? before.legacyEtags
            : legacyKeyEtags
        var etags = Dictionary(uniqueKeysWithValues: bookmarkMetas.compactMap { meta in
            meta.etag.map { (meta.key, $0) }
        })
        if let ownEtag { etags[deviceKey] = ownEtag }
        saveState(HttpSyncCachedMapState(
            booksEtag: booksMeta.etag,
            books: remoteBooks,
            bookmarkEtags: etags,
            bookmarkShards: shards,
            ownedBookmarks: merge(remote: owned, local: latest.ownedBookmarks),
            legacyEtags: acknowledgedLegacy,
            initialized: before.initialized
        ))

        let ids = Set(localBooks.compactMap { syncId(for: $0) })
        let hashes = cachedLocalBookHashes(books: localBooks)
        let missingHash = ids.subtracting(hashes.keys).contains { !HttpSyncActiveBooks.contains($0) }
        let mismatch = ids != Set(remoteBooks.keys) || missingHash || hashes.contains { id, sha in
            !HttpSyncActiveBooks.contains(id) && remoteBooks[id] != sha
        } || hasDirtyLocalPayload(books: localBooks)
        return HttpSyncMapChanges(
            needsBootstrap: !before.initialized,
            booksChanged: mismatch,
            otherChanged: legacyChangedBeforeWrites,
            uploadedBookmarks: uploaded,
            downloadedBookmarks: downloaded,
            observedLegacyEtags: legacyKeyEtags,
            statisticsMetadata: statisticsMetadata
        )
    }

    /// Called only after a full reconcile succeeds. It acknowledges the non-map metadata snapshot.
    func publishMaps(
        transport: HttpSyncKvTransport,
        acknowledgedLegacyEtags: [String: String] = [:]
    ) async throws -> HttpSyncMapChanges {
        await acquireOperation()
        defer { releaseOperation() }
        return try await publishMapsLocked(
            transport: transport,
            acknowledgedLegacyEtags: acknowledgedLegacyEtags
        )
    }

    private func publishMapsLocked(
        transport: HttpSyncKvTransport,
        acknowledgedLegacyEtags: [String: String]
    ) async throws -> HttpSyncMapChanges {
        let before = loadState()
        let captured = loadPending()
        let localBooks = (try? BookStorage.loadAllBooks()) ?? []
        // The preflight fetched every shard before the reconcile imported remote-only books, so
        // it could not place their positions yet. Apply the newest known position to the books
        // that exist now; otherwise a fresh install's first "Sync now" leaves each imported book
        // at the older legacy-key position until the next map pass.
        let applied = try applyRemoteWinners(
            remote: mergeShards(Array(before.bookmarkShards.values)),
            local: readLocalBookmarks(books: localBooks),
            books: localBooks
        )
        let local = readLocalBookmarks(books: localBooks)
        let owned = merge(remote: before.ownedBookmarks, local: local)
        var books = cachedLocalBookHashes(books: localBooks)
        for (id, remoteHash) in before.books where HttpSyncActiveBooks.contains(id) && books[id] != nil {
            books[id] = remoteHash
        }
        let booksResponse = try await transport.put(
            key: httpSyncBooksMapKey,
            contentType: "application/json; charset=utf-8",
            body: try encoder.encode(books)
        )
        let deviceKey = bookmarkMapKey(deviceId())
        let bookmarksResponse = try await transport.put(
            key: deviceKey,
            contentType: "application/json; charset=utf-8",
            body: try encoder.encode(owned)
        )
        var bookmarkEtags = before.bookmarkEtags
        if let responseEtag = bookmarksResponse.etag { bookmarkEtags[deviceKey] = responseEtag }
        saveState(HttpSyncCachedMapState(
            booksEtag: booksResponse.etag,
            books: books,
            bookmarkEtags: bookmarkEtags,
            bookmarkShards: before.bookmarkShards.merging([deviceKey: owned]) { _, new in new },
            ownedBookmarks: owned,
            // Never acknowledge a write that arrived after preflight and was not reconciled.
            legacyEtags: acknowledgedLegacyEtags,
            initialized: true
        ))
        let completed = Dictionary(uniqueKeysWithValues: captured.map { ($0.key, $0.mutationId) })
        savePending(loadPending().filter { completed[$0.key] != $0.mutationId })
        return HttpSyncMapChanges(uploadedBookmarks: local.count, downloadedBookmarks: applied)
    }

    /// A full reconcile may write legacy keys itself. Publish maps only after the observed
    /// fingerprint is stable; an unrelated concurrent write must remain visible next pass.
    func observeLegacyEtags(transport: HttpSyncKvTransport) async throws -> [String: String] {
        await acquireOperation()
        defer { releaseOperation() }
        let listing = try await listAllMetadata(transport: transport)
        return Dictionary(uniqueKeysWithValues: listing.keys.compactMap { meta in
            guard httpNeedsFullReconcile(meta.key), let etag = meta.etag else { return nil }
            return (meta.key, etag)
        })
    }

    private func acquireOperation() async {
        if !operationBusy {
            operationBusy = true
            return
        }
        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    private func releaseOperation() {
        if operationWaiters.isEmpty {
            operationBusy = false
        } else {
            operationWaiters.removeFirst().resume()
        }
    }

    private func readLocalBookmarks(books localBooks: [BookMetadata]) -> [String: HttpSyncBookmarkMapEntry] {
        guard let booksDir = try? BookStorage.getBooksDirectory() else { return [:] }
        var result: [String: HttpSyncBookmarkMapEntry] = [:]
        for book in localBooks {
            guard let id = syncId(for: book), let folder = book.folder else { continue }
            let root = booksDir.appendingPathComponent(folder)
            guard let bookmark = BookStorage.loadBookmark(root: root) else { continue }
            var blob = bookmark.toBlob()
            blob.rev = HttpSyncRevisionStore.current(SyncKeys.bookmark(id)).localRev
            guard let body = try? encoder.encode(blob) else { continue }
            result[id] = HttpSyncBookmarkMapEntry(
                etag: sha256Etag(body), lastModified: blob.lastModified, value: blob
            )
        }
        return result
    }

    private func applyRemoteWinners(
        remote: [String: HttpSyncBookmarkMapEntry],
        local: [String: HttpSyncBookmarkMapEntry],
        books localBooks: [BookMetadata]
    ) throws -> Int {
        guard let booksDir = try? BookStorage.getBooksDirectory() else { return 0 }
        let roots: [String: URL] = Dictionary(uniqueKeysWithValues: localBooks.compactMap { book -> (String, URL)? in
            guard let id = syncId(for: book), let folder = book.folder else { return nil }
            return (id, booksDir.appendingPathComponent(folder))
        })
        var applied = 0
        for (id, entry) in remote {
            if let localEntry = local[id], compareEntries(entry, localEntry) <= 0 { continue }
            guard let blob = entry.value, blob.isValid, let root = roots[id], let date = parseRfc3339(blob.lastModified) else { continue }
            if let current = BookStorage.loadBookmark(root: root) {
                var currentBlob = current.toBlob()
                currentBlob.rev = HttpSyncRevisionStore.current(SyncKeys.bookmark(id)).localRev
                if let body = try? encoder.encode(currentBlob) {
                    let currentEntry = HttpSyncBookmarkMapEntry(
                        etag: sha256Etag(body),
                        lastModified: currentBlob.lastModified,
                        value: currentBlob
                    )
                    guard compareEntries(entry, currentEntry) > 0 else { continue }
                }
            }
            let previous = BookStorage.loadBookmark(root: root)
            let moved = previous?.chapterIndex != blob.chapterIndex || previous?.progress != blob.progress || previous?.characterCount != blob.characterCount
            try BookStorage.save(Bookmark(
                chapterIndex: blob.chapterIndex,
                progress: blob.progress,
                characterCount: blob.characterCount,
                lastModified: date
            ), inside: root, as: FileNames.bookmark)
            HttpSyncRevisionStore.noteRemote(SyncKeys.bookmark(id), rev: blob.rev, appliedLocally: true)
            NotificationCenter.default.post(name: .httpSyncBookmarkApplied, object: nil, userInfo: ["syncId": id])
            if moved { applied += 1 }
        }
        return applied
    }

    private func merge(
        remote: [String: HttpSyncBookmarkMapEntry],
        local: [String: HttpSyncBookmarkMapEntry]
    ) -> [String: HttpSyncBookmarkMapEntry] {
        // Validate cached shards too: they may have been read by a version that accepted
        // malformed positions, and must not suppress a valid entry from another device.
        func valid(_ entry: HttpSyncBookmarkMapEntry) -> Bool {
            parseRfc3339(entry.lastModified) != nil && (entry.value?.isValid ?? true)
        }
        var result = remote.filter { valid($0.value) }
        for (id, entry) in local where valid(entry) && (result[id].map({ compareEntries(entry, $0) > 0 }) ?? true) {
            result[id] = entry
        }
        return result
    }

    private func mergeShards(_ shards: [[String: HttpSyncBookmarkMapEntry]]) -> [String: HttpSyncBookmarkMapEntry] {
        shards.reduce(into: [:]) { result, shard in result = merge(remote: result, local: shard) }
    }

    private func compareEntries(_ left: HttpSyncBookmarkMapEntry, _ right: HttpSyncBookmarkMapEntry) -> Int {
        let stamp = compareRfc3339(left.lastModified, right.lastModified)
        if stamp != 0 { return stamp }
        let leftRevision = left.value?.rev ?? 0, rightRevision = right.value?.rev ?? 0
        if leftRevision != rightRevision { return leftRevision < rightRevision ? -1 : 1 }
        return left.etag == right.etag ? 0 : (left.etag < right.etag ? -1 : 1)
    }

    private func cachedLocalBookHashes(books localBooks: [BookMetadata]) -> [String: String] {
        guard let booksDir = try? BookStorage.getBooksDirectory() else { return [:] }
        var result: [String: String] = [:]
        for book in localBooks {
            guard let id = syncId(for: book), let folder = book.folder,
                  let hash = HttpSyncPayloadCodec().cachedPayloadSha(
                    bookRoot: booksDir.appendingPathComponent(folder)
                  ) else { continue }
            result[id] = hash
        }
        return result
    }

    private func hasDirtyLocalPayload(books localBooks: [BookMetadata]) -> Bool {
        guard let booksDir = try? BookStorage.getBooksDirectory() else { return false }
        let codec = HttpSyncPayloadCodec()
        return localBooks.contains { book in
            guard let id = syncId(for: book), let folder = book.folder,
                  !HttpSyncActiveBooks.contains(id) else { return false }
            return codec.hasPayloadContentDirty(bookRoot: booksDir.appendingPathComponent(folder))
        }
    }

    private func loadState() -> HttpSyncCachedMapState {
        guard let url = fileURL(cacheFilename), let data = try? Data(contentsOf: url) else {
            return HttpSyncCachedMapState()
        }
        return (try? decoder.decode(HttpSyncCachedMapState.self, from: data)) ?? HttpSyncCachedMapState()
    }

    private func saveState(_ state: HttpSyncCachedMapState) {
        guard let url = fileURL(cacheFilename), let data = try? encoder.encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func loadPending() -> [HttpSyncPendingBookmark] {
        guard let url = fileURL(pendingFilename), let data = try? Data(contentsOf: url) else { return [] }
        return (try? decoder.decode([HttpSyncPendingBookmark].self, from: data)) ?? []
    }

    private func savePending(_ pending: [HttpSyncPendingBookmark]) {
        guard let url = fileURL(pendingFilename), let data = try? encoder.encode(pending) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func deviceId() -> String {
        // identifierForVendor is device-local and is not copied with a Books backup. A copied
        // shard identifier would let two devices overwrite the same key and lose page turns.
        installationId
    }

    private func listAllMetadata(transport: HttpSyncKvTransport) async throws -> HttpSyncKvList {
        var keys: [HttpSyncKvKeyMeta] = []
        var cursor: String?
        repeat {
            let page = try await transport.list(prefix: nil, since: nil, cursor: cursor, limit: 2_000)
            keys.append(contentsOf: page.keys)
            guard page.truncated == true else { break }
            guard let next = page.nextCursor else {
                throw HttpSyncError("The server truncated its metadata list without a cursor.")
            }
            cursor = next
        } while true
        return HttpSyncKvList(keys: keys)
    }

    private func fileURL(_ name: String) -> URL? {
        guard let directory = try? BookStorage.getBooksDirectory() else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }

    private func sha256Etag(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func bookmarkMapKey(_ deviceId: String) -> String {
        "\(httpSyncBookmarksMapPrefix)\(deviceId).json"
    }
}
