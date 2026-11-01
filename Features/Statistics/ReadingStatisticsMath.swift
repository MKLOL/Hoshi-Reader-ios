import Foundation

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
        for incoming in entries where incoming.readingTime.isFinite && incoming.readingTime >= 0 && incoming.charactersRead >= 0 {
            let entry = incoming.withImportedResidual()
            if let old = result[entry.key] {
                if let merged = old.mergingImportedBaseline(entry) { result[entry.key] = merged; continue }
                if old.lastStatisticModified == entry.lastStatisticModified, let candidate = entry.importedBaseline {
                    if old.importedBaseline == nil { result[entry.key] = entry; continue }
                    let prior = old.importedBaseline!
                    if candidate.sourceModified != prior.sourceModified {
                        if candidate.sourceModified > prior.sourceModified { result[entry.key] = entry }
                        continue
                    }
                    if candidate.readingTime != prior.readingTime {
                        if candidate.readingTime > prior.readingTime { result[entry.key] = entry }
                        continue
                    }
                    if candidate.charactersRead != prior.charactersRead {
                        if candidate.charactersRead > prior.charactersRead { result[entry.key] = entry }
                        continue
                    }
                } else if old.lastStatisticModified == entry.lastStatisticModified, old.importedBaseline != nil { continue }
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

