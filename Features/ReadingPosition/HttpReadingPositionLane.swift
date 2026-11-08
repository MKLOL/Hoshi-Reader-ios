import Foundation

/// Independent single-writer position histories run after the inexpensive bookmark maps.
/// Unknown/invalid unchanged bodies are remembered, failed requests back off, and each pass
/// fetches at most 32 histories so a fresh library cannot block foreground map synchronization.
@MainActor
final class HttpReadingPositionLane {
    static let shared = HttpReadingPositionLane(store: .shared)
    struct Outcome { var moved: Set<String> = []; var published: Set<String> = []; var errors: [String] = [] }
    private struct Index: Codable {
        var applied: [String: String] = [:]
        var published: [String: String] = [:]
        var unusable: [String: String] = [:]
    }
    private struct Failure { var etag: String; var retryAt: Date; var pause: Double }
    private let store: ReadingPositionRepository
    private var failures: [String: Failure] = [:]
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var currentScope: String?
    init(store: ReadingPositionRepository) { self.store = store }

    func run(transport: HttpSyncKvTransport, listing: [String: HttpSyncKvKeyMeta], scope: String,
             stillCurrent: @escaping @MainActor () -> Bool = { true }) async -> Outcome {
        if busy { await withCheckedContinuation { waiters.append($0) } } else { busy = true }
        defer { if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() } }
        guard stillCurrent(), !Task.isCancelled else { return Outcome() }
        var roots: [String: URL] = [:]
        if let directory = try? BookStorage.getBooksDirectory() {
            for book in (try? BookStorage.loadAllBooks()) ?? [] {
                guard let id = syncId(for: book), let folder = book.folder else { continue }
                roots[id] = directory.appendingPathComponent(folder)
            }
        }
        return await exchange(transport: transport, listing: listing, roots: roots, scope: scope, stillCurrent: stillCurrent)
    }

    /// Explicit roots and a separate repository make the actual transport behavior testable.
    func exchange(transport: HttpSyncKvTransport, listing: [String: HttpSyncKvKeyMeta], roots: [String: URL], scope: String,
                  stillCurrent: @escaping @MainActor () -> Bool = { true }) async -> Outcome {
        let (stored, generation) = store.loadSyncIndex()
        // A different account/server cannot reuse another server's ETag acknowledgements.
        struct Scoped: Codable { var scope: String; var index: Index }
        var index: Index
        if let stored, let decoded = try? JSONDecoder().decode(Scoped.self, from: stored), decoded.scope == scope { index = decoded.index }
        else { index = Index() }
        if currentScope != scope { failures = [:]; currentScope = scope }
        var outcome = Outcome(), reads = 0
        defer {
            // A later cancellation still notifies for durable commits already applied. One
            // notification per book reveals the final winner after all received histories.
            for book in outcome.moved {
                NotificationCenter.default.post(name: .httpSyncBookmarkApplied, object: nil, userInfo: ["syncId": book])
            }
        }
        for (bookId, root) in roots {
            let before = BookStorage.loadBookmark(root: root).map(ReadingPosition.init)
            store.observe(bookId: bookId, root: root)
            let after = BookStorage.loadBookmark(root: root).map(ReadingPosition.init)
            if let after, before == nil || !after.samePlace(as: before!) { outcome.moved.insert(bookId) }
        }
        let device = store.device.id
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        func checkpoint() {
            guard stillCurrent(), let data = try? encoder.encode(Scoped(scope: scope, index: index)) else { return }
            store.saveSyncIndex(data, generation: generation)
        }
        func stamp(_ meta: HttpSyncKvKeyMeta) -> String {
            meta.etag ?? "stamp:\(meta.lastModified):\(meta.size ?? -1)"
        }
        func backedOff(_ key: String, _ etag: String) -> Bool {
            guard let failed = failures[key], failed.etag == etag else { return false }
            return Date.now < failed.retryAt
        }
        func failed(_ key: String, _ etag: String) {
            let previous = failures[key].flatMap { $0.etag == etag ? $0 : nil }
            let pause = min(600, (previous?.pause ?? 15) * 2)
            failures[key] = Failure(etag: etag, retryAt: Date.now.addingTimeInterval(pause), pause: pause)
            outcome.errors.append("Could not synchronize a reading position history.")
        }
        func receive(_ meta: HttpSyncKvKeyMeta, book: String, writer: String) async -> Bool {
            guard stillCurrent(), !Task.isCancelled else { return false }
            reads += 1
            do {
                guard let fetched = try await transport.getBounded(key: meta.key, maxBytes: 2 * 1024 * 1024) else {
                    index.unusable[meta.key] = stamp(meta); index.applied[meta.key] = nil; return true
                }
                guard stillCurrent(), !Task.isCancelled else { return false }
                // As on Android: the listed ETag when the body is the listed version, or when a proxy
                // dropped or weakened the header, so the next listing matches; otherwise the header
                // of a body that changed after the listing.
                let header = fetched.etag.trimmingCharacters(in: .whitespaces)
                let listedBody = meta.etag == "sha256:" + ReadingPositionRepository.digest(fetched.body)
                let etag = meta.etag == nil || listedBody || header.isEmpty || header.hasPrefix("W/") ? stamp(meta) : header
                do {
                    let journal = try JSONDecoder().decode(ReadingPositionJournal.self, from: fetched.body)
                    guard journal.version == 1, journal.bookId == book, journal.deviceId == writer else {
                        throw ReadingPositionProtocolError.invalidJournal
                    }
                    if try store.merge(journal, root: roots[book]) { outcome.moved.insert(book) }
                    index.applied[meta.key] = etag; index.unusable[meta.key] = nil
                } catch is DecodingError {
                    index.unusable[meta.key] = etag; index.applied[meta.key] = nil
                } catch is ReadingPositionProtocolError {
                    index.unusable[meta.key] = etag; index.applied[meta.key] = nil
                }
                failures[meta.key] = nil
                return true
            } catch is CancellationError { return false }
            catch let error as HttpSyncError where error.message.contains("size limit") {
                index.unusable[meta.key] = stamp(meta); index.applied[meta.key] = nil
                return true
            } catch { failed(meta.key, stamp(meta)); return false }
        }
        func activeFirst(_ lhs: (HttpSyncKvKeyMeta, String, String), _ rhs: (HttpSyncKvKeyMeta, String, String)) -> Bool {
            let left = HttpSyncActiveBooks.contains(lhs.1), right = HttpSyncActiveBooks.contains(rhs.1)
            return left != right ? left : lhs.0.key < rhs.0.key
        }
        let entries: [(HttpSyncKvKeyMeta, String, String)] = listing.values.compactMap { meta in
            ReadingPositionProtocol.parseKey(meta.key).map { (meta, $0.book, $0.device) }
        }.sorted(by: activeFirst)
        let ownBefore = store.ownHistories()
        var blocked: Set<String> = []
        // Restore this device's published journal before overwriting it, including after a
        // local journal has been set aside. Unknown other writers cannot block local events.
        for (meta, book, writer) in entries where writer == device {
            guard stillCurrent(), !Task.isCancelled else { checkpoint(); return outcome }
            if index.unusable[meta.key] == stamp(meta) { continue }
            if index.applied[meta.key] == stamp(meta) && ownBefore[book] != nil { continue }
            if ownBefore[book] == nil && roots[book] == nil { continue }
            if reads >= 32 || backedOff(meta.key, stamp(meta)) { blocked.insert(book); continue }
            if !(await receive(meta, book: book, writer: writer)) { blocked.insert(book) }
        }
        checkpoint()
        for (book, pending) in store.ownHistories() where !blocked.contains(book) {
            guard stillCurrent(), !Task.isCancelled else { checkpoint(); return outcome }
            let key = ReadingPositionProtocol.prefix + book + "/" + device + ".json", meta = listing[key]
            if pending.isEmpty, let meta, index.applied[key] == stamp(meta), index.published[key] != nil { continue }
            if backedOff(key, meta.map(stamp) ?? "") { continue }
            guard let journal = store.export(bookId: book), let body = try? encoder.encode(journal) else { continue }
            let digest = ReadingPositionRepository.digest(body)
            let ids = Set((journal.events + journal.heads).map(\.id))
            if let meta, meta.etag == "sha256:" + digest || (index.applied[key] == stamp(meta) && index.published[key] == digest) {
                index.applied[key] = stamp(meta); index.published[key] = digest; index.unusable[key] = nil
                store.acknowledge(bookId: book, ids: ids)
                continue
            }
            do {
                let result = try await transport.put(key: key, contentType: "application/json", body: body)
                guard stillCurrent() else { return outcome }
                index.applied[key] = result.etag ?? "sha256:" + digest; index.published[key] = digest; index.unusable[key] = nil
                store.acknowledge(bookId: book, ids: ids)
                failures[key] = nil; outcome.published.insert(book)
            } catch is CancellationError { checkpoint(); return outcome }
            catch { failed(key, meta.map(stamp) ?? "") }
        }
        checkpoint()
        for (meta, book, writer) in entries where writer != device && roots[book] != nil {
            guard stillCurrent(), !Task.isCancelled else { checkpoint(); return outcome }
            if reads >= 32 { break }
            if index.applied[meta.key] == stamp(meta) || index.unusable[meta.key] == stamp(meta) || backedOff(meta.key, stamp(meta)) { continue }
            _ = await receive(meta, book: book, writer: writer)
        }
        checkpoint()
        return outcome
    }
}
