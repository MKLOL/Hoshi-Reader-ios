import Foundation

nonisolated enum UsageEventType: String, Codable, Sendable {
    case opened = "reader-opened", closed = "reader-closed"
    case started = "reading-started", stopped = "reading-stopped", page = "page-turned"
    case lookup = "word-looked-up", revealed = "bubble-revealed", translated = "bubble-translated"
    case copied = "bubble-copied", screenshot = "screenshot-translated"
}
nonisolated struct UsageEvent: Codable, Sendable {
    let at: Int64
    let utcOffset: String?
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
    var timeZone: String?
    var startedTimeZone: String?
    var recordedZone: TimeZone { StatisticsZone.zone(timeZone) ?? instantZone }
    var instantZone: TimeZone { Self.instantZone(timeZone: timeZone, utcOffset: utcOffset) }
    static func instantZone(timeZone: String?, utcOffset: String?) -> TimeZone {
        StatisticsZone.zone(utcOffset) ?? StatisticsZone.zone(timeZone) ?? StatisticsZone.legacyZone
    }
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
                let file = directory.appendingPathComponent(ReaderDateFormatting.shared.dayKey(for: event.date, timeZone: event.instantZone) + ".ndjson")
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
    private static func validDevice(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 64 && id.contains { $0 != "." } && id.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45,46,95].contains($0) }
    }
    struct DayFile: Sendable {
        let day: String
        let file: URL
        let stamp: String
    }
    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var root = directory, values = URLResourceValues(); values.isExcludedFromBackup = true
        try root.setResourceValues(values)
    }
    func ownFiles() async throws -> [DayFile] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    guard FileManager.default.fileExists(atPath: directory.path) else { continuation.resume(returning: []); return }
                    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
                    let result = try files.filter { $0.pathExtension == "ndjson" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { file -> DayFile? in
                        let day = file.deletingPathExtension().lastPathComponent
                        guard ReadingDay.parse(day) != nil else { return nil }
                        let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                        return DayFile(day: day, file: file, stamp: "\(day):\(values.fileSize ?? 0):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)")
                    }
                    continuation.resume(returning: result)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func bytes(files: [DayFile]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    var result = Data()
                    for file in files {
                        let data = try Data(contentsOf: file.file)
                        guard result.count + data.count <= UsageGzip.expandedLimit else { throw HttpSyncError("Usage log exceeds the size limit") }
                        result.append(data)
                        if result.last != 10 { result.append(10) }
                    }
                    continuation.resume(returning: result)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func store(days: [String: Data], device: String?, mergeOwn: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    try prepareDirectory()
                    let folder: URL
                    if let device {
                        guard Self.validDevice(device) else { throw HttpSyncError("Invalid usage device ID") }
                        folder = directory.appendingPathComponent("devices").appendingPathComponent(device)
                    } else { folder = directory }
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    var changed = false
                    for (day, data) in days {
                        guard day.count == 10, ReadingDay.parse(day) != nil else { throw HttpSyncError("Invalid usage day") }
                        let file = folder.appendingPathComponent(day + ".ndjson")
                        let exists = FileManager.default.fileExists(atPath: file.path)
                        let old = exists ? try Data(contentsOf: file) : Data()
                        var next = data
                        if mergeOwn {
                            var known = Set(old.split(separator: 10).map(Data.init))
                            next = old
                            if !next.isEmpty && next.last != 10 { next.append(10) }
                            for line in data.split(separator: 10) where known.insert(Data(line)).inserted { next.append(contentsOf: line); next.append(10) }
                        }
                        if next != old { try next.write(to: file, options: .atomic); changed = true }
                    }
                    if changed { NotificationCenter.default.post(name: .usageLogChanged, object: nil) }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func clearDeviceDays() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    let folder = directory.appendingPathComponent("devices")
                    if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
                    NotificationCenter.default.post(name: .usageLogChanged, object: nil)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    /// A synchronized key and the day files it was unpacked into; `device` is nil for this device.
    struct CachedDays: Sendable {
        let key: String
        let days: [String]
        let device: String?
    }
    /// The keys whose day files are all still present, checked on the log's own queue.
    func complete(_ entries: [CachedDays]) async -> Set<String> {
        guard !entries.isEmpty else { return [] }
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: Set(entries.filter { entry in
                    entry.device.map { hasDeviceDays(entry.days, device: $0) } ?? hasOwnDays(entry.days)
                }.map(\.key)))
            }
        }
    }
    func hasOwnDays(_ days: [String]) -> Bool {
        days.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0 + ".ndjson").path) }
    }
    func hasDeviceDays(_ days: [String], device: String) -> Bool {
        days.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent("devices").appendingPathComponent(device).appendingPathComponent($0 + ".ndjson").path) }
    }
    func read(historyDays: Int = 92, now: Date = .now, resetHour: Int = 0) async -> (events: [UsageEvent], firstDayKey: String?) {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                var folders: [(URL, String)] = [(directory, "local")]
                let devices = directory.appendingPathComponent("devices")
                for folder in (try? FileManager.default.contentsOfDirectory(at: devices, includingPropertiesForKeys: nil)) ?? [] where Self.validDevice(folder.lastPathComponent) {
                    folders.append((folder, "device:" + folder.lastPathComponent))
                }
                // Adjacent files can contain overnight spans or pre-update events saved after a zone change.
                let since = StatisticsZone.calendar.date(byAdding: .day, value: -(historyDays + 4), to: now) ?? now
                let sinceKey = ReadingDay.key(since)
                var events: [UsageEvent] = [], firstDayKey: String?
                for (folder, namespace) in folders {
                    let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "ndjson" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                    for (index, file) in files.enumerated() {
                        guard file.deletingPathExtension().lastPathComponent >= sinceKey || index < 3, let handle = try? FileHandle(forReadingFrom: file) else { continue }
                        defer { try? handle.close() }
                        var pending = Data()
                        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                            pending.append(chunk)
                            while let end = pending.firstIndex(of: 10) {
                                if var event = try? JSONDecoder().decode(UsageEvent.self, from: pending[..<end]) {
                                    if index < 3 {
                                        let calendar = StatisticsZone.calendar(zone: event.instantZone)
                                        let localDay = ReadingDay.date(at: event.date, resetHour: resetHour, calendar: calendar)
                                        let key = ReaderDateFormatting.shared.dayKey(for: localDay, timeZone: event.instantZone)
                                        firstDayKey = min(firstDayKey ?? key, key)
                                    }
                                    if event.date >= since {
                                        event.session = namespace + "|" + (event.session ?? "")
                                        events.append(event)
                                    }
                                }
                                pending.removeSubrange(...end)
                            }
                            if pending.count > 1024 * 1024 { pending.removeAll() }
                        }
                    }
                }
                continuation.resume(returning: (events.sorted { $0.at == $1.at ? ($0.session ?? "") < ($1.session ?? "") : $0.at < $1.at }, firstDayKey))
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
    private var readingStart: (date: Date, zone: TimeZone)?
    private var closed = false
    private var revealed: Set<String> = []
    init(book: BookMetadata, log: UsageLog = .shared) {
        self.book = book; self.log = log
        record(.opened)
    }
    func reading(_ active: Bool) {
        guard !closed else { return }
        if active {
            guard readingStart == nil else { return }
            let now = Date(), zone = TimeZone.current
            readingStart = (now, zone)
            record(.started, now: now, timeZone: zone)
        } else {
            guard let start = readingStart else { return }
            readingStart = nil
            record(.stopped, startedAt: start.date, startedTimeZone: start.zone.identifier)
        }
    }
    func close() {
        guard !closed else { return }
        reading(false); record(.closed, startedAt: openedAt); closed = true
    }
    func reveal(text: String, block: String?, page: Int) {
        if let block, !block.isEmpty, !revealed.insert(block).inserted { return }
        record(.revealed, text: text, page: page)
    }
    func record(_ type: UsageEventType, text: String? = nil, term: String? = nil, source: String? = nil,
                found: Bool? = nil, page: Int? = nil, from: Int? = nil, to: Int? = nil,
                chapter: Int? = nil, character: Int? = nil, startedAt: Date? = nil, now: Date = .now,
                timeZone: TimeZone = .current, startedTimeZone: String? = nil) {
        guard !closed else { return }
        if type != .started, type != .stopped, let start = readingStart, now > start.date, start.zone != timeZone {
            // The first event observed on the new clock closes the old span.
            readingStart = (now, timeZone)
            record(.stopped, startedAt: start.date, now: now, timeZone: start.zone, startedTimeZone: start.zone.identifier)
            record(.started, now: now, timeZone: timeZone)
        }
        log.append(UsageEvent(at: Int64(now.timeIntervalSince1970 * 1000), utcOffset: ReaderDateFormatting.utcOffset(for: now, timeZone: timeZone), type: type,
            session: id, bookId: book.id.uuidString, bookTitle: book.title,
            contentType: book.resolvedContentType == .mokuro ? "manga" : "epub", page: page, fromPage: from, toPage: to,
            chapter: chapter, character: character, startedAt: startedAt.map { Int64($0.timeIntervalSince1970 * 1000) },
            text: text.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500)) },
            term: term.map { String($0.prefix(500)) }, source: source, outcome: found.map { $0 ? "found" : "not-found" },
            timeZone: timeZone.identifier, startedTimeZone: startedTimeZone))
    }
}
