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
/// The library's sync-relevant files, read off the main thread. The five-second foreground poll
/// needs every book's metadata, bookmark, payload hash and dirty marker; reading those there
/// made scrolling stall every poll in large libraries.
nonisolated struct HttpSyncLocalLibrary: Sendable {
    struct Book: Sendable {
        let metadata: BookMetadata
        let root: URL?
        let bookmark: Bookmark?
        let bookmarkModified: Date?
        let payloadSha: String?
        let payloadDirty: Bool
    }
    let books: [Book]
    var metadata: [BookMetadata] { books.map(\.metadata) }

    @concurrent static func scan(booksDirectory: URL) async -> HttpSyncLocalLibrary {
        let decoder = JSONDecoder(), codec = HttpSyncPayloadCodec()
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: booksDirectory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        var books: [Book] = []
        for folder in folders where (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(FileNames.metadata)),
                  let metadata = try? decoder.decode(BookMetadata.self, from: data) else { continue }
            let root = metadata.folder.map { booksDirectory.appendingPathComponent($0) }
            let bookmarkFile = root?.appendingPathComponent(FileNames.bookmark)
            let bookmark = bookmarkFile.flatMap { try? Data(contentsOf: $0) }.flatMap { try? decoder.decode(Bookmark.self, from: $0) }
            let bookmarkModified = bookmarkFile.flatMap {
                (try? FileManager.default.attributesOfItem(atPath: $0.path(percentEncoded: false)))?[.modificationDate] as? Date
            }
            books.append(Book(metadata: metadata, root: root, bookmark: bookmark, bookmarkModified: bookmarkModified,
                              payloadSha: root.flatMap { codec.cachedPayloadSha(bookRoot: $0) },
                              payloadDirty: root.map { codec.hasPayloadContentDirty(bookRoot: $0) } ?? false))
        }
        return HttpSyncLocalLibrary(books: books)
    }
}

nonisolated func httpNeedsFullReconcile(_ key: String) -> Bool {
    !key.hasPrefix("app/reader_settings/") && !key.hasPrefix("sync/maps/") && !(key.hasPrefix("books/") && ["/statistics", "/manga_statistics", "/bookmark"].contains { key.hasSuffix($0) })
}
nonisolated let httpSyncBookmarksMapKey = "sync/maps/bookmarks.json"
nonisolated let httpSyncBookmarksMapPrefix = "sync/maps/bookmarks/"

extension Notification.Name {
    static let httpSyncBookmarkApplied = Notification.Name("HttpSyncBookmarkApplied")
}

nonisolated private struct HttpSyncCachedMapState: Codable, Equatable, Sendable {
    var scope: String?
    var booksEtag: String?
    var books: [String: String]
    var bookmarkEtags: [String: String]
    var bookmarkShards: [String: [String: HttpSyncBookmarkMapEntry]]
    var ownedBookmarks: [String: HttpSyncBookmarkMapEntry]
    var legacyEtags: [String: String]
    var initialized: Bool

    init(
        scope: String? = nil,
        booksEtag: String? = nil,
        books: [String: String] = [:],
        bookmarkEtags: [String: String] = [:],
        bookmarkShards: [String: [String: HttpSyncBookmarkMapEntry]] = [:],
        ownedBookmarks: [String: HttpSyncBookmarkMapEntry] = [:],
        legacyEtags: [String: String] = [:],
        initialized: Bool = false
    ) {
        self.scope = scope
        self.booksEtag = booksEtag
        self.books = books
        self.bookmarkEtags = bookmarkEtags
        self.bookmarkShards = bookmarkShards
        self.ownedBookmarks = ownedBookmarks
        self.legacyEtags = legacyEtags
        self.initialized = initialized
    }
}

nonisolated private struct HttpSyncPendingBookmark: Codable, Equatable, Sendable {
    let key: String
    let mutationId: String
    let bodyBase64: String
}

/// A JSON file only `HttpSyncBatchState` writes, kept decoded in memory. A read checks only the
/// file's modification time and size, and saving an unchanged value leaves the file alone, so a
/// five-second poll that finds nothing new decodes, encodes and writes nothing.
nonisolated private struct HttpSyncRememberedFile<Value: Codable & Equatable> {
    private var remembered: (stamp: Date, size: Int, value: Value)?

    private static func stamp(_ url: URL) -> (Date, Int)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)),
              let modified = attributes[.modificationDate] as? Date,
              let size = (attributes[.size] as? NSNumber)?.intValue else { return nil }
        return (modified, size)
    }

    mutating func load(_ url: URL, decoder: JSONDecoder) -> Value? {
        guard let (modified, size) = Self.stamp(url) else { remembered = nil; return nil }
        if let remembered, remembered.stamp == modified, remembered.size == size { return remembered.value }
        let value = (try? Data(contentsOf: url)).flatMap { try? decoder.decode(Value.self, from: $0) }
        remembered = value.map { (modified, size, $0) }
        return value
    }

    mutating func save(_ value: Value, to url: URL, encoder: JSONEncoder) {
        if let remembered, remembered.value == value, let current = Self.stamp(url),
           current.0 == remembered.stamp, current.1 == remembered.size { return }
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? data.write(to: url, options: .atomic)) != nil, let (modified, size) = Self.stamp(url) else {
            remembered = nil; return
        }
        remembered = (modified, size, value)
    }
}

/// The listing indexed off the main thread: a large library lists hundreds of keys every poll.
nonisolated struct HttpSyncListedKeys: Sendable {
    var all: [String: HttpSyncKvKeyMeta] = [:]
    var legacyEtags: [String: String] = [:]
    var bookmarkMaps: [HttpSyncKvKeyMeta] = []

    @concurrent static func index(_ listing: HttpSyncKvList) async -> HttpSyncListedKeys {
        var keys = HttpSyncListedKeys()
        for meta in listing.keys {
            keys.all[meta.key] = meta
            if httpNeedsFullReconcile(meta.key), let etag = meta.etag { keys.legacyEtags[meta.key] = etag }
            if meta.key == httpSyncBookmarksMapKey || meta.key.hasPrefix(httpSyncBookmarksMapPrefix) { keys.bookmarkMaps.append(meta) }
        }
        return keys
    }
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
    private var stateFile = HttpSyncRememberedFile<HttpSyncCachedMapState>()
    private var pendingFile = HttpSyncRememberedFile<[HttpSyncPendingBookmark]>()
    /// Each book's map entry with the bookmark and revision it was computed from. Encoding and
    /// hashing every book's bookmark on every poll was a visible part of its main-thread time.
    private var bookmarkEntries: [String: (bookmark: Bookmark, rev: Int, entry: HttpSyncBookmarkMapEntry)] = [:]
    private var operationBusy = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private lazy var installationId: String =
        UIDevice.current.identifierForVendor?.uuidString.lowercased()
        ?? UUID().uuidString.lowercased()

    private let booksDirectory: URL?
    private let scanLibrary: @Sendable (URL) async -> HttpSyncLocalLibrary

    init(booksDirectory: URL? = nil, scanLibrary: @escaping @Sendable (URL) async -> HttpSyncLocalLibrary = { await HttpSyncLocalLibrary.scan(booksDirectory: $0) }) {
        self.booksDirectory = booksDirectory
        self.scanLibrary = scanLibrary
        if let books = booksDirectory ?? (try? BookStorage.getBooksDirectory()) {
            HttpSyncPayloadCodec().recoverInterruptedReplacements(booksDirectory: books)
        }
    }

    func queueBookmark(book: BookMetadata) {
        guard let id = syncId(for: book), let folder = book.folder,
              let books = libraryDirectory() else { return }
        let root = books.appendingPathComponent(folder)
        guard let bookmark = BookStorage.loadBookmark(root: root) else { return }
        let key = SyncKeys.bookmark(id)
        let rev = HttpSyncRevisionStore.bumpForLocalEdit(key)
        var blob = bookmark.toBlob()
        blob.rev = rev
        guard let body = try? encoder.encode(blob) else { return }
        var pending = loadPending()
        pending.removeAll { $0.key == key }
        pending.append(HttpSyncPendingBookmark(
            key: key, mutationId: UUID().uuidString, bodyBase64: body.base64EncodedString()
        ))
        savePending(pending.sorted { $0.key < $1.key })
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
    func syncLegacyBookmark(book: BookMetadata, config: HttpSyncConfig, stillCurrent: @MainActor () -> Bool = { true }) async throws -> Bool {
        try await syncLegacyBookmark(
            book: book,
            transport: HttpSyncKvClient(baseURL: config.baseURL, bearerToken: config.token), stillCurrent: stillCurrent
        )
    }

    func syncLegacyBookmark(book: BookMetadata, transport: HttpSyncKvTransport, stillCurrent: @MainActor () -> Bool = { true }) async throws -> Bool {
        await acquireOperation()
        defer { releaseOperation() }
        try ensureCurrent(stillCurrent)
        guard let id = syncId(for: book), let folder = book.folder,
              let books = libraryDirectory() else { return false }
        let key = SyncKeys.bookmark(id)
        let response = try await transport.get(key: key)
        try ensureCurrent(stillCurrent)
        guard let fetched = response else { return false }
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

    func syncMaps(config: HttpSyncConfig, stillCurrent: @MainActor () -> Bool = { true }) async throws -> HttpSyncMapChanges {
        try await syncMaps(transport: HttpSyncKvClient(baseURL: config.baseURL, bearerToken: config.token), scope: Self.scope(config), stillCurrent: stillCurrent)
    }

    /// No-change is one list request. Any number of local turns add one PUT of this device's shard.
    func syncMaps(transport: HttpSyncKvTransport, scope: String = "", stillCurrent: @MainActor () -> Bool = { true }) async throws -> HttpSyncMapChanges {
        await acquireOperation()
        defer { releaseOperation() }
        try ensureCurrent(stillCurrent)
        return try await syncMapsLocked(transport: transport, scope: scope, stillCurrent: stillCurrent)
    }

    private func syncMapsLocked(transport: HttpSyncKvTransport, scope: String, stillCurrent: @MainActor () -> Bool) async throws -> HttpSyncMapChanges {
        let before = loadState(scope: scope)
        let listing = await HttpSyncListedKeys.index(try await listAllMetadata(transport: transport, stillCurrent: stillCurrent))
        try ensureCurrent(stillCurrent)
        let legacyKeyEtags = listing.legacyEtags, statisticsMetadata = listing.all
        guard let booksMeta = listing.all[httpSyncBooksMapKey] else {
            return HttpSyncMapChanges(
                needsBootstrap: true,
                observedLegacyEtags: legacyKeyEtags,
                statisticsMetadata: statisticsMetadata
            )
        }
        let bookmarkMetas = listing.bookmarkMaps
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
            try ensureCurrent(stillCurrent)
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
                try ensureCurrent(stillCurrent)
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
        guard let booksDirectory = libraryDirectory() else { throw HttpSyncError("The library folder is unavailable.") }
        // A scan suspends while readers can save again. Acknowledge only this earlier snapshot.
        let captured = loadPending()
        let library = await scanLibrary(booksDirectory)
        try ensureCurrent(stillCurrent)
        let localBooks = library.metadata
        let local = merge(remote: localBookmarkEntries(library.books.map { ($0.metadata, $0.bookmark) }), local: pendingEntries(captured))
        let downloaded = try applyRemoteWinners(remote: remote, local: local, books: localBooks)
        let deviceKey = bookmarkMapKey(deviceId())
        let serverOwned = shards[deviceKey] ?? [:]
        var owned = merge(remote: serverOwned, local: before.ownedBookmarks)
        for (id, entry) in local {
            let newerThanRemote = remote[id].map { compareEntries(entry, $0) > 0 } ?? true
            let newerThanOwned = owned[id].map { compareEntries(entry, $0) > 0 } ?? true
            if newerThanRemote && newerThanOwned { owned[id] = entry }
        }

        var ownEtag = bookmarkMetas.first(where: { $0.key == deviceKey })?.etag
        var uploaded = 0
        if owned != serverOwned {
            let response = try await transport.put(
                key: deviceKey,
                contentType: "application/json; charset=utf-8",
                body: try encoder.encode(owned)
            )
            try ensureCurrent(stillCurrent)
            ownEtag = response.etag
            shards[deviceKey] = owned
            uploaded = captured.count
        }
        let completed = Dictionary(uniqueKeysWithValues: captured.map { ($0.key, $0.mutationId) })
        savePending(loadPending().filter { completed[$0.key] != $0.mutationId })
        let latest = loadState(scope: scope)
        let acknowledgedLegacy = legacyChangedBeforeWrites
            ? before.legacyEtags
            : legacyKeyEtags
        var etags = Dictionary(uniqueKeysWithValues: bookmarkMetas.compactMap { meta in
            meta.etag.map { (meta.key, $0) }
        })
        if let ownEtag { etags[deviceKey] = ownEtag }
        saveState(HttpSyncCachedMapState(
            scope: scope,
            booksEtag: booksMeta.etag,
            books: remoteBooks,
            bookmarkEtags: etags,
            bookmarkShards: shards,
            ownedBookmarks: merge(remote: owned, local: latest.ownedBookmarks),
            legacyEtags: acknowledgedLegacy,
            initialized: before.initialized
        ))

        let ids = Set(localBooks.compactMap { syncId(for: $0) })
        var hashes: [String: String] = [:]
        for book in library.books { if let id = syncId(for: book.metadata), let sha = book.payloadSha { hashes[id] = sha } }
        let missingHash = ids.subtracting(hashes.keys).contains { !HttpSyncActiveBooks.contains($0) }
        let knownIds = ids.union(HttpSyncCloudBooks.shared.records.map(\.syncId).filter { remoteBooks[$0] != nil })
        let mismatch = knownIds != Set(remoteBooks.keys) || missingHash || hashes.contains { id, sha in
            !HttpSyncActiveBooks.contains(id) && remoteBooks[id] != sha
        } || library.books.contains { book in
            book.payloadDirty && syncId(for: book.metadata).map { !HttpSyncActiveBooks.contains($0) } == true
        }
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
        acknowledgedLegacyEtags: [String: String] = [:],
        scope: String = "",
        stillCurrent: @MainActor () -> Bool = { true }
    ) async throws -> HttpSyncMapChanges {
        await acquireOperation()
        defer { releaseOperation() }
        return try await publishMapsLocked(
            transport: transport,
            acknowledgedLegacyEtags: acknowledgedLegacyEtags, scope: scope, stillCurrent: stillCurrent
        )
    }

    private func publishMapsLocked(
        transport: HttpSyncKvTransport,
        acknowledgedLegacyEtags: [String: String], scope: String, stillCurrent: @MainActor () -> Bool
    ) async throws -> HttpSyncMapChanges {
        try ensureCurrent(stillCurrent)
        let before = loadState(scope: scope)
        let captured = loadPending()
        guard let directory = libraryDirectory() else { throw HttpSyncError("The library folder is unavailable.") }
        let library = await scanLibrary(directory)
        try ensureCurrent(stillCurrent)
        let localBooks = library.metadata
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
        let owned = merge(remote: merge(remote: before.ownedBookmarks, local: local), local: pendingEntries(captured))
        var books: [String: String] = [:]
        for book in library.books {
            if let id = syncId(for: book.metadata), let hash = book.payloadSha { books[id] = hash }
        }
        for record in HttpSyncCloudBooks.shared.records where books[record.syncId] == nil {
            if let remoteHash = before.books[record.syncId] { books[record.syncId] = remoteHash }
        }
        for (id, remoteHash) in before.books where HttpSyncActiveBooks.contains(id) && books[id] != nil {
            books[id] = remoteHash
        }
        let booksResponse = try await transport.put(
            key: httpSyncBooksMapKey,
            contentType: "application/json; charset=utf-8",
            body: try encoder.encode(books)
        )
        try ensureCurrent(stillCurrent)
        let deviceKey = bookmarkMapKey(deviceId())
        let bookmarksResponse = try await transport.put(
            key: deviceKey,
            contentType: "application/json; charset=utf-8",
            body: try encoder.encode(owned)
        )
        try ensureCurrent(stillCurrent)
        var bookmarkEtags = before.bookmarkEtags
        if let responseEtag = bookmarksResponse.etag { bookmarkEtags[deviceKey] = responseEtag }
        saveState(HttpSyncCachedMapState(
            scope: scope,
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
        return await HttpSyncListedKeys.index(try await listAllMetadata(transport: transport)).legacyEtags
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
        guard let booksDir = libraryDirectory() else { return [:] }
        return localBookmarkEntries(localBooks.map { book in
            (book, book.folder.flatMap { BookStorage.loadBookmark(root: booksDir.appendingPathComponent($0)) })
        })
    }

    private func localBookmarkEntries(_ books: [(BookMetadata, Bookmark?)]) -> [String: HttpSyncBookmarkMapEntry] {
        let revisions = HttpSyncRevisionStore.load()
        var result: [String: HttpSyncBookmarkMapEntry] = [:]
        for (book, bookmark) in books {
            guard let id = syncId(for: book), book.folder != nil, let bookmark else { continue }
            result[id] = bookmarkEntry(id: id, bookmark: bookmark, rev: revisions[SyncKeys.bookmark(id)]?.localRev ?? 0)
        }
        return result
    }

    private func bookmarkEntry(id: String, bookmark: Bookmark, rev: Int) -> HttpSyncBookmarkMapEntry? {
        if let known = bookmarkEntries[id], known.bookmark == bookmark, known.rev == rev { return known.entry }
        var blob = bookmark.toBlob()
        blob.rev = rev
        guard let body = try? encoder.encode(blob) else { return nil }
        let entry = HttpSyncBookmarkMapEntry(etag: sha256Etag(body), lastModified: blob.lastModified, value: blob)
        bookmarkEntries[id] = (bookmark, rev, entry)
        return entry
    }

    private func applyRemoteWinners(
        remote: [String: HttpSyncBookmarkMapEntry],
        local: [String: HttpSyncBookmarkMapEntry],
        books localBooks: [BookMetadata]
    ) throws -> Int {
        guard let booksDir = libraryDirectory() else { return 0 }
        // A root is built only for the rare position that may win; every poll checks them all.
        let folders: [String: String] = Dictionary(localBooks.compactMap { book -> (String, String)? in
            guard let id = syncId(for: book), let folder = book.folder else { return nil }
            return (id, folder)
        }, uniquingKeysWith: { first, _ in first })
        var applied = 0
        for (id, entry) in remote {
            if let localEntry = local[id], compareEntries(entry, localEntry) <= 0 { continue }
            guard let blob = entry.value, blob.isValid, let folder = folders[id], let date = parseRfc3339(blob.lastModified) else { continue }
            let root = booksDir.appendingPathComponent(folder)
            if let current = BookStorage.loadBookmark(root: root),
               let currentEntry = bookmarkEntry(id: id, bookmark: current, rev: HttpSyncRevisionStore.current(SyncKeys.bookmark(id)).localRev) {
                guard compareEntries(entry, currentEntry) > 0 else { continue }
                // Another client's encoder gives the same position a different ETag, which can win
                // the tie-break. Rewriting the bookmark then repeated on every poll, rewriting files
                // and announcing a move that never happened; only its revision is new.
                if let local = currentEntry.value, local.chapterIndex == blob.chapterIndex, local.progress == blob.progress,
                   local.characterCount == blob.characterCount, compareRfc3339(local.lastModified, blob.lastModified) == 0 {
                    HttpSyncRevisionStore.noteRemote(SyncKeys.bookmark(id), rev: blob.rev, appliedLocally: true)
                    continue
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
        guard let booksDir = libraryDirectory() else { return [:] }
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

    private func loadState(scope: String) -> HttpSyncCachedMapState {
        let stored = fileURL(cacheFilename).flatMap { stateFile.load($0, decoder: decoder) }
        // Old unscoped acknowledgements are not safe for a newly selected account.
        return stored?.scope == scope ? stored! : HttpSyncCachedMapState(scope: scope)
    }

    private func saveState(_ state: HttpSyncCachedMapState) {
        guard let url = fileURL(cacheFilename) else { return }
        stateFile.save(state, to: url, encoder: encoder)
    }

    private func loadPending() -> [HttpSyncPendingBookmark] {
        fileURL(pendingFilename).flatMap { pendingFile.load($0, decoder: decoder) } ?? []
    }

    private func savePending(_ pending: [HttpSyncPendingBookmark]) {
        guard let url = fileURL(pendingFilename) else { return }
        pendingFile.save(pending, to: url, encoder: encoder)
    }

    private func pendingEntries(_ pending: [HttpSyncPendingBookmark]) -> [String: HttpSyncBookmarkMapEntry] {
        var entries: [String: HttpSyncBookmarkMapEntry] = [:]
        for mutation in pending {
            guard mutation.key.hasPrefix("books/"), mutation.key.hasSuffix("/bookmark"),
                  let data = Data(base64Encoded: mutation.bodyBase64),
                  let blob = try? decoder.decode(HttpSyncBookmarkBlob.self, from: data), blob.isValid,
                  parseRfc3339(blob.lastModified) != nil else { continue }
            let id = String(mutation.key.dropFirst(6).dropLast(9))
            entries[id] = HttpSyncBookmarkMapEntry(etag: sha256Etag(data), lastModified: blob.lastModified, value: blob)
        }
        return entries
    }

    private func ensureCurrent(_ stillCurrent: @MainActor () -> Bool) throws {
        try Task.checkCancellation()
        guard stillCurrent() else { throw CancellationError() }
    }

    static func scope(_ config: HttpSyncConfig) -> String {
        config.baseURL + ":" + SHA256.hash(data: Data(config.token.utf8)).lowercaseHex
    }

    private func deviceId() -> String {
        // identifierForVendor is device-local and is not copied with a Books backup. A copied
        // shard identifier would let two devices overwrite the same key and lose page turns.
        installationId
    }

    private func listAllMetadata(transport: HttpSyncKvTransport, stillCurrent: @MainActor () -> Bool = { true }) async throws -> HttpSyncKvList {
        var keys: [HttpSyncKvKeyMeta] = []
        var cursor: String?
        repeat {
            let page = try await transport.list(prefix: nil, since: nil, cursor: cursor, limit: 2_000)
            try ensureCurrent(stillCurrent)
            keys.append(contentsOf: page.keys)
            guard page.truncated == true else { break }
            guard let next = page.nextCursor else {
                throw HttpSyncError("The server truncated its metadata list without a cursor.")
            }
            cursor = next
        } while true
        return HttpSyncKvList(keys: keys)
    }

    private func libraryDirectory() -> URL? { booksDirectory ?? (try? BookStorage.getBooksDirectory()) }

    private func fileURL(_ name: String) -> URL? {
        libraryDirectory()?.appendingPathComponent(name)
    }

    private func sha256Etag(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).lowercaseHex
    }

    private func bookmarkMapKey(_ deviceId: String) -> String {
        "\(httpSyncBookmarksMapPrefix)\(deviceId).json"
    }
}
