//
//  HttpSyncBatchExchange.swift
//  Hoshi Reader
//
//  One-round-trip remote index cache and durable bookmark outbox.
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

nonisolated private struct HttpSyncPendingBookmark: Codable, Sendable {
    let key: String
    let baseEtag: String?
    let mutationId: String
    let contentType: String
    let bodyBase64: String
}

/// Main-actor file store. Mutations are atomic and accepted writes are removed by
/// mutation id, so an in-flight exchange can never erase a newer page turn.
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
            baseEtag: prior?.baseEtag ?? loadCache()[key]?.etag,
            mutationId: UUID().uuidString,
            contentType: "application/json; charset=utf-8",
            bodyBase64: body.base64EncodedString()
        ))
        savePending(pending.sorted { $0.key < $1.key })
    }

    func exchangeRequest() -> HttpSyncExchangeRequest {
        let cache = loadCache()
        return HttpSyncExchangeRequest(
            knownEtags: cache.mapValues(\.etag),
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

    func applyExchange(_ response: HttpSyncExchangeResponse) {
        let old = loadCache()
        var next = old
        for key in response.removedKeys { next.removeValue(forKey: key) }
        for remote in response.keys {
            let retainedBody: String?
            if let body = remote.bodyBase64 {
                retainedBody = body
            } else if old[remote.key]?.etag == remote.etag {
                retainedBody = old[remote.key]?.bodyBase64
            } else {
                retainedBody = nil
            }
            next[remote.key] = HttpSyncCachedExchangeKey(
                key: remote.key,
                lastModified: remote.lastModified,
                etag: remote.etag,
                size: remote.size,
                contentType: remote.contentType,
                bodyBase64: retainedBody
            )
        }
        saveCache(next)

        let accepted = Dictionary(
            uniqueKeysWithValues: response.writeAcks.filter(\.accepted).map { ($0.mutationId, $0.key) }
        )
        savePending(loadPending().filter { accepted[$0.mutationId] != $0.key })
    }

    func saveCache(_ cache: [String: HttpSyncCachedExchangeKey]) {
        guard let url = fileURL(cacheFilename), let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func cacheSnapshot() -> [String: HttpSyncCachedExchangeKey] { loadCache() }
    var hasPending: Bool { !loadPending().isEmpty }
    var pendingKeys: Set<String> { Set(loadPending().map(\.key)) }

    private func loadCache() -> [String: HttpSyncCachedExchangeKey] {
        guard let url = fileURL(cacheFilename), let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: HttpSyncCachedExchangeKey].self, from: data)) ?? [:]
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

/// Actor-backed transport which serves all small GETs and the listing from the
/// exchange snapshot. Large changed payloads fall back to the streaming KV API.
actor HttpSyncBatchKvTransport: HttpSyncKvTransport {
    private let delegate: HttpSyncKvClient
    private let request: HttpSyncExchangeRequest
    private var cache: [String: HttpSyncCachedExchangeKey]
    private var pendingKeys: Set<String>
    private var prepared = false
    private var response: HttpSyncExchangeResponse?

    init(config: HttpSyncConfig, request: HttpSyncExchangeRequest,
         cache: [String: HttpSyncCachedExchangeKey]) {
        delegate = HttpSyncKvClient(baseURL: config.baseURL, bearerToken: config.token)
        self.request = request
        self.cache = cache
        pendingKeys = Set(request.writes.map(\.key))
    }

    func prepare() async throws {
        guard !prepared else { return }
        let exchange = try await delegate.exchange(request)
        for key in exchange.removedKeys { cache.removeValue(forKey: key) }
        for remote in exchange.keys {
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
        let accepted = Set(exchange.writeAcks.filter(\.accepted).map(\.key))
        pendingKeys.subtract(accepted)
        response = exchange
        prepared = true
    }

    func exchangeResponse() -> HttpSyncExchangeResponse? { response }
    func cacheSnapshot() -> [String: HttpSyncCachedExchangeKey] { cache }
    func setPendingKeys(_ keys: Set<String>) { pendingKeys = keys }

    func list(prefix: String?, since: String?, cursor: String?, limit: Int?) async throws -> HttpSyncKvList {
        try await prepare()
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
        if key.hasSuffix("/bookmark"), pendingKeys.contains(key) {
            throw HttpSyncError("A newer local bookmark is awaiting conflict-safe acknowledgement.")
        }
        let written = try await delegate.put(key: key, contentType: contentType, body: body)
        cacheWrite(written, body: body)
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
