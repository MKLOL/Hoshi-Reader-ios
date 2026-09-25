import Foundation

nonisolated enum UsageEventType: String, Codable, Sendable {
    case opened = "reader-opened", closed = "reader-closed"
    case started = "reading-started", stopped = "reading-stopped", page = "page-turned"
    case lookup = "word-looked-up", revealed = "bubble-revealed", translated = "bubble-translated"
    case copied = "bubble-copied", screenshot = "screenshot-translated"
}
nonisolated struct UsageEvent: Codable, Sendable {
    let at: Int64
    let utcOffset: String
    let type: UsageEventType
    var session: String?
    var bookId: String?
    var bookTitle: String?
    var contentType: String?
    var page: Int?
    var fromPage: Int?
    var toPage: Int?
    var chapter: Int?
    var character: Int?
    var startedAt: Int64?
    var text: String?
    var term: String?
    var source: String?
    var outcome: String?
    var date: Date { Date(timeIntervalSince1970: Double(at) / 1000) }
}

/// One serial writer for the whole process. Reads follow pending writes, and a torn final
/// JSON line is separated before appending so it cannot swallow the next valid event.
nonisolated final class UsageLog: @unchecked Sendable {
    static let shared = UsageLog()
    let directory: URL
    private let queue = DispatchQueue(label: "hoshi.usage-log", qos: .utility)
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("usage-log", isDirectory: true)
    }
    func append(_ event: UsageEvent) {
        queue.async { [self] in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var root = directory, values = URLResourceValues(); values.isExcludedFromBackup = true
                try root.setResourceValues(values)
                let file = directory.appendingPathComponent(MangaStatisticsTracker.dateKey(for: event.date) + ".ndjson")
                if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
                let handle = try FileHandle(forUpdating: file); defer { try? handle.close() }
                let size = try handle.seekToEnd()
                if size > 0 {
                    try handle.seek(toOffset: size - 1)
                    let last = try handle.read(upToCount: 1)
                    try handle.seekToEnd()
                    if last != Data([10]) { try handle.write(contentsOf: Data([10])) }
                }
                var data = try JSONEncoder().encode(event); data.append(10)
                try handle.write(contentsOf: data)
                NotificationCenter.default.post(name: .usageLogChanged, object: nil)
            } catch { /* Logging cannot interrupt reading. */ }
        }
    }
    func read(historyDays: Int = 92, now: Date = .now) async -> (events: [UsageEvent], firstDay: Date?) {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.pathExtension == "ndjson" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                let first = files.compactMap { StatisticsMath.date($0.deletingPathExtension().lastPathComponent) }.first
                let since = Calendar.current.date(byAdding: .day, value: -historyDays, to: now) ?? now
                var events: [UsageEvent] = []
                for file in files {
                    guard let date = StatisticsMath.date(file.deletingPathExtension().lastPathComponent), date >= Calendar.current.startOfDay(for: since),
                          let handle = try? FileHandle(forReadingFrom: file) else { continue }
                    defer { try? handle.close() }
                    var pending = Data()
                    while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                        pending.append(chunk)
                        while let end = pending.firstIndex(of: 10) {
                            if let event = try? JSONDecoder().decode(UsageEvent.self, from: pending[..<end]) { events.append(event) }
                            pending.removeSubrange(...end)
                        }
                        if pending.count > 1024 * 1024 { pending.removeAll() }
                    }
                }
                continuation.resume(returning: (events.sorted { $0.at < $1.at }, first))
            }
        }
    }
}

extension Notification.Name {
    nonisolated static let usageLogChanged = Notification.Name("usageLogChanged")
}

@MainActor final class ReaderUsageSession {
    let id = UUID().uuidString
    let book: BookMetadata
    private let log: UsageLog
    private let openedAt = Date()
    private var readingSince: Date?
    private var closed = false
    private var revealed: Set<String> = []
    init(book: BookMetadata, log: UsageLog = .shared) {
        self.book = book; self.log = log
        record(.opened)
    }
    func reading(_ active: Bool) {
        guard !closed else { return }
        if active {
            guard readingSince == nil else { return }; readingSince = .now; record(.started)
        } else {
            guard let since = readingSince else { return }; readingSince = nil; record(.stopped, startedAt: since)
        }
    }
    func close() {
        guard !closed else { return }
        reading(false); record(.closed, startedAt: openedAt); closed = true
    }
    func reveal(text: String, block: String?, page: Int) {
        if let block, !revealed.insert(block).inserted { return }
        record(.revealed, text: text, page: page)
    }
    func record(_ type: UsageEventType, text: String? = nil, term: String? = nil, source: String? = nil,
                found: Bool? = nil, page: Int? = nil, from: Int? = nil, to: Int? = nil,
                chapter: Int? = nil, character: Int? = nil, startedAt: Date? = nil, now: Date = .now) {
        guard !closed else { return }
        let offset = DateFormatter(); offset.dateFormat = "xxx"; offset.locale = Locale(identifier: "en_US_POSIX")
        log.append(UsageEvent(at: Int64(now.timeIntervalSince1970 * 1000), utcOffset: offset.string(from: now), type: type,
            session: id, bookId: book.id.uuidString, bookTitle: book.title,
            contentType: book.resolvedContentType == .mokuro ? "manga" : "epub", page: page, fromPage: from, toPage: to,
            chapter: chapter, character: character, startedAt: startedAt.map { Int64($0.timeIntervalSince1970 * 1000) },
            text: text.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500)) },
            term: term.map { String($0.prefix(500)) }, source: source, outcome: found.map { $0 ? "found" : "not-found" }))
    }
}
