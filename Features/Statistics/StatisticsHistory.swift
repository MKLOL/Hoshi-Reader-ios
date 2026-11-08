import Foundation
import CryptoKit

nonisolated struct StatisticsHistoryInfo: Codable, Sendable {
    var syncId: String
    var title: String?
    var contentType: ContentType?
    var progress: Double?
}
nonisolated struct StatisticsRoot: Sendable {
    var syncId: String
    var root: URL
    var title: String?
    var contentType: ContentType?
    var book: BookMetadata?
}

/// History belongs to the reader. Hidden folders travel with Books backups but stay off the shelf.
@MainActor enum StatisticsHistory {
    nonisolated static let directoryName = ".reading_history"
    nonisolated static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 64 && id.contains { $0 != "." } && id.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0)
        }
    }
    static func info(_ root: URL) -> StatisticsHistoryInfo? {
        BookStorage.load(StatisticsHistoryInfo.self, from: root.appendingPathComponent("history.json"))
    }
    static func historyRoot(_ id: String, title: String? = nil, type: ContentType? = nil, directory: URL? = nil) throws -> URL {
        guard validID(id) else { throw HttpSyncError("Invalid statistics book ID") }
        let books = try directory ?? BookStorage.getBooksDirectory()
        let root = books.appendingPathComponent(directoryName).appendingPathComponent(id)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var value = info(root) ?? StatisticsHistoryInfo(syncId: id)
        if let title, !title.isEmpty { value.title = title }
        if let type { value.contentType = type }
        try BookStorage.save(value, inside: root, as: "history.json")
        // Received history must never be attributed to this installation by the legacy migration.
        try Data().write(to: root.appendingPathComponent(".statistics_devices_v2"), options: .atomic)
        return root
    }
    static func roots(directory: URL? = nil, onError: ((String, Error) -> Void)? = nil) throws -> [StatisticsRoot] {
        let books = try directory ?? BookStorage.getBooksDirectory()
        let foldersOnShelf: [URL]
        do { foldersOnShelf = try FileManager.default.contentsOfDirectory(at: books, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) }
        catch { if let onError { onError("Books", error); foldersOnShelf = [] } else { throw error } }
        var library: [BookMetadata] = []
        for folder in foldersOnShelf {
            if let book = BookStorage.loadMetadata(root: folder) { library.append(book) }
            else if FileManager.default.fileExists(atPath: folder.appendingPathComponent(FileNames.metadata).path) || FileManager.default.fileExists(atPath: folder.appendingPathComponent(FileNames.statistics).path) {
                let error = HttpSyncError("Unreadable book metadata at \(folder.lastPathComponent)")
                if let onError { onError(folder.lastPathComponent, error) } else { throw error }
            }
        }
        var installed: [String: StatisticsRoot] = [:]
        for book in library {
            guard let id = syncId(for: book), let folder = book.folder else { continue }
            installed[id] = StatisticsRoot(syncId: id, root: books.appendingPathComponent(folder), title: book.title, contentType: book.resolvedContentType, book: book)
        }
        let parent = books.appendingPathComponent(directoryName)
        let folders: [URL]
        if FileManager.default.fileExists(atPath: parent.path) {
            do { folders = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey]) }
            catch { if let onError { onError(directoryName, error); folders = [] } else { throw error } }
        } else { folders = [] }
        for folder in folders {
            guard validID(folder.lastPathComponent) else { continue }
            guard let value = info(folder), value.syncId == folder.lastPathComponent else {
                let error = HttpSyncError("Unreadable retained history at \(folder.lastPathComponent)")
                if let onError { onError(folder.lastPathComponent, error); continue } else { throw error }
            }
            if let local = installed[value.syncId] {
                do { try absorb(history: folder, into: local.root) }
                catch { if let onError { onError(value.syncId, error) } else { throw error } }
            }
            else {
                installed[value.syncId] = StatisticsRoot(syncId: value.syncId, root: folder, title: value.title, contentType: value.contentType, book: nil)
            }
        }
        return installed.values.sorted { $0.syncId < $1.syncId }
    }
    static func absorb(history: URL, into root: URL) throws {
        try ReadingStatisticsStore.migrate(root: root)
        let reading = Statistics.merged(try ReadingStatisticsStore.strictReading(root: root) + ReadingStatisticsStore.strictReading(root: history))
        let text = MangaTextStatistic.merged(try ReadingStatisticsStore.strictText(root: root) + ReadingStatisticsStore.strictText(root: history))
        try BookStorage.save(reading, inside: root, as: FileNames.statistics)
        if !text.isEmpty { try BookStorage.save(text, inside: root, as: FileNames.mangaStatistics) }
        try FileManager.default.removeItem(at: history)
    }
    static func absorbIfPresent(root: URL) throws {
        guard let book = BookStorage.loadMetadata(root: root), let id = syncId(for: book) else { return }
        let history = try BookStorage.getBooksDirectory().appendingPathComponent(directoryName).appendingPathComponent(id)
        if FileManager.default.fileExists(atPath: history.path) { try absorb(history: history, into: root) }
    }
    static func retain(root: URL) throws {
        guard let book = BookStorage.loadMetadata(root: root), let id = syncId(for: book) else { return }
        try ReadingStatisticsStore.migrate(root: root)
        let reading = try ReadingStatisticsStore.strictReading(root: root), text = try ReadingStatisticsStore.strictText(root: root)
        guard !reading.isEmpty || !text.isEmpty else { return }
        let kept = try historyRoot(id, title: book.title, type: book.resolvedContentType)
        try BookStorage.save(Statistics.merged(try ReadingStatisticsStore.strictReading(root: kept) + reading), inside: kept, as: FileNames.statistics)
        try BookStorage.save(MangaTextStatistic.merged(try ReadingStatisticsStore.strictText(root: kept) + text), inside: kept, as: FileNames.mangaStatistics)
        var value = info(kept)!
        let bookmark = BookStorage.loadBookmark(root: root)
        if let total = BookStorage.loadBookInfo(root: root)?.characterCount, total > 0, let bookmark {
            value.progress = Double(bookmark.characterCount) / Double(total)
        } else if book.resolvedContentType == .mokuro { value.progress = bookmark?.progress }
        try BookStorage.save(value, inside: kept, as: "history.json")
    }
    static func metadata(for root: StatisticsRoot) -> BookMetadata {
        if let book = root.book { return book }
        // Deterministic detail-page identity survives reloads and app restarts.
        let bytes = Array(SHA256.hash(data: Data(root.syncId.utf8)).prefix(16))
        let id = UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
        return BookMetadata(id: id, title: root.title ?? root.syncId, cover: nil, folder: nil, lastAccess: .distantPast, contentType: root.contentType, syncId: root.syncId)
    }
}
