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

    /// Duration's floating-point initializer traps outside its representable range. Imported
    /// totals and pace estimates can be much larger than any real session, but still valid JSON.
    static func safeDuration(_ seconds: Double) -> Duration {
        guard !seconds.isNaN, seconds > 0 else { return .zero }
        guard seconds.isFinite, seconds < Double(Int.max) else { return .seconds(Int.max) }
        return .seconds(seconds)
    }
    static func formattedDuration(_ seconds: Double) -> String { safeDuration(seconds).formatted() }

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
            guard let old = result[entry.key] else { result[entry.key] = entry; continue }
            var winner = preferred(old, entry)
            // Samples are append-only per origin, independently of the scalar timestamp. A
            // same-day restore or older client can send a newer row missing earlier samples.
            // Maxima retain that evidence; summing snapshots would count every retry twice.
            winner.mangaPageSeconds = old.mangaPageSeconds.merging(entry.mangaPageSeconds, uniquingKeysWith: max)
            result[entry.key] = winner
        }
        return result.values.sorted { $0.key < $1.key }
    }
    private static func preferred(_ old: Statistics, _ entry: Statistics) -> Statistics {
        if let merged = old.mergingImportedBaseline(entry) { return merged }
        if old.lastStatisticModified == entry.lastStatisticModified, let candidate = entry.importedBaseline {
            guard let prior = old.importedBaseline else { return entry }
            if candidate.sourceModified != prior.sourceModified { return candidate.sourceModified > prior.sourceModified ? entry : old }
            if candidate.readingTime != prior.readingTime { return candidate.readingTime > prior.readingTime ? entry : old }
            if candidate.charactersRead != prior.charactersRead { return candidate.charactersRead > prior.charactersRead ? entry : old }
        } else if old.lastStatisticModified == entry.lastStatisticModified, old.importedBaseline != nil { return old }
        if old.lastStatisticModified > entry.lastStatisticModified { return old }
        if old.lastStatisticModified == entry.lastStatisticModified {
            // Old clients strip unknown fields. Otherwise-identical rows keep the richer
            // hourly evidence, so an equal-stamp merge cannot turn an exact day into a guess.
            if old.tieBreak == entry.tieBreak {
                if old.readingTimeByHour == entry.readingTimeByHour, old.readingTimeByZone != entry.readingTimeByZone {
                    if old.readingTimeByZone.isEmpty { return entry }
                    if entry.readingTimeByZone.isEmpty { return old }
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                    let left = (try? encoder.encode(old.readingTimeByZone)) ?? Data()
                    let right = (try? encoder.encode(entry.readingTimeByZone)) ?? Data()
                    return left.lexicographicallyPrecedes(right) ? entry : old
                }
                if old.readingTimeByHour == entry.readingTimeByHour && old.timeZone != nil && entry.timeZone == nil { return old }
                if old.readingTimeByHour == entry.readingTimeByHour && old.timeZone == nil && entry.timeZone != nil { return entry }
                // Android orders equal stamps by the full row text, where the zone follows the hours.
                if old.readingTimeByHour == entry.readingTimeByHour, let oldZone = old.timeZone, let newZone = entry.timeZone, oldZone != newZone {
                    return (newZone + ",").utf16.lexicographicallyPrecedes((oldZone + ",").utf16) ? old : entry
                }
                let oldHours = old.readingTimeByHour.values.filter { $0.isFinite && $0 > 0 }.reduce(0.0, StatisticsNumbers.adding)
                let newHours = entry.readingTimeByHour.values.filter { $0.isFinite && $0 > 0 }.reduce(0.0, StatisticsNumbers.adding)
                let oldKeys = old.readingTimeByHour.keys.sorted().map { "\($0)=\(old.readingTimeByHour[$0]!)" }.joined(separator: ",")
                let newKeys = entry.readingTimeByHour.keys.sorted().map { "\($0)=\(entry.readingTimeByHour[$0]!)" }.joined(separator: ",")
                if oldHours > newHours || (oldHours == newHours && !oldKeys.utf16.lexicographicallyPrecedes(newKeys.utf16)) { return old }
            } else if !old.tieBreak.utf16.lexicographicallyPrecedes(entry.tieBreak.utf16) { return old }
        }
        return entry
    }
    /// Adds disjoint page samples (different days/devices, or one newly completed page).
    static func sumPageSeconds(_ histograms: [[Int: Int]]) -> [Int: Int] {
        var result: [Int: Int] = [:]
        for histogram in histograms {
            for (seconds, count) in histogram where seconds > 0 && count > 0 {
                result[seconds] = StatisticsNumbers.adding(result[seconds] ?? 0, count)
            }
        }
        return result
    }
    /// Weighted median of completed page durations, averaging both middle pages for even counts.
    var medianPageSeconds: Double? {
        let samples = mangaPageSeconds.filter { $0.key > 0 && $0.value > 0 }.sorted { $0.key < $1.key }
        guard !samples.isEmpty else { return nil }
        // Removing the same number of pages from both ends preserves the middle. No total
        // occurrence count is needed, so even several Int.max buckets retain their exact weight.
        var lower = 0, upper = samples.count - 1
        var lowCount = samples[lower].value, highCount = samples[upper].value
        while lower < upper {
            if lowCount == highCount {
                if lower + 1 == upper { return (Double(samples[lower].key) + Double(samples[upper].key)) / 2 }
                lower += 1; upper -= 1
                lowCount = samples[lower].value; highCount = samples[upper].value
            } else if lowCount < highCount {
                highCount -= lowCount; lower += 1; lowCount = samples[lower].value
            } else {
                lowCount -= highCount; upper -= 1; highCount = samples[upper].value
            }
        }
        return Double(samples[lower].key)
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

