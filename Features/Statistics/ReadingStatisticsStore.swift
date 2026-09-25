import Foundation
import UIKit

nonisolated struct ReadingDevice: Codable, Equatable, Sendable {
    let id: String
    let name: String

    @MainActor static var current: ReadingDevice {
        let defaults = UserDefaults.standard
        let id = defaults.string(forKey: "statistics.deviceId") ?? UUID().uuidString.lowercased()
        defaults.set(id, forKey: "statistics.deviceId")
        return ReadingDevice(id: id, name: UIDevice.current.name)
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

nonisolated extension Statistics {
    var key: String { dateKey + "|" + (deviceId ?? "") }
    static func empty(title: String, day: String, device: ReadingDevice? = nil) -> Statistics {
        Statistics(title: title, dateKey: day, charactersRead: 0, readingTime: 0,
                   minReadingSpeed: 0, altMinReadingSpeed: 0, lastReadingSpeed: 0,
                   maxReadingSpeed: 0, lastStatisticModified: 0, deviceId: device?.id, deviceName: device?.name)
    }
    mutating func add(seconds: Double, count: Int, stamp: Int) {
        readingTime += max(0, seconds)
        charactersRead = max(0, charactersRead + count)
        lastReadingSpeed = readingTime > 0 ? Int(Double(charactersRead) / readingTime * 3600) : 0
        maxReadingSpeed = max(maxReadingSpeed, lastReadingSpeed)
        minReadingSpeed = minReadingSpeed == 0 ? lastReadingSpeed : min(minReadingSpeed, lastReadingSpeed)
        if count != 0 { altMinReadingSpeed = altMinReadingSpeed == 0 ? lastReadingSpeed : min(altMinReadingSpeed, lastReadingSpeed) }
        lastStatisticModified = max(stamp, lastStatisticModified + 1)
    }
    // Same tie-break text as Android's ReadingStatistics data class.
    var tieBreak: String {
        "ReadingStatistics(title=\(title), dateKey=\(dateKey), charactersRead=\(charactersRead), readingTime=\(readingTime), minReadingSpeed=\(minReadingSpeed), altMinReadingSpeed=\(altMinReadingSpeed), lastReadingSpeed=\(lastReadingSpeed), maxReadingSpeed=\(maxReadingSpeed), lastStatisticModified=\(lastStatisticModified), deviceId=\(deviceId ?? "null"), deviceName=\(deviceName ?? "null"))"
    }
    static func merged(_ entries: [Statistics]) -> [Statistics] {
        var result: [String: Statistics] = [:]
        for entry in entries where entry.readingTime.isFinite && entry.readingTime >= 0 && entry.charactersRead >= 0 {
            if let old = result[entry.key], old.lastStatisticModified > entry.lastStatisticModified ||
                (old.lastStatisticModified == entry.lastStatisticModified && old.tieBreak >= entry.tieBreak) { continue }
            result[entry.key] = entry
        }
        return result.values.sorted { $0.key < $1.key }
    }
    static func total(_ entries: [Statistics], title: String = "", day: String = "") -> Statistics {
        var total = empty(title: title, day: day)
        for entry in merged(entries) {
            total.readingTime += entry.readingTime
            total.charactersRead += entry.charactersRead
            total.lastStatisticModified = max(total.lastStatisticModified, entry.lastStatisticModified)
        }
        total.lastReadingSpeed = total.readingTime > 0 ? Int(Double(total.charactersRead) / total.readingTime * 3600) : 0
        return total
    }
}

nonisolated extension MangaTextStatistic {
    var tieBreak: String {
        "MangaTextStatistic(dateKey=\(dateKey), charactersRead=\(charactersRead), lastModified=\(lastModified), deviceId=\(deviceId ?? "null"), deviceName=\(deviceName ?? "null"))"
    }
    static func merged(_ entries: [Self]) -> [Self] {
        var result: [String: Self] = [:]
        for entry in entries where entry.charactersRead >= 0 {
            if let old = result[entry.key], old.lastModified > entry.lastModified ||
                (old.lastModified == entry.lastModified && old.tieBreak >= entry.tieBreak) { continue }
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
        var reading = BookStorage.load([Statistics].self, from: root.appendingPathComponent(FileNames.statistics)) ?? []
        if let legacy = BookStorage.load([Statistics].self, from: root.appendingPathComponent(FileNames.mangaStatistics)), !legacy.isEmpty {
            reading += legacy
            // Keep a recovery copy until the whole migration has committed.
            try BookStorage.save(legacy, inside: root, as: ".legacy_manga_statistics.json")
        }
        reading = reading.map { row in
            var copy = row
            if copy.deviceId == nil { copy.deviceId = device.id; copy.deviceName = device.name }
            return copy
        }
        let text = (BookStorage.load([MangaTextStatistic].self, from: root.appendingPathComponent(FileNames.mangaStatistics)) ?? []).map { row in
            var copy = row
            if copy.deviceId == nil { copy.deviceId = device.id; copy.deviceName = device.name }
            return copy
        }
        try BookStorage.save(Statistics.merged(reading), inside: root, as: FileNames.statistics)
        if ContentType.detect(bookDir: root) == .mokuro {
            try BookStorage.save(MangaTextStatistic.merged(text), inside: root, as: FileNames.mangaStatistics)
        }
        try Data().write(to: marker, options: .atomic)
    }

    static func reading(root: URL) -> [Statistics] {
        try? migrate(root: root)
        return Statistics.merged(BookStorage.load([Statistics].self, from: root.appendingPathComponent(FileNames.statistics)) ?? [])
    }
    static func text(root: URL) -> [MangaTextStatistic] {
        try? migrate(root: root)
        return MangaTextStatistic.merged(BookStorage.load([MangaTextStatistic].self, from: root.appendingPathComponent(FileNames.mangaStatistics)) ?? [])
    }
    static func save(_ rows: [Statistics], root: URL, scheduleSync: Bool = true) throws {
        let merged = Statistics.merged(reading(root: root) + rows)
        try BookStorage.save(merged, inside: root, as: FileNames.statistics)
        changed(root: root, scheduleSync: scheduleSync)
    }
    static func saveText(_ rows: [MangaTextStatistic], root: URL, scheduleSync: Bool = true) throws {
        try BookStorage.save(MangaTextStatistic.merged(text(root: root) + rows), inside: root, as: FileNames.mangaStatistics)
        changed(root: root, scheduleSync: scheduleSync)
    }
    static func collapsed(_ rows: [Statistics]) -> [Statistics] {
        Dictionary(grouping: Statistics.merged(rows), by: \.dateKey).map { day, entries in
            Statistics.total(entries, title: entries.first?.title ?? "", day: day)
        }.sorted { $0.dateKey < $1.dateKey }
    }

    static func applyDayTotals(_ totals: [Statistics], root: URL, replace: Bool) throws {
        let device = ReadingDevice.current
        var next = reading(root: root)
        for total in collapsed(totals) {
            let others = next.filter { $0.dateKey == total.dateKey && $0.deviceId != device.id }
            let own = next.first { $0.dateKey == total.dateKey && $0.deviceId == device.id }
            let time = max(0, total.readingTime - others.reduce(0) { $0 + $1.readingTime })
            let count = max(0, total.charactersRead - others.reduce(0) { $0 + $1.charactersRead })
            if own?.readingTime == time && own?.charactersRead == count { continue }
            var row = total
            row.readingTime = time; row.charactersRead = count
            row.lastReadingSpeed = time > 0 ? Int(Double(count) / time * 3600) : 0
            row.deviceId = device.id; row.deviceName = device.name
            row.lastStatisticModified = max(total.lastStatisticModified, (own?.lastStatisticModified ?? 0) + 1)
            next.removeAll { $0.key == row.key }; next.append(row)
        }
        if replace {
            let keep = Set(totals.map(\.dateKey))
            next.removeAll { $0.deviceId == device.id && !keep.contains($0.dateKey) }
        }
        try BookStorage.save(Statistics.merged(next), inside: root, as: FileNames.statistics)
        changed(root: root, scheduleSync: true)
    }

    private static func changed(root: URL, scheduleSync: Bool) {
        NotificationCenter.default.post(name: .readingStatisticsChanged, object: root)
        if scheduleSync { HttpReadingStatisticsSync.shared.schedule(root: root) }
    }
}
