import Foundation

/// Prevents sync from replacing a book directory while a reader is saving into it.
nonisolated final class HttpSyncActiveBooks: @unchecked Sendable {
    static let shared = HttpSyncActiveBooks()
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    static func open(_ syncId: String?) { shared.update(syncId, open: true) }
    static func close(_ syncId: String?) { shared.update(syncId, open: false) }
    static func contains(_ syncId: String) -> Bool {
        shared.lock.withLock { (shared.counts[syncId] ?? 0) > 0 }
    }
    static var hasAny: Bool { shared.lock.withLock { !shared.counts.isEmpty } }

    private func update(_ syncId: String?, open: Bool) {
        guard let syncId else { return }
        lock.withLock {
            if open {
                counts[syncId, default: 0] += 1
            } else if let count = counts[syncId] {
                counts[syncId] = count > 1 ? count - 1 : nil
            }
        }
    }
}
