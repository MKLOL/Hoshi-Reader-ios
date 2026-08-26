//
//  HttpSyncBatchExchange.swift
//  Hoshi Reader
//
//  Two-map sync cache and durable five-second bookmark outbox.
//

import Foundation

nonisolated struct HttpSyncCachedExchangeKey: Codable, Sendable {
    let key: String
    let lastModified: String
    let etag: String
    let size: Int
    let contentType: String
    let bodyBase64: String?
}

nonisolated private struct HttpSyncCachedMapState: Codable, Sendable {
    var booksHash: String?
    var bookmarksHash: String?
    var books: [String: String]
    var keys: [String: HttpSyncCachedExchangeKey]

    init(
        booksHash: String? = nil,
        bookmarksHash: String? = nil,
        books: [String: String] = [:],
        keys: [String: HttpSyncCachedExchangeKey] = [:]
    ) {
        self.booksHash = booksHash
        self.bookmarksHash = bookmarksHash
        self.books = books
        self.keys = keys
    }
}

nonisolated private struct HttpSyncPendingBookmark: Codable, Sendable {
    let key: String
    let baseEtag: String?
    let mutationId: String
    let contentType: String
    let bodyBase64: String
}

nonisolated struct HttpSyncMapChanges: Sendable {
    let booksChanged: Bool
    let bookmarksChanged: Bool
}

/// Main-actor persistence for the two map hashes and the bookmark outbox.
@MainActor
final class HttpSyncBatchState {
    static let shared = HttpSyncBatchState()

    private let cacheFilename = ".http_sync_exchange_cache.json"
    private let pendingFilename = ".http_sync_pending_bookmarks.json"

    func queueBookmark(book: BookMetadata) {
        guard let bookSyncId = syncId(for: book),
              let folder = book.folder,
              let books = try? BookStorage.getBooksDirectory() else { return }
        let root = books.appendingPathComponent(folder)
        guard let bookmark = BookStorage.loadBookmark(root: root) else { return }

        let key = SyncKeys.bookmark(bookSyncId)
        let rev = HttpSyncRevisionStore.bumpForLocalEdit(key)
        var blob = bookmark.toBlob()
        blob.rev = rev
        guard let body = try? JSONEncoder().encode(blob) else { return }

        var pending = loadPending()
        let prior = pending.first { $0.key == key }
        pending.removeAll { $0.key == key }
        pending.append(HttpSyncPendingBookmark(
            key: key,
            baseEtag: prior?.baseEtag ?? loadState().keys[key]?.etag,
            mutationId: UUID().uuidString,
            contentType: "application/json; charset=utf-8",
            bodyBase64: body.base64EncodedString()
        ))
        savePending(pending.sorted { $0.key < $1.key })
    }

    func exchangeRequest() -> HttpSyncExchangeRequest {
        let state = loadState()
        return HttpSyncExchangeRequest(
            booksHash: state.booksHash,
            bookmarksHash: state.bookmarksHash,
            writes: loadPending().map {
                HttpSyncExchangeWrite(
                    key: $0.key,
                    baseEtag: $0.baseEtag,
                    mutationId: $0.mutationId,
                    contentType: $0.contentType,
                    bodyBase64: $0.bodyBase64
                )
            }
        )
    }

    func exchange(config: HttpSyncConfig) async throws -> HttpSyncMapChanges {
        let client = HttpSyncKvClient(baseURL: config.baseURL, bearerToken: config.token)
        let response = try await client.exchange(exchangeRequest())
        return applyExchange(response)
    }

    @discardableResult
    func applyExchange(_ response: HttpSyncExchangeResponse) -> HttpSyncMapChanges {
        let old = loadState()
        var next = old

        if let remoteKeys = response.bookKeys {
            next.keys = next.keys.filter { key, _ in
                !key.isPerBookKey || key.isBookmarkKey
            }
            for remote in remoteKeys {
                let retainedBody: String?
                if let body = remote.bodyBase64 {
                    retainedBody = body
                } else if old.keys[remote.key]?.etag == remote.etag {
                    retainedBody = old.keys[remote.key]?.bodyBase64
                } else {
                    retainedBody = nil
                }
                next.keys[remote.key] = HttpSyncCachedExchangeKey(
                    key: remote.key,
                    lastModified: remote.lastModified,
                    etag: remote.etag,
                    size: remote.size,
                    contentType: remote.contentType,
                    bodyBase64: retainedBody
                )
            }
        }

        if let bookmarks = response.bookmarks {
            next.keys = next.keys.filter { key, _ in !key.isBookmarkKey }
            let encoder = JSONEncoder()
            for (bookId, entry) in bookmarks {
                guard let value = entry.value, let body = try? encoder.encode(value) else { continue }
                let key = SyncKeys.bookmark(bookId)
                next.keys[key] = HttpSyncCachedExchangeKey(
                    key: key,
                    lastModified: entry.lastModified,
                    etag: entry.etag,
                    size: body.count,
                    contentType: "application/json; charset=utf-8",
                    bodyBase64: body.base64EncodedString()
                )
            }
        }

        next.booksHash = response.booksHash
        next.bookmarksHash = response.bookmarksHash
        if let books = response.books { next.books = books }
        saveState(next)

        // Accepted and rejected acknowledgements both resolve the exact queued
        // mutation. Rejected means the returned bookmark map is authoritative.
        let acknowledged = Dictionary(
            uniqueKeysWithValues: response.writeAcks.map { ($0.mutationId, $0.key) }
        )
        savePending(loadPending().filter { acknowledged[$0.mutationId] != $0.key })

        if let bookmarks = response.bookmarks { applyRemoteBookmarks(bookmarks) }
        return HttpSyncMapChanges(
            booksChanged: response.books != nil && response.books != old.books,
            bookmarksChanged: response.bookmarks != nil
        )
    }

    private func applyRemoteBookmarks(_ bookmarks: [String: HttpSyncBookmarkMapEntry]) {
        guard let booksDir = try? BookStorage.getBooksDirectory(),
              let metadata = try? BookStorage.loadAllBooks() else { return }
        let roots: [String: URL] = Dictionary(uniqueKeysWithValues: metadata.compactMap { book in
            guard let id = syncId(for: book), let folder = book.folder else { return nil }
            return (id, booksDir.appendingPathComponent(folder))
        })
        for (bookId, entry) in bookmarks {
            guard let blob = entry.value, let root = roots[bookId] else { continue }
            let key = SyncKeys.bookmark(bookId)
            let local = BookStorage.loadBookmark(root: root)
            let localStamp = local?.lastModified.map(rfc3339(from:))
            let localRev = HttpSyncRevisionStore.current(key).localRev
            let stampOrder = compareRfc3339(blob.lastModified, localStamp)
            let remoteWins = stampOrder > 0 || (
                stampOrder == 0 && (blob.rev ?? 0) > localRev
            )
            guard remoteWins else {
                HttpSyncRevisionStore.noteRemote(key, rev: blob.rev, appliedLocally: false)
                continue
            }
            let bookmark = Bookmark(
                chapterIndex: blob.chapterIndex,
                progress: blob.progress,
                characterCount: blob.characterCount,
                lastModified: Date(
                    timeIntervalSinceReferenceDate: rfc3339ToAppleSeconds(blob.lastModified)
                )
            )
            try? BookStorage.save(bookmark, inside: root, as: FileNames.bookmark)
            HttpSyncRevisionStore.noteRemote(key, rev: blob.rev, appliedLocally: true)
        }
    }

    func saveCache(_ cache: [String: HttpSyncCachedExchangeKey]) {
        var state = loadState()
        state.keys = cache
        saveState(state)
    }

    func cacheSnapshot() -> [String: HttpSyncCachedExchangeKey] { loadState().keys }
    var hasPending: Bool { !loadPending().isEmpty }
    var pendingKeys: Set<String> { Set(loadPending().map(\.key)) }

    func resolveLegacyWrites(_ mutations: [String: String]) {
        savePending(loadPending().filter { mutations[$0.key] != $0.mutationId })
    }

    private func loadState() -> HttpSyncCachedMapState {
        guard let url = fileURL(cacheFilename), let data = try? Data(contentsOf: url) else {
            return HttpSyncCachedMapState()
        }
        if let state = try? JSONDecoder().decode(HttpSyncCachedMapState.self, from: data) {
            return state
        }
        let legacy = (try? JSONDecoder().decode(
            [String: HttpSyncCachedExchangeKey].self,
            from: data
        )) ?? [:]
        return HttpSyncCachedMapState(keys: legacy)
    }

    private func saveState(_ state: HttpSyncCachedMapState) {
        guard let url = fileURL(cacheFilename), let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func loadPending() -> [HttpSyncPendingBookmark] {
        guard let url = fileURL(pendingFilename), let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([HttpSyncPendingBookmark].self, from: data)) ?? []
    }

    private func savePending(_ pending: [HttpSyncPendingBookmark]) {
        guard let url = fileURL(pendingFilename), let data = try? JSONEncoder().encode(pending) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func fileURL(_ name: String) -> URL? {
        (try? BookStorage.getBooksDirectory())?.appendingPathComponent(name)
    }
}

/// Actor transport serving book listings/small bodies from the map exchange.
actor HttpSyncBatchKvTransport: HttpSyncKvTransport {
    private let delegate: HttpSyncKvClient
    private let request: HttpSyncExchangeRequest
    private var cache: [String: HttpSyncCachedExchangeKey]
    private var pendingKeys: Set<String>
    private var prepared = false
    private var response: HttpSyncExchangeResponse?
    private var legacyFallback = false
    private var legacyMutations: [String: String] = [:]
    private var resolvedLegacyKeys: Set<String> = []

    init(config: HttpSyncConfig, request: HttpSyncExchangeRequest,
         cache: [String: HttpSyncCachedExchangeKey]) {
        delegate = HttpSyncKvClient(baseURL: config.baseURL, bearerToken: config.token)
        self.request = request
        self.cache = cache
        pendingKeys = Set(request.writes.map(\.key))
    }

    func prepare() async throws {
        guard !prepared else { return }
        let exchange: HttpSyncExchangeResponse
        do {
            exchange = try await delegate.exchange(request)
        } catch is HttpSyncExchangeUnavailable {
            // Rolling deploy compatibility: continue through the v1 transport
            // until this server gains /v2/exchange.
            legacyFallback = true
            legacyMutations = Dictionary(
                uniqueKeysWithValues: request.writes.map { ($0.key, $0.mutationId) }
            )
            prepared = true
            return
        }
        if let remoteKeys = exchange.bookKeys {
            cache = cache.filter { key, _ in !key.isPerBookKey || key.isBookmarkKey }
            for remote in remoteKeys {
                let retained: String?
                if let body = remote.bodyBase64 {
                    retained = body
                } else if cache[remote.key]?.etag == remote.etag {
                    retained = cache[remote.key]?.bodyBase64
                } else {
                    retained = nil
                }
                cache[remote.key] = HttpSyncCachedExchangeKey(
                    key: remote.key, lastModified: remote.lastModified, etag: remote.etag,
                    size: remote.size, contentType: remote.contentType, bodyBase64: retained
                )
            }
        }
        if let bookmarks = exchange.bookmarks {
            cache = cache.filter { key, _ in !key.isBookmarkKey }
            let encoder = JSONEncoder()
            for (bookId, entry) in bookmarks {
                guard let value = entry.value, let body = try? encoder.encode(value) else { continue }
                let key = SyncKeys.bookmark(bookId)
                cache[key] = HttpSyncCachedExchangeKey(
                    key: key, lastModified: entry.lastModified, etag: entry.etag,
                    size: body.count, contentType: "application/json; charset=utf-8",
                    bodyBase64: body.base64EncodedString()
                )
            }
        }
        pendingKeys.subtract(exchange.writeAcks.map(\.key))
        response = exchange
        prepared = true
    }

    func exchangeResponse() -> HttpSyncExchangeResponse? { response }
    func cacheSnapshot() -> [String: HttpSyncCachedExchangeKey] { cache }
    func setPendingKeys(_ keys: Set<String>) { pendingKeys = keys }

    func legacyMutationsToResolve(fullSuccess: Bool) -> [String: String] {
        guard legacyFallback else { return [:] }
        if fullSuccess { return legacyMutations }
        return legacyMutations.filter { resolvedLegacyKeys.contains($0.key) }
    }

    func list(prefix: String?, since: String?, cursor: String?, limit: Int?) async throws -> HttpSyncKvList {
        try await prepare()
        if legacyFallback {
            return try await delegate.list(prefix: prefix, since: since, cursor: cursor, limit: limit)
        }
        if let prefix, !prefix.hasPrefix(SyncKeys.allBooksPrefix) {
            return try await delegate.list(prefix: prefix, since: since, cursor: cursor, limit: limit)
        }
        let keys = cache.values
            .filter { prefix == nil || $0.key.hasPrefix(prefix!) }
            .filter { since == nil || $0.lastModified > since! }
            .filter { cursor == nil || $0.key > cursor! }
            .sorted { $0.key < $1.key }
            .map { HttpSyncKvKeyMeta(key: $0.key, lastModified: $0.lastModified,
                                    etag: $0.etag, size: $0.size, contentType: $0.contentType) }
        return HttpSyncKvList(keys: keys, truncated: false, nextCursor: nil)
    }

    func get(key: String) async throws -> HttpSyncKvFetched? {
        try await prepare()
        if legacyFallback { return try await delegate.get(key: key) }
        if !key.isPerBookKey { return try await delegate.get(key: key) }
        guard let item = cache[key] else { return nil }
        if let encoded = item.bodyBase64, let body = Data(base64Encoded: encoded) {
            return HttpSyncKvFetched(body: body, contentType: item.contentType,
                                     lastModified: item.lastModified, etag: item.etag)
        }
        guard let fetched = try await delegate.get(key: key) else { return nil }
        cache[key] = HttpSyncCachedExchangeKey(
            key: key, lastModified: fetched.lastModified, etag: fetched.etag,
            size: fetched.body.count, contentType: fetched.contentType,
            bodyBase64: fetched.body.count <= 512 * 1024 ? fetched.body.base64EncodedString() : nil
        )
        return fetched
    }

    func put(key: String, contentType: String, body: Data) async throws -> HttpSyncKvWriteResponse {
        try await prepare()
        if !legacyFallback, key.isBookmarkKey, pendingKeys.contains(key) {
            throw HttpSyncError("A newer local bookmark is awaiting conflict-safe acknowledgement.")
        }
        let written = try await delegate.put(key: key, contentType: contentType, body: body)
        cacheWrite(written, body: body)
        if legacyFallback, key.isBookmarkKey { resolvedLegacyKeys.insert(key) }
        return written
    }

    func putFile(key: String, contentType: String, fileURL: URL) async throws -> HttpSyncKvWriteResponse {
        try await prepare()
        let written = try await delegate.putFile(key: key, contentType: contentType, fileURL: fileURL)
        cacheWrite(written, body: nil)
        return written
    }

    func downloadToFile(key: String, targetURL: URL) async throws -> HttpSyncKvFileFetched? {
        try await prepare()
        return try await delegate.downloadToFile(key: key, targetURL: targetURL)
    }

    func delete(key: String) async throws {
        try await prepare()
        try await delegate.delete(key: key)
        cache.removeValue(forKey: key)
    }

    private func cacheWrite(_ written: HttpSyncKvWriteResponse, body: Data?) {
        cache[written.key] = HttpSyncCachedExchangeKey(
            key: written.key,
            lastModified: written.lastModified,
            etag: written.etag ?? "",
            size: written.size ?? body?.count ?? 0,
            contentType: written.contentType ?? "application/octet-stream",
            bodyBase64: body.flatMap { $0.count <= 512 * 1024 ? $0.base64EncodedString() : nil }
        )
    }
}

nonisolated private extension String {
    var isPerBookKey: Bool { hasPrefix(SyncKeys.allBooksPrefix) }
    var isBookmarkKey: Bool { isPerBookKey && hasSuffix("/bookmark") }
}
