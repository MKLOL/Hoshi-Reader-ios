import Foundation
import UIKit

/// Imported statistics must never make arithmetic or a floating-point conversion trap.
nonisolated enum StatisticsNumbers {
    static func adding(_ lhs: Int, _ rhs: Int) -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? (rhs >= 0 ? .max : .min) : value
    }
    static func adding(_ lhs: Double, _ rhs: Double) -> Double {
        min(Double.greatestFiniteMagnitude, max(0, lhs) + max(0, rhs))
    }
    static func integer(_ value: Double) -> Int {
        guard !value.isNaN, value > 0 else { return 0 }
        return value >= Double(Int.max) ? .max : Int(value)
    }
    static func speed(count: Int, seconds: Double) -> Int {
        seconds > 0 ? integer(Double(count) / seconds * 3600) : 0
    }
    static func nextStamp(_ stamp: Int) -> Int { adding(stamp, 1) }

    /// Kotlin's data-class tie-break uses Double.toString: shortest decimal digits, scientific
    /// notation below 1e-3 or at/above 1e7, uppercase E and a mandatory fractional digit. Swift
    /// already supplies the shortest digits; only their decimal placement/notation differs.
    static func kotlinDoubleText(_ value: Double) -> String {
        let raw = String(value)
        let magnitude = abs(value)
        guard value.isFinite, magnitude > 0, magnitude < 0.001 || magnitude >= 10_000_000 else { return raw }
        let negative = raw.hasPrefix("-")
        let unsigned = negative ? String(raw.dropFirst()) : raw
        let components = unsigned.lowercased().split(separator: "e")
        let mantissa = components[0].split(separator: ".", omittingEmptySubsequences: false)
        var digits = mantissa.joined()
        var decimalPosition = mantissa[0].count + (components.count > 1 ? Int(components[1]) ?? 0 : 0)
        while digits.first == "0", digits.count > 1 { digits.removeFirst(); decimalPosition -= 1 }
        while digits.last == "0", digits.count > 1 { digits.removeLast() }
        let leading = digits.removeFirst()
        return (negative ? "-" : "") + String(leading) + "." + (digits.isEmpty ? "0" : digits) + "E" + String(decimalPosition - 1)
    }
}

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

nonisolated extension Statistics {
    var key: String { dateKey + "|" + (deviceId ?? "") }
    static func empty(title: String, day: String, device: ReadingDevice? = nil) -> Statistics {
        Statistics(title: title, dateKey: day, charactersRead: 0, readingTime: 0,
                   minReadingSpeed: 0, altMinReadingSpeed: 0, lastReadingSpeed: 0,
                   maxReadingSpeed: 0, lastStatisticModified: 0, deviceId: device?.id, deviceName: device?.name)
    }
    mutating func add(seconds: Double, count: Int, stamp: Int) {
        readingTime = StatisticsNumbers.adding(readingTime, seconds)
        charactersRead = max(0, StatisticsNumbers.adding(charactersRead, count))
        lastReadingSpeed = StatisticsNumbers.speed(count: charactersRead, seconds: readingTime)
        maxReadingSpeed = max(maxReadingSpeed, lastReadingSpeed)
        minReadingSpeed = minReadingSpeed == 0 ? lastReadingSpeed : min(minReadingSpeed, lastReadingSpeed)
        if count != 0 { altMinReadingSpeed = altMinReadingSpeed == 0 ? lastReadingSpeed : min(altMinReadingSpeed, lastReadingSpeed) }
        lastStatisticModified = max(stamp, StatisticsNumbers.nextStamp(lastStatisticModified))
    }
    // Same tie-break text as Android's ReadingStatistics data class.
    var tieBreak: String {
        "ReadingStatistics(title=\(title), dateKey=\(dateKey), charactersRead=\(charactersRead), readingTime=\(StatisticsNumbers.kotlinDoubleText(readingTime)), minReadingSpeed=\(minReadingSpeed), altMinReadingSpeed=\(altMinReadingSpeed), lastReadingSpeed=\(lastReadingSpeed), maxReadingSpeed=\(maxReadingSpeed), lastStatisticModified=\(lastStatisticModified), deviceId=\(deviceId ?? "null"), deviceName=\(deviceName ?? "null"))"
    }
    static func merged(_ entries: [Statistics]) -> [Statistics] {
        var result: [String: Statistics] = [:]
        for entry in entries where entry.readingTime.isFinite && entry.readingTime >= 0 && entry.charactersRead >= 0 {
            if let old = result[entry.key] {
                if old.lastStatisticModified > entry.lastStatisticModified { continue }
                if old.lastStatisticModified == entry.lastStatisticModified {
                    // Old clients strip unknown fields. Otherwise-identical rows keep the richer
                    // hourly evidence, so an equal-stamp merge cannot turn an exact day into a guess.
                    if old.tieBreak == entry.tieBreak {
                        if old.readingTimeByHour == entry.readingTimeByHour && old.timeZone != nil && entry.timeZone == nil { continue }
                        if old.readingTimeByHour == entry.readingTimeByHour && old.timeZone == nil && entry.timeZone != nil { result[entry.key] = entry; continue }
                        let oldHours = old.readingTimeByHour.values.filter { $0.isFinite && $0 > 0 }.reduce(0.0, StatisticsNumbers.adding)
                        let newHours = entry.readingTimeByHour.values.filter { $0.isFinite && $0 > 0 }.reduce(0.0, StatisticsNumbers.adding)
                        let oldKeys = old.readingTimeByHour.keys.sorted().map { "\($0)=\(old.readingTimeByHour[$0]!)" }.joined(separator: ",")
                        let newKeys = entry.readingTimeByHour.keys.sorted().map { "\($0)=\(entry.readingTimeByHour[$0]!)" }.joined(separator: ",")
                        if oldHours > newHours || (oldHours == newHours && !oldKeys.utf16.lexicographicallyPrecedes(newKeys.utf16)) { continue }
                    } else if !old.tieBreak.utf16.lexicographicallyPrecedes(entry.tieBreak.utf16) { continue }
                }
            }
            result[entry.key] = entry
        }
        return result.values.sorted { $0.key < $1.key }
    }
    static func total(_ entries: [Statistics], title: String = "", day: String = "") -> Statistics {
        var total = empty(title: title, day: day)
        for entry in merged(entries) {
            total.readingTime = StatisticsNumbers.adding(total.readingTime, entry.readingTime)
            total.readingTimeByHour = ReadingDay.sumHours([total.readingTimeByHour, entry.readingTimeByHour])
            total.charactersRead = StatisticsNumbers.adding(total.charactersRead, entry.charactersRead)
            total.lastStatisticModified = max(total.lastStatisticModified, entry.lastStatisticModified)
            if entry.minReadingSpeed > 0 { total.minReadingSpeed = total.minReadingSpeed == 0 ? entry.minReadingSpeed : min(total.minReadingSpeed, entry.minReadingSpeed) }
            if entry.altMinReadingSpeed > 0 { total.altMinReadingSpeed = total.altMinReadingSpeed == 0 ? entry.altMinReadingSpeed : min(total.altMinReadingSpeed, entry.altMinReadingSpeed) }
            total.maxReadingSpeed = max(total.maxReadingSpeed, entry.maxReadingSpeed)
        }
        let zones = Set(merged(entries).map(\.timeZone))
        total.timeZone = zones.count == 1 ? zones.first! : nil
        total.lastReadingSpeed = StatisticsNumbers.speed(count: total.charactersRead, seconds: total.readingTime)
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
        let device = ReadingDevice.current
        try migrate(root: root)
        try StatisticsHistory.absorbIfPresent(root: root)
        var next = try preserveUnreadable(root: root, filename: FileNames.statistics, load: { try strictReading(root: root) })
        for total in collapsed(totals) {
            let others = next.filter { $0.dateKey == total.dateKey && $0.deviceId != device.id }
            let own = next.first { $0.dateKey == total.dateKey && $0.deviceId == device.id }
            let otherTotals = Statistics.total(others)
            let time = max(0, total.readingTime - otherTotals.readingTime)
            let count = max(0, total.charactersRead - otherTotals.charactersRead)
            if own == nil && time == 0 && count == 0 { continue }
            if own?.readingTime == time && own?.charactersRead == count { continue }
            var row = total
            row.readingTime = time; row.charactersRead = count
            let hoursFromTotal = !total.readingTimeByHour.isEmpty && others.allSatisfy({ abs($0.readingTime - $0.readingTimeByHour.values.reduce(0, +)) < 0.001 })
            if hoursFromTotal {
                row.readingTimeByHour = total.readingTimeByHour.mapValues { $0 }
                for (hour, seconds) in otherTotals.readingTimeByHour {
                    row.readingTimeByHour[hour] = max(0, (row.readingTimeByHour[hour] ?? 0) - seconds)
                }
            } else { row.readingTimeByHour = own?.readingTimeByHour ?? [:] }
            if row.readingTimeByHour.values.reduce(0, +) > time + 0.001 { row.readingTimeByHour = [:] }
            row.readingTimeByHour = row.readingTimeByHour.filter { $0.value > 0 }
            row.timeZone = row.readingTimeByHour.isEmpty ? nil : ((hoursFromTotal ? total.timeZone : nil) ?? own?.timeZone ?? own?.recordedZone(target: .current)?.identifier ?? TimeZone.current.identifier)
            row.lastReadingSpeed = StatisticsNumbers.speed(count: count, seconds: time)
            row.deviceId = device.id; row.deviceName = device.name
            row.lastStatisticModified = max(total.lastStatisticModified, StatisticsNumbers.nextStamp(own?.lastStatisticModified ?? 0))
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
