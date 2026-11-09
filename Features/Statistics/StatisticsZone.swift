import Foundation

nonisolated enum StatisticsZone {
    static let key = "statistics.timeZone"
    static let defaultID = "America/New_York"
    static func zone(_ id: String?) -> TimeZone? {
        guard let id else { return nil }
        if id == "Z" { return TimeZone(secondsFromGMT: 0) }
        return TimeZone(identifier: id) ?? ((id.hasPrefix("+") || id.hasPrefix("-")) ? TimeZone(identifier: "GMT" + id) : nil)
    }
    static var calendar: Calendar {
        calendar(zone: zone(UserDefaults.standard.string(forKey: key) ?? defaultID) ?? TimeZone(identifier: defaultID)!)
    }
    static func calendar(zone: TimeZone) -> Calendar {
        var result = Calendar(identifier: .gregorian); result.timeZone = zone; return result
    }
    static func display(_ date: Date, dateStyle: DateFormatter.Style = .medium, timeStyle: DateFormatter.Style = .none, calendar: Calendar = StatisticsZone.calendar) -> String {
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = .current; formatter.dateStyle = dateStyle; formatter.timeStyle = timeStyle
        return formatter.string(from: date)
    }
    static func wallInstant(_ key: String) -> Date? {
        switch ReadingDay.fixedKey(key, time: true) {
        case let .valid(year, month, day, hour, minute, second):
            let utc = calendar(zone: TimeZone(secondsFromGMT: 0)!)
            return utc.date(from: DateComponents(calendar: utc, timeZone: utc.timeZone, year: year, month: month, day: day, hour: hour, minute: minute, second: second))
        case .invalid: return nil
        case .unusual: break
        }
        let formatter = DateFormatter(); formatter.calendar = calendar(zone: TimeZone(secondsFromGMT: 0)!)
        formatter.timeZone = formatter.calendar.timeZone; formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.isLenient = false
        for format in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss"] {
            formatter.dateFormat = format
            if let value = formatter.date(from: key), formatter.string(from: value) == key { return value }
        }
        return nil
    }
    static func convert(_ key: String, from source: TimeZone?, to target: Calendar) -> (date: Date, hour: Int)? {
        guard let source, source != target.timeZone, let wall = wallInstant(key) else { return ReadingDay.hour(key, calendar: target) }
        let utc = calendar(zone: TimeZone(secondsFromGMT: 0)!)
        let components = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: wall)
        guard let instant = calendar(zone: source).date(from: components) else { return nil }
        return (target.startOfDay(for: instant), target.component(.hour, from: instant))
    }
}

nonisolated extension Statistics {
    /// Old rows can reveal their recording offset from the absolute last-counted timestamp.
    /// Later aggregate edits cannot: only complete hourly evidence qualifies for inference.
    func recordedZone(target: TimeZone) -> TimeZone? {
        if let timeZone, let zone = StatisticsZone.zone(timeZone) { return zone }
        guard lastStatisticModified > 0, let last = readingTimeByHour.keys.compactMap(StatisticsZone.wallInstant).max() else { return nil }
        let stamp = Date(timeIntervalSince1970: Double(lastStatisticModified) / 1000)
        let low = last.timeIntervalSince(stamp)
        let targetOffset = Double(target.secondsFromGMT(for: stamp))
        if targetOffset > low && targetOffset <= low + 3660 { return target }
        let known = readingTimeByHour.values.filter { $0.isFinite && $0 > 0 }.reduce(0.0, StatisticsNumbers.adding)
        guard abs(readingTime - known) <= 1 else { return nil }
        let hours = floor(low / 3600) + 1
        guard hours >= -14, hours <= 14 else { return nil }
        return TimeZone(secondsFromGMT: Int(hours) * 3600)
    }
    mutating func record(in zone: TimeZone) {
        guard timeZone != zone.identifier else { return }
        let from = recordedZone(target: zone)
        if let from, from != zone {
            let calendar = StatisticsZone.calendar(zone: zone)
            var converted: [String: Double] = [:]
            for (key, seconds) in readingTimeByHour {
                let moved = StatisticsZone.convert(key, from: from, to: calendar).map {
                    ReadingDay.key($0.date, calendar: calendar) + String(format: "T%02d:00", $0.hour)
                } ?? key
                converted[moved] = StatisticsNumbers.adding(converted[moved] ?? 0, seconds)
            }
            readingTimeByHour = converted
        }
        timeZone = zone.identifier
    }
}
