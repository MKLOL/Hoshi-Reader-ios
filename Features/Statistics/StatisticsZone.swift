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
    static func calendar(zone: TimeZone) -> Calendar {
        var result = Calendar(identifier: .gregorian); result.timeZone = zone; return result
    }
    static func display(_ date: Date, dateStyle: DateFormatter.Style = .medium, timeStyle: DateFormatter.Style = .none, calendar: Calendar = StatisticsZone.calendar) -> String {
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = .current; formatter.dateStyle = dateStyle; formatter.timeStyle = timeStyle
        return formatter.string(from: date)
    }
}

nonisolated extension Statistics {
    var recordingZone: TimeZone { StatisticsZone.zone(timeZone) ?? StatisticsZone.legacyZone }
    var wallClockHours: [String: Double] {
        readingTimeByHour.isEmpty ? ReadingDay.sumHours(Array(readingTimeByZone.values)) : readingTimeByHour
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
