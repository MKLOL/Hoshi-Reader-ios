import Foundation
import UIKit

nonisolated struct ReadingDevice: Codable, Equatable, Sendable {
    let id: String
    let name: String

    @MainActor static var current: ReadingDevice {
        resolve(defaults: .standard, vendorID: UIDevice.current.identifierForVendor?.uuidString, name: UIDevice.current.name)
    }

    @MainActor static func resolve(defaults: UserDefaults, vendorID: String?, name: String) -> ReadingDevice {
        let previousVendor = defaults.string(forKey: "statistics.deviceVendorId")
        // System backups can copy defaults onto another phone. Keep this install's UUID across
        // upgrades, but give a different physical device its own statistics bucket after restore.
        let changedDevice = vendorID != nil && previousVendor != nil && vendorID != previousVendor
        let id = changedDevice ? UUID().uuidString.lowercased() : defaults.string(forKey: "statistics.deviceId") ?? UUID().uuidString.lowercased()
        if defaults.string(forKey: "statistics.deviceId") != id { defaults.set(id, forKey: "statistics.deviceId") }
        if let vendorID, previousVendor != vendorID { defaults.set(vendorID, forKey: "statistics.deviceVendorId") }
        return ReadingDevice(id: id, name: name)
    }
}

nonisolated struct MangaTextStatistic: Codable, Equatable, Sendable {
    var dateKey: String
    var charactersRead: Int = 0
    var lastModified: Int = 0
    var deviceId: String?
    var deviceName: String?
    var key: String { dateKey + "|" + (deviceId ?? "") }
}

nonisolated extension MangaTextStatistic {
    var tieBreak: String {
        "MangaTextStatistic(dateKey=\(dateKey), charactersRead=\(charactersRead), lastModified=\(lastModified), deviceId=\(deviceId ?? "null"), deviceName=\(deviceName ?? "null"))"
    }
    static func merged(_ entries: [Self]) -> [Self] {
        var result: [String: Self] = [:]
        for entry in entries where entry.charactersRead >= 0 {
            if let old = result[entry.key], old.lastModified > entry.lastModified ||
                (old.lastModified == entry.lastModified && !old.tieBreak.utf16.lexicographicallyPrecedes(entry.tieBreak.utf16)) { continue }
            result[entry.key] = entry
        }
        return result.values.sorted { $0.key < $1.key }
    }
}

extension Notification.Name {
    static let readingStatisticsChanged = Notification.Name("readingStatisticsChanged")
}

@MainActor enum ReadingStatisticsStore {
    private static let migration = ".statistics_devices_v2"

    /// Old iOS manga_statistics.json held page/time rows. Preserve those in statistics.json
    /// before reusing the Android-compatible manga sidecar for OCR character counts.
    static func migrate(root: URL) throws {
        let marker = root.appendingPathComponent(migration)
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        let device = ReadingDevice.current
        var reading = try strictReading(root: root)
        if let legacy = BookStorage.load([Statistics].self, from: root.appendingPathComponent(FileNames.mangaStatistics)), !legacy.isEmpty {
            reading += legacy
            // Keep a recovery copy until the whole migration has committed.
            try BookStorage.save(legacy, inside: root, as: ".legacy_manga_statistics.json")
        }
        let exchanged = [HttpReadingStatisticsSync.stateFile, ".http_sync_statistics.json"].contains {
            FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
        }
        // A mixed/device-aware file already contains shared history. Its unknown-device bucket
        // must keep that identity or the next HTTP merge would count the same history twice.
        let attributeReading = !exchanged && !reading.contains { $0.deviceId != nil }
        reading = reading.map { row in
            var copy = row
            if attributeReading && copy.deviceId == nil { copy.deviceId = device.id; copy.deviceName = device.name }
            return copy
        }
        let textFile = root.appendingPathComponent(FileNames.mangaStatistics)
        let originalText: [MangaTextStatistic]
        if FileManager.default.fileExists(atPath: textFile.path), BookStorage.load([Statistics].self, from: textFile) == nil {
            originalText = try strictText(root: root)
        } else { originalText = [] }
        let attributeText = !exchanged && !originalText.contains { $0.deviceId != nil }
        let text = originalText.map { row in
            var copy = row
            if attributeText && copy.deviceId == nil { copy.deviceId = device.id; copy.deviceName = device.name }
            return copy
        }
        try BookStorage.save(Statistics.merged(reading), inside: root, as: FileNames.statistics)
        if ContentType.detect(bookDir: root) == .mokuro {
            try BookStorage.save(MangaTextStatistic.merged(text), inside: root, as: FileNames.mangaStatistics)
        }
        try Data().write(to: marker, options: .atomic)
    }

    static func strictReading(root: URL) throws -> [Statistics] {
        let file = root.appendingPathComponent(FileNames.statistics)
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return Statistics.merged(try JSONDecoder().decode([Statistics].self, from: Data(contentsOf: file)))
    }
    static func strictText(root: URL) throws -> [MangaTextStatistic] {
        let file = root.appendingPathComponent(FileNames.mangaStatistics)
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return MangaTextStatistic.merged(try JSONDecoder().decode([MangaTextStatistic].self, from: Data(contentsOf: file)))
    }
    static func contentType(root: URL) -> ContentType {
        StatisticsHistory.info(root)?.contentType ?? (FileManager.default.fileExists(atPath: root.appendingPathComponent(FileNames.mangaStatistics).path) && StatisticsHistory.info(root) != nil ? .mokuro : ContentType.detect(bookDir: root))
    }
    static func reading(root: URL) -> [Statistics] {
        try? StatisticsHistory.absorbIfPresent(root: root)
        try? migrate(root: root)
        return Statistics.merged(BookStorage.load([Statistics].self, from: root.appendingPathComponent(FileNames.statistics)) ?? [])
    }
    static func text(root: URL) -> [MangaTextStatistic] {
        try? StatisticsHistory.absorbIfPresent(root: root)
        try? migrate(root: root)
        return MangaTextStatistic.merged(BookStorage.load([MangaTextStatistic].self, from: root.appendingPathComponent(FileNames.mangaStatistics)) ?? [])
    }
    static func save(_ rows: [Statistics], root: URL, scheduleSync: Bool = true) throws {
        try migrate(root: root)
        try StatisticsHistory.absorbIfPresent(root: root)
        let merged = Statistics.merged(try preserveUnreadable(root: root, filename: FileNames.statistics, load: { try strictReading(root: root) }) + rows)
        try BookStorage.save(merged, inside: root, as: FileNames.statistics)
        changed(root: root, scheduleSync: scheduleSync)
    }
    static func saveText(_ rows: [MangaTextStatistic], root: URL, scheduleSync: Bool = true) throws {
        try migrate(root: root)
        try StatisticsHistory.absorbIfPresent(root: root)
        let existing = try preserveUnreadable(root: root, filename: FileNames.mangaStatistics, load: { try strictText(root: root) })
        try BookStorage.save(MangaTextStatistic.merged(existing + rows), inside: root, as: FileNames.mangaStatistics)
        changed(root: root, scheduleSync: scheduleSync)
    }
    private static func preserveUnreadable<T>(root: URL, filename: String, load: () throws -> [T]) throws -> [T] {
        do { return try load() }
        catch is DecodingError {
            let recovery = try BookStorage.getBooksDirectory().appendingPathComponent(".unreadable")
            try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: root.appendingPathComponent(filename), to: recovery.appendingPathComponent(filename + "." + UUID().uuidString))
            return []
        }
    }
    static func collapsed(_ rows: [Statistics]) -> [Statistics] {
        Dictionary(grouping: Statistics.merged(rows), by: \.dateKey).map { day, entries in
            Statistics.total(entries, title: entries.first?.title ?? "", day: day)
        }.sorted { $0.dateKey < $1.dateKey }
    }

    static func applyDayTotals(_ totals: [Statistics], root: URL, replace: Bool) throws {
        try migrate(root: root)
        try StatisticsHistory.absorbIfPresent(root: root)
        let original = try preserveUnreadable(root: root, filename: FileNames.statistics, load: { try strictReading(root: root) })
        let next = ImportedReadingTotals.applying(totals, to: original, replace: replace)
        guard next != original else { return }
        try BookStorage.save(next, inside: root, as: FileNames.statistics)
        changed(root: root, scheduleSync: true)
    }

    private static func changed(root: URL, scheduleSync: Bool) {
        NotificationCenter.default.post(name: .readingStatisticsChanged, object: root)
        if scheduleSync { HttpReadingStatisticsSync.shared.schedule(root: root) }
    }
}
