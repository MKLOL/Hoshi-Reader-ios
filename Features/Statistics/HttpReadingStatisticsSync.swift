import Foundation
import CryptoKit

nonisolated struct ReadingStatisticsBlob: Codable {
    var version = 2
    var syncId: String
    var entries: [Statistics]
}
nonisolated struct MangaStatisticsBlob: Codable {
    var version = 2
    var syncId: String
    var entries: [MangaTextStatistic]
}

/// Serializes each book's read/merge/write exchange across manual sync and reader pushes.
@MainActor final class HttpReadingStatisticsSync {
    static let shared = HttpReadingStatisticsSync()
    static let stateFile = ".http_sync_statistics_state.json"
    private struct Stamp: Codable {
        var localHash: String
        var remoteSize: Int
        var remoteStamp: String
    }
    private var busy: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var scheduled: [String: Task<Void, Never>] = [:]
    private var failures = 0
    private var retryAfter = Date.distantPast

    func schedule(root: URL, delay: Duration = .seconds(30)) {
        let key = root.path
        scheduled[key]?.cancel()
        scheduled[key] = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self else { return }
            self.scheduled[key] = nil
            guard Date() >= self.retryAfter else { return }
            let config = HttpSyncSettingsStore.shared.currentConfig()
            guard config.isConfigured, let book = BookStorage.loadMetadata(root: root), let id = syncId(for: book) else { return }
            do {
                try await self.exchange(root: root, syncId: id, transport: HttpSyncKvClient(baseURL: config.baseURL, bearerToken: config.token))
                self.failures = 0
            } catch {
                self.failures += 1
                if self.failures >= 3 { self.retryAfter = Date().addingTimeInterval(300); self.failures = 0 }
            }
        }
    }

    func exchange(root: URL, syncId: String, transport: any HttpSyncKvTransport, listing: [String: HttpSyncKvKeyMeta]? = nil) async throws {
        let lock = root.standardizedFileURL.path
        if busy.contains(lock) { await withCheckedContinuation { waiters[lock, default: []].append($0) } }
        busy.insert(lock)
        defer {
            if var pending = waiters[lock], !pending.isEmpty {
                let next = pending.removeFirst(); waiters[lock] = pending; next.resume()
            } else { busy.remove(lock) }
        }
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        try ReadingStatisticsStore.migrate(root: root)
        try await exchangeReading(root: root, id: syncId, transport: transport, listing: listing)
        if ContentType.detect(bookDir: root) == .mokuro {
            try await exchangeText(root: root, id: syncId, transport: transport, listing: listing)
        }
    }

    private func exchangeReading(root: URL, id: String, transport: any HttpSyncKvTransport, listing: [String: HttpSyncKvKeyMeta]?) async throws {
        try await exchangeRows(root: root, key: "books/\(id)/statistics", transport: transport, listing: listing,
            load: { ReadingStatisticsStore.reading(root: root) },
            save: { try ReadingStatisticsStore.save($0, root: root, scheduleSync: false) },
            merge: Statistics.merged,
            encode: { try self.encode(ReadingStatisticsBlob(syncId: id, entries: $0)) },
            decode: { data in
                let blob = try JSONDecoder().decode(ReadingStatisticsBlob.self, from: data)
                guard (1...2).contains(blob.version), blob.syncId == id else { throw HttpSyncError("Unsupported reading statistics for \(id)") }
                return blob.entries
            })
    }
    private func exchangeText(root: URL, id: String, transport: any HttpSyncKvTransport, listing: [String: HttpSyncKvKeyMeta]?) async throws {
        try await exchangeRows(root: root, key: "books/\(id)/manga_statistics", transport: transport, listing: listing,
            load: { ReadingStatisticsStore.text(root: root) },
            save: { try ReadingStatisticsStore.saveText($0, root: root, scheduleSync: false) },
            merge: MangaTextStatistic.merged,
            encode: { try self.encode(MangaStatisticsBlob(syncId: id, entries: $0)) },
            decode: { data in
                let blob = try JSONDecoder().decode(MangaStatisticsBlob.self, from: data)
                guard (1...2).contains(blob.version), blob.syncId == id else { throw HttpSyncError("Unsupported manga statistics for \(id)") }
                return blob.entries
            })
    }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    func pushLocalChanges(transport: any HttpSyncKvTransport) async throws {
        guard let root = try? BookStorage.getBooksDirectory() else { return }
        for book in (try? BookStorage.loadAllBooks()) ?? [] {
            guard let folder = book.folder, let id = syncId(for: book) else { continue }
            try await exchange(root: root.appendingPathComponent(folder), syncId: id, transport: transport)
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private func exchangeRows<T: Equatable>(root: URL, key: String, transport: any HttpSyncKvTransport,
        listing: [String: HttpSyncKvKeyMeta]?, load: () -> [T], save: ([T]) throws -> Void,
        merge: ([T]) -> [T], encode: ([T]) throws -> Data, decode: (Data) throws -> [T]) async throws {
        let local = load()
        let body = try encode(local)
        let localHash = hash(body)
        let stateURL = root.appendingPathComponent(Self.stateFile)
        var state = BookStorage.load([String: Stamp].self, from: stateURL) ?? [:]
        let old = state[key]
        let meta = listing?[key]
        if old?.localHash == localHash {
            if listing == nil { return }
            if let meta, old?.remoteSize == meta.size, old?.remoteStamp == meta.lastModified { return }
        }
        if listing == nil, old == nil, local.isEmpty { return }
        if let meta, (meta.size ?? 0) > 4 * 1024 * 1024 { throw HttpSyncError("Statistics exceed the size limit") }
        let fetched = listing != nil && meta == nil ? nil : try await transport.get(key: key)
        if let fetched, fetched.body.count > 4 * 1024 * 1024 { throw HttpSyncError("Statistics exceed the size limit") }
        let remote = try fetched.map { merge(try decode($0.body)) } ?? []
        // The reader can save while GET is in flight. Re-read before merging.
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let latest = load()
        let merged = merge(latest + remote)
        if merged != latest { try save(merged) }
        if merged.isEmpty && fetched == nil { return }
        let mergedBody = try encode(merged)
        let size: Int
        let stamp: String
        if merged != remote {
            let written = try await transport.put(key: key, contentType: "application/json; charset=utf-8", body: mergedBody)
            size = mergedBody.count; stamp = written.lastModified
        } else {
            size = fetched?.body.count ?? 0; stamp = fetched?.lastModified ?? ""
        }
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        state[key] = Stamp(localHash: hash(mergedBody), remoteSize: size, remoteStamp: stamp)
        try BookStorage.save(state, inside: root, as: Self.stateFile)
    }
}
