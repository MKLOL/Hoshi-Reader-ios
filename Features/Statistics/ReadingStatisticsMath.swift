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
    // Legacy per-book HTTP sidecars order equal timestamps by the Android record text.
    var tieBreak: String { legacyRecordText() }

    func legacyRecordText(hourOrder: [String]? = nil) -> String {
        let hours = hourOrder.map { order in
            legacyMap(order.compactMap { key in readingTimeByHour[key].map { (key, $0) } }, value: StatisticsNumbers.kotlinDoubleText)
        } ?? legacyHours(readingTimeByHour)
        let histogram = legacyMap(mangaPageSeconds.sorted { $0.key < $1.key }, value: String.init)
        let zones = legacyMap(legacySorted(readingTimeByZone), value: legacyHours)
        let baseline = importedBaseline.map(legacyBaseline) ?? "null"
        return """
        ReadingStatistics(title=\(title), dateKey=\(dateKey), charactersRead=\(charactersRead), readingTime=\(StatisticsNumbers.kotlinDoubleText(readingTime)), minReadingSpeed=\(minReadingSpeed), altMinReadingSpeed=\(altMinReadingSpeed), lastReadingSpeed=\(lastReadingSpeed), maxReadingSpeed=\(maxReadingSpeed), lastStatisticModified=\(lastStatisticModified), deviceId=\(deviceId ?? "null"), deviceName=\(deviceName ?? "null"), readingTimeByHour=\(hours), timeZone=\(timeZone ?? "null"), importedBaseline=\(baseline), mangaPageSeconds=\(histogram), readingTimeByZone=\(zones))
        """
    }

    private func legacySorted<Value>(_ values: [String: Value]) -> [(key: String, value: Value)] {
        values.sorted { $0.key.utf16.lexicographicallyPrecedes($1.key.utf16) }
    }

    private func legacyMap<Key, Value>(_ values: [(key: Key, value: Value)], value text: (Value) -> String) -> String {
        "{" + values.map { "\($0.key)=\(text($0.value))" }.joined(separator: ", ") + "}"
    }

    private func legacyHours(_ hours: [String: Double]) -> String {
        legacyMap(legacySorted(hours), value: StatisticsNumbers.kotlinDoubleText)
    }

    private func legacyBaseline(_ baseline: ImportedReadingBaseline) -> String {
        let devices = legacyMap(legacySorted(baseline.includedDevices)) { checkpoint in
            """
            ImportedReadingCheckpoint(charactersRead=\(checkpoint.charactersRead), readingTime=\(StatisticsNumbers.kotlinDoubleText(checkpoint.readingTime)), lastStatisticModified=\(checkpoint.lastStatisticModified), readingTimeByHour=\(legacyHours(checkpoint.readingTimeByHour)), timeZone=\(checkpoint.timeZone ?? "null"))
            """
        }
        return """
        ImportedReadingBaseline(charactersRead=\(baseline.charactersRead), readingTime=\(StatisticsNumbers.kotlinDoubleText(baseline.readingTime)), sourceModified=\(baseline.sourceModified), readingTimeByHour=\(legacyHours(baseline.readingTimeByHour)), timeZone=\(baseline.timeZone ?? "null"), includedDevices=\(devices))
        """
    }

    static func merged(_ entries: [Statistics]) -> [Statistics] { StatisticsMerge.reading(entries) }
    static func mergedLegacy(_ entries: [Statistics]) -> [Statistics] { StatisticsMerge.reading(entries, legacyOrder: true) }

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
        let rows = merged(entries)
        for entry in rows {
            total.readingTime = StatisticsNumbers.adding(total.readingTime, entry.readingTime)
            total.readingTimeByHour = ReadingDay.sumHours([total.readingTimeByHour, entry.readingTimeByHour])
            total.charactersRead = StatisticsNumbers.adding(total.charactersRead, entry.charactersRead)
            total.lastStatisticModified = max(total.lastStatisticModified, entry.lastStatisticModified)
            if entry.minReadingSpeed > 0 { total.minReadingSpeed = total.minReadingSpeed == 0 ? entry.minReadingSpeed : min(total.minReadingSpeed, entry.minReadingSpeed) }
            if entry.altMinReadingSpeed > 0 { total.altMinReadingSpeed = total.altMinReadingSpeed == 0 ? entry.altMinReadingSpeed : min(total.altMinReadingSpeed, entry.altMinReadingSpeed) }
            total.maxReadingSpeed = max(total.maxReadingSpeed, entry.maxReadingSpeed)
        }
        let zones = Set(rows.map(\.timeZone))
        total.timeZone = zones.count == 1 ? zones.first! : nil
        total.lastReadingSpeed = StatisticsNumbers.speed(count: total.charactersRead, seconds: total.readingTime)
        return total
    }
}

