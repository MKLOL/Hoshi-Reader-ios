import Foundation

nonisolated enum StatisticsZone {
    static let legacyID = "America/New_York"
    static let legacyZone = TimeZone(identifier: legacyID)!
    static func zone(_ id: String?) -> TimeZone? {
        guard let id else { return nil }
        if id == "Z" { return TimeZone(secondsFromGMT: 0) }
        return TimeZone(identifier: id) ?? ((id.hasPrefix("+") || id.hasPrefix("-")) ? TimeZone(identifier: "GMT" + id) : nil)
    }
    static var calendar: Calendar { calendar(zone: .current) }
    static var historyCalendar: Calendar {
        calendar(zone: zone(UserDefaults.standard.string(forKey: StatisticsPreferencesStore.zoneKey)) ?? legacyZone)
    }
    static func calendar(zone: TimeZone) -> Calendar {
        var result = Calendar(identifier: .gregorian); result.timeZone = zone; return result
    }
    static func display(_ date: Date, dateStyle: DateFormatter.Style = .medium, timeStyle: DateFormatter.Style = .none, calendar: Calendar = StatisticsZone.calendar) -> String {
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = .current; formatter.dateStyle = dateStyle; formatter.timeStyle = timeStyle
        return formatter.string(from: date)
    }

    static func wallInstant(_ key: String, calendar: Calendar) -> Date? {
        switch ReadingDay.fixedKey(key, time: true) {
        case let .valid(year, month, day, hour, minute, second):
            return calendar.date(from: DateComponents(year: year, month: month, day: day,
                hour: hour, minute: minute, second: second))
        case .invalid: return nil
        case .unusual: return nil
        }
    }
}

nonisolated extension Statistics {
    var recordingZone: TimeZone { StatisticsZone.zone(timeZone) ?? StatisticsZone.legacyZone }
    var wallClockHours: [String: Double] {
        readingTimeByHour.isEmpty ? ReadingDay.sumHours(Array(readingTimeByZone.values)) : readingTimeByHour
    }

    /// Older clients omitted the zone. Use their last counted timestamp only when it
    /// agrees with the last hour or when the hours cover the entire recorded duration.
    func historicalRecordingZone(target: TimeZone) -> TimeZone {
        if let explicit = StatisticsZone.zone(timeZone) { return explicit }
        let hoursByKey = wallClockHours
        guard lastStatisticModified > 0, !hoursByKey.isEmpty else { return target }
        let utc = StatisticsZone.calendar(zone: TimeZone(secondsFromGMT: 0)!)
        guard let wall = hoursByKey.keys.compactMap({ StatisticsZone.wallInstant($0, calendar: utc) }).max() else { return target }
        let stamp = Date(timeIntervalSince1970: Double(lastStatisticModified) / 1000)
        let low = wall.timeIntervalSince(stamp)
        let offset = Double(target.secondsFromGMT(for: stamp))
        if offset > low && offset <= low + 3660 { return target }
        let known = hoursByKey.values.filter { $0.isFinite && $0 > 0 }.reduce(0.0, StatisticsNumbers.adding)
        let hours = floor(low / 3600) + 1
        guard abs(readingTime - known) <= 1, (-14...14).contains(hours) else { return target }
        return TimeZone(secondsFromGMT: Int(hours) * 3600) ?? target
    }

    /// Keep the original wall-clock labels and the cumulative date/device identity.
    mutating func record(hours: [String: Double], in zone: TimeZone) {
        guard !hours.isEmpty else { return }
        let newID = zone.identifier
        let priorHours = wallClockHours
        if readingTimeByZone.isEmpty {
            let oldID = recordingZone.identifier
            if priorHours.isEmpty || oldID == newID {
                timeZone = newID
            } else {
                readingTimeByZone[oldID] = priorHours
            }
        }
        if !readingTimeByZone.isEmpty {
            readingTimeByZone[newID] = ReadingDay.sumHours([readingTimeByZone[newID] ?? [:], hours])
            timeZone = nil
        }
        readingTimeByHour = ReadingDay.sumHours([priorHours, hours])
    }
}
