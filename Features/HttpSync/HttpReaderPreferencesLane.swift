import Foundation

/// Small preference shards use the foreground metadata lane, independently of large book
/// transfers. Every device writes only its own shard, preserving concurrent peer edits.
@MainActor
final class HttpReaderPreferencesLane {
    static let shared = HttpReaderPreferencesLane(store: ReaderPreferencesStore.shared)
    struct Outcome { var uploaded = false; var downloaded = false; var errors: [String] = [] }
    private let store: ReaderPreferencesSyncing
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var pollTask: Task<Void, Never>?
    private var lastSuccessful: (scope: String, metadata: [String: HttpSyncKvKeyMeta], records: [String: ReaderPreferenceRecord])?

    init(store: ReaderPreferencesSyncing) { self.store = store }

    func poll(transport: HttpSyncKvTransport, listing: [String: HttpSyncKvKeyMeta], scope: String, stillCurrent: @escaping @MainActor () -> Bool) {
        guard pollTask == nil else { return }
        pollTask = Task {
            _ = await run(transport: transport, listing: listing, scope: scope, stillCurrent: stillCurrent)
            pollTask = nil
        }
    }

    func run(transport: HttpSyncKvTransport, listing: [String: HttpSyncKvKeyMeta]? = nil, scope: String? = nil,
             stillCurrent: @escaping @MainActor () -> Bool = { true }) async -> Outcome {
        if busy { await withCheckedContinuation { waiters.append($0) } } else { busy = true }
        defer {
            if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        }
        var outcome = Outcome()
        do {
            try Task.checkCancellation()
            guard stillCurrent() else { return outcome }
            let initial = try store.snapshot()
            guard ReaderPreferencesProtocol.validDevice(store.deviceId) else { throw HttpSyncError("Invalid reader preferences identity.") }
            let ownKey = ReaderPreferencesProtocol.prefix + store.deviceId
            var keys = Set<String>()
            var metadata: [String: HttpSyncKvKeyMeta] = [:]
            var cursor: String?
            var cursors = Set<String>()
            if let listing {
                metadata = listing.filter { $0.key.hasPrefix(ReaderPreferencesProtocol.prefix) }
                keys = Set(metadata.keys)
            } else { repeat {
                let page = try await transport.list(prefix: ReaderPreferencesProtocol.prefix, since: nil, cursor: cursor, limit: 256)
                for meta in page.keys where meta.key.hasPrefix(ReaderPreferencesProtocol.prefix) { keys.insert(meta.key); metadata[meta.key] = meta }
                guard keys.union([ownKey]).count <= 256 else { throw HttpSyncError("Too many reader preferences devices.") }
                if page.truncated != true { break }
                guard let next = page.nextCursor, !next.isEmpty, cursors.insert(next).inserted, cursors.count < 256 else {
                    throw HttpSyncError("Invalid reader preferences listing.")
                }
                cursor = next
            } while true }
            guard keys.union([ownKey]).count <= 256 else { throw HttpSyncError("Too many reader preferences devices.") }
            if let scope, let previous = lastSuccessful, previous.scope == scope,
               previous.metadata == metadata, previous.records == initial { return outcome }
            var merged = initial
            var own: ReaderPreferencesBlob?
            var canPublish = true
            for key in [ownKey] + keys.subtracting([ownKey]).sorted() {
                try Task.checkCancellation()
                guard stillCurrent() else { return Outcome() }
                let id = String(key.dropFirst(ReaderPreferencesProtocol.prefix.count))
                guard ReaderPreferencesProtocol.validDevice(id) else {
                    outcome.errors.append("Invalid reader preferences key.")
                    canPublish = false
                    continue
                }
                do {
                    guard let fetched = try await transport.getBounded(key: key, maxBytes: ReaderPreferencesProtocol.maxBody) else { continue }
                    struct Version: Decodable { var version: Int? }
                    let version = try JSONDecoder().decode(Version.self, from: fetched.body).version ?? 1
                    guard version == 1 else {
                        outcome.errors.append("Reader preferences use an unsupported version.")
                        if key == ownKey { canPublish = false }
                        continue
                    }
                    let blob = try JSONDecoder().decode(ReaderPreferencesBlob.self, from: fetched.body)
                    guard blob.deviceId == id else { throw HttpSyncError("Invalid reader preferences identity.") }
                    try ReaderPreferencesProtocol.validate(blob.records)
                    guard Set(merged.keys).union(blob.records.keys).count <= 256 else { throw HttpSyncError("Too many reader preferences.") }
                    for (name, record) in blob.records where record.isNewer(than: merged[name]) { merged[name] = record }
                    if key == ownKey { own = blob }
                } catch is CancellationError { throw CancellationError() }
                catch { canPublish = false; outcome.errors.append("Could not read reader preferences.") }
            }
            guard stillCurrent() else { return Outcome() }
            outcome.downloaded = try store.merge(merged)
            let latest = try store.snapshot() // Includes edits made during the network awaits.
            if canPublish, !latest.isEmpty, latest != own?.records {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let body = try encoder.encode(ReaderPreferencesBlob(deviceId: store.deviceId, records: latest))
                guard body.count <= ReaderPreferencesProtocol.maxBody else { throw HttpSyncError("Reader preferences exceed the size limit.") }
                try Task.checkCancellation()
                guard stillCurrent() else { return Outcome() }
                _ = try await transport.put(key: ownKey, contentType: "application/json; charset=utf-8", body: body)
                outcome.uploaded = true
            }
            if outcome.errors.isEmpty, let scope {
                lastSuccessful = (scope, metadata, latest)
            }
        } catch is CancellationError { }
        catch { outcome.errors.append("Could not synchronize reader preferences.") }
        return outcome
    }
}
