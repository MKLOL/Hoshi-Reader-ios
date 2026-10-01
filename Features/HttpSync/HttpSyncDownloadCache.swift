import Foundation
import CryptoKit

nonisolated final class HttpSyncDownloadCache: @unchecked Sendable {
    static let shared = HttpSyncDownloadCache()
    private let lock = NSLock()
    private var active: [URL: Int] = [:]
    static let retention: TimeInterval = 7 * 24 * 60 * 60

    func directory(books: URL, key: String, archiveSHA: String) -> URL {
        let digest = SHA256.hash(data: Data((key + "\n" + archiveSHA).utf8)).map { String(format: "%02x", $0) }.joined()
        return books.appendingPathComponent(".http-sync-downloads", isDirectory: true).appendingPathComponent(digest, isDirectory: true)
    }
    func acquire(_ directory: URL, now: Date = Date()) throws {
        try lock.withLock {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: directory.path)
            active[directory, default: 0] += 1
        }
    }
    func release(_ directory: URL) {
        lock.withLock {
            if active[directory, default: 0] <= 1 { active[directory] = nil }
            else { active[directory, default: 0] -= 1 }
        }
    }
    struct Summary: Sendable, Equatable {
        var count = 0
        var bytes: Int64 = 0
    }
    func summary(books: URL, excluding: Set<URL> = []) -> Summary {
        lock.withLock {
            let root = books.appendingPathComponent(".http-sync-downloads", isDirectory: true)
            let entries = (try? FileManager.default.contentsOfDirectory(at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
            var result = Summary()
            for entry in entries where active[entry] == nil && !excluding.contains(entry) {
                guard entry.lastPathComponent.count == 64, entry.lastPathComponent.allSatisfy({ $0.isHexDigit }),
                      let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true, values.isSymbolicLink != true else { continue }
                result.count += 1
                if let files = FileManager.default.enumerator(at: entry, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]) {
                    for case let file as URL in files {
                        if let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
                           values.isRegularFile == true, values.isSymbolicLink != true {
                            result.bytes += Int64(values.fileSize ?? 0)
                        }
                    }
                }
            }
            return result
        }
    }
    /// Ignore unrelated files and all active transfers. Revalidate the timestamp at deletion.
    @discardableResult func clean(books: URL, olderThan cutoff: Date, excluding: Set<URL> = []) -> Int {
        lock.withLock {
            let root = books.appendingPathComponent(".http-sync-downloads", isDirectory: true)
            let entries = (try? FileManager.default.contentsOfDirectory(at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey])) ?? []
            var removed = 0
            for entry in entries where active[entry] == nil && !excluding.contains(entry) {
                guard entry.lastPathComponent.count == 64, entry.lastPathComponent.allSatisfy({ $0.isHexDigit }),
                      let attributes = try? entry.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey]),
                      attributes.isDirectory == true, attributes.isSymbolicLink != true,
                      let modified = attributes.contentModificationDate, modified < cutoff else { continue }
                if (try? FileManager.default.removeItem(at: entry)) != nil { removed += 1 }
            }
            return removed
        }
    }
}
