import Foundation

/// A bounded metadata cache, independent of the reader's decoded translation cache. Load off-main
/// after publishing the shelf so a large collection of translated books never delays its first paint.
nonisolated final class BookTranslationAvailability: @unchecked Sendable {
    static let shared = BookTranslationAvailability()
    struct Book: Sendable {
        let id: UUID
        let root: URL
        let syncId: String
    }
    private struct Stamp: Equatable {
        let size: UInt64
        let modified: Date
        let inode: UInt64
        let syncId: String
    }
    private let lock = NSLock()
    private var cache: [URL: (Stamp, Bool)] = [:]
    private var order: [URL] = []
    private let read: @Sendable (URL) throws -> Data
    init(read: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }) { self.read = read }

    func load(_ books: [Book]) -> Set<UUID> {
        Set(books.filter { hasTranslations(root: $0.root, syncId: $0.syncId) }.map(\.id))
    }

    func hasTranslations(root: URL, syncId: String) -> Bool {
        lock.withLock {
            let manga = FileManager.default.fileExists(atPath: root.appendingPathComponent("mokuro.json").path)
            let url = root.appendingPathComponent(manga ? "pretranslations.json" : "sentence_translations.json")
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attrs[.type] as? FileAttributeType == .typeRegular,
                  let size = (attrs[.size] as? NSNumber)?.uint64Value, size <= 50 * 1024 * 1024,
                  let modified = attrs[.modificationDate] as? Date else {
                cache[url] = nil
                order.removeAll { $0 == url }
                return false
            }
            let stamp = Stamp(size: size, modified: modified,
                inode: (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0, syncId: syncId)
            if let cached = cache[url], cached.0 == stamp { return cached.1 }
            let available = (try? read(url)).map { data in
                if manga {
                    guard let blob = try? JSONDecoder().decode(HttpSyncPretranslationsBlob.self, from: data),
                          (1...HttpSyncPretranslationsBlob.supportedVersion).contains(blob.version),
                          blob.syncId.isEmpty || blob.syncId == syncId else { return false }
                    return blob.entries.values.contains {
                        !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                        !$0.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }
                }
                guard let blob = try? JSONDecoder().decode(HttpSyncSentencesBlob.self, from: data) else { return false }
                return blob.validationError(expectedSyncId: syncId, spineCount: blob.spineCount) == nil
            } ?? false
            cache[url] = (stamp, available)
            order.removeAll { $0 == url }
            order.append(url)
            if order.count > 128 { cache.removeValue(forKey: order.removeFirst()) }
            return available
        }
    }
}
