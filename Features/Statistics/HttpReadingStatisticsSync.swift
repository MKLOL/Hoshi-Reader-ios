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
        var remoteETag: String? = nil
        var pendingUpload: Bool? = nil
    }
    private var busy: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func schedule(root: URL, delay: Duration = .seconds(30)) {
        HttpStatisticsLane.shared.schedule(flush: delay < .seconds(30))
    }

    /// Whether the book needed any exchange: false when its rows and the server's copy were as
    /// the last exchange left them, with nothing waiting to upload.
    @discardableResult
    func exchange(root: URL, syncId: String, transport: any HttpSyncKvTransport, listing: [String: HttpSyncKvKeyMeta]? = nil, uploadLocal: Bool = true, stillCurrent: @escaping @MainActor () -> Bool = { true }) async throws -> Bool {
        let lock = root.standardizedFileURL.path
        if busy.contains(lock) { await withCheckedContinuation { waiters[lock, default: []].append($0) } }
        busy.insert(lock)
        defer {
            if var pending = waiters[lock], !pending.isEmpty {
                let next = pending.removeFirst(); waiters[lock] = pending; next.resume()
            } else { busy.remove(lock) }
        }
        try checkCurrent(stillCurrent)
        guard FileManager.default.fileExists(atPath: root.path) else { return false }
        try ReadingStatisticsStore.migrate(root: root)
        var exchanged = try await exchangeReading(root: root, id: syncId, transport: transport, listing: listing, uploadLocal: uploadLocal, stillCurrent: stillCurrent)
        try checkCurrent(stillCurrent)
        if ReadingStatisticsStore.contentType(root: root) == .mokuro {
            exchanged = try await exchangeText(root: root, id: syncId, transport: transport, listing: listing, uploadLocal: uploadLocal, stillCurrent: stillCurrent) || exchanged
            try checkCurrent(stillCurrent)
        }
        return exchanged
    }

    private func exchangeReading(root: URL, id: String, transport: any HttpSyncKvTransport, listing: [String: HttpSyncKvKeyMeta]?, uploadLocal: Bool, stillCurrent: @escaping @MainActor () -> Bool) async throws -> Bool {
        try await exchangeRows(root: root, key: "books/\(id)/statistics", transport: transport, listing: listing, uploadLocal: uploadLocal, stillCurrent: stillCurrent,
            load: { try ReadingStatisticsStore.strictReading(root: root) },
            save: { try ReadingStatisticsStore.save($0, root: root, scheduleSync: false) },
            merge: Statistics.merged,
            encode: { try self.encode(ReadingStatisticsBlob(syncId: id, entries: $0)) },
            decode: { data in
                let blob = try JSONDecoder().decode(ReadingStatisticsBlob.self, from: data)
                if blob.version > 2 { throw HttpSyncError("Statistics need a newer app", skip: true) }
                guard (1...2).contains(blob.version), blob.syncId == id else { throw HttpSyncError("Unsupported reading statistics for \(id)") }
                return blob.entries
            })
    }
    private func exchangeText(root: URL, id: String, transport: any HttpSyncKvTransport, listing: [String: HttpSyncKvKeyMeta]?, uploadLocal: Bool, stillCurrent: @escaping @MainActor () -> Bool) async throws -> Bool {
        try await exchangeRows(root: root, key: "books/\(id)/manga_statistics", transport: transport, listing: listing, uploadLocal: uploadLocal, stillCurrent: stillCurrent,
            load: { try ReadingStatisticsStore.strictText(root: root) },
            save: { try ReadingStatisticsStore.saveText($0, root: root, scheduleSync: false) },
            merge: MangaTextStatistic.merged,
            encode: { try self.encode(MangaStatisticsBlob(syncId: id, entries: $0)) },
            decode: { data in
                let blob = try JSONDecoder().decode(MangaStatisticsBlob.self, from: data)
                if blob.version > 2 { throw HttpSyncError("Statistics need a newer app", skip: true) }
                guard (1...2).contains(blob.version), blob.syncId == id else { throw HttpSyncError("Unsupported manga statistics for \(id)") }
                return blob.entries
            })
    }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).lowercaseHex }
    private func checkCurrent(_ stillCurrent: @MainActor () -> Bool) throws {
        try Task.checkCancellation()
        guard stillCurrent() else { throw CancellationError() }
    }

    func pushLocalChanges(transport: any HttpSyncKvTransport, listing: [String: HttpSyncKvKeyMeta]? = nil) async -> [String] {
        do {
            let directory = try BookStorage.getBooksDirectory()
            let roots = try BookStorage.loadAllBooks().compactMap { book -> (root: URL, syncId: String)? in
                guard let folder = book.folder, let id = syncId(for: book) else { return nil }
                return (directory.appendingPathComponent(folder), id)
            }
            return await pushLocalChanges(roots: roots, transport: transport, listing: listing)
        } catch { return ["Statistics: \(error.localizedDescription)"] }
    }

    /// A damaged statistics sidecar must not prevent other books or bookmarks from syncing.
    func pushLocalChanges(roots: [(root: URL, syncId: String)], transport: any HttpSyncKvTransport, listing: [String: HttpSyncKvKeyMeta]? = nil) async -> [String] {
        var errors: [String] = []
        for book in roots {
            do { try await exchange(root: book.root, syncId: book.syncId, transport: transport, listing: listing) }
            catch { errors.append("Statistics \(book.syncId): \(error.localizedDescription)") }
        }
        return errors
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private func exchangeRows<T: Equatable>(root: URL, key: String, transport: any HttpSyncKvTransport,
        listing: [String: HttpSyncKvKeyMeta]?, uploadLocal: Bool, stillCurrent: @MainActor () -> Bool, load: () throws -> [T], save: ([T]) throws -> Void,
        merge: ([T]) -> [T], encode: ([T]) throws -> Data, decode: (Data) throws -> [T]) async throws -> Bool {
        try checkCurrent(stillCurrent)
        let local = try load()
        let body = try encode(local)
        let localHash = hash(body)
        let stateURL = root.appendingPathComponent(Self.stateFile)
        var state = BookStorage.load([String: Stamp].self, from: stateURL) ?? [:]
        let old = state[key]
        let meta = listing?[key]
        if old?.localHash == localHash {
            if listing == nil { return old?.pendingUpload == true }
            if let meta, old?.remoteSize == meta.size, old?.remoteStamp == meta.lastModified,
               let etag = meta.etag, !etag.isEmpty, old?.remoteETag == etag, old?.pendingUpload != true || !uploadLocal { return old?.pendingUpload == true }
        }
        if listing == nil, old == nil, local.isEmpty { return false }
        if let meta, (meta.size ?? 0) > 4 * 1024 * 1024 { throw HttpSyncError("Statistics exceed the size limit") }
        // Absence is only a snapshot. A peer may have written this key after the listing;
        // fetch again before a nonempty upload so we merge rather than erase its first day.
        if listing != nil, meta == nil, local.isEmpty { return false }
        let fetched = try await transport.getBounded(key: key, maxBytes: 4 * 1024 * 1024)
        try checkCurrent(stillCurrent)
        if let fetched, fetched.body.count > 4 * 1024 * 1024 { throw HttpSyncError("Statistics exceed the size limit") }
        let remote = try fetched.map { merge(try decode($0.body)) } ?? []
        // The reader can save while GET is in flight. Re-read before merging.
        guard FileManager.default.fileExists(atPath: root.path) else { return true }
        let latest = try load()
        let merged = merge(latest + remote)
        if merged != latest { try save(merged) }
        if merged.isEmpty && fetched == nil { return true }
        let mergedBody = try encode(merged)
        let size: Int
        let stamp: String
        let etag: String?
        if merged != remote && uploadLocal {
            let written = try await transport.put(key: key, contentType: "application/json; charset=utf-8", body: mergedBody)
            try checkCurrent(stillCurrent)
            size = mergedBody.count; stamp = written.lastModified; etag = written.etag
        } else {
            size = fetched?.body.count ?? 0; stamp = fetched?.lastModified ?? ""; etag = fetched?.etag ?? ""
        }
        guard FileManager.default.fileExists(atPath: root.path) else { return true }
        state[key] = Stamp(localHash: hash(mergedBody), remoteSize: size, remoteStamp: stamp, remoteETag: etag, pendingUpload: !uploadLocal && merged != remote)
        try BookStorage.save(state, inside: root, as: Self.stateFile)
        return true
    }
}
