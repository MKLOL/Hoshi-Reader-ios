import Foundation

nonisolated struct ReadingStreakProgress {
    let current: Int
    let longest: Int
    let qualifyingDays: Int
    let todaySeconds: Double
}

nonisolated struct ReadingStreakRun {
    private var lastDay: Date?
    private var trailing = 0
    private var longest = 0
    private var count = 0

    mutating func add(_ day: Date, calendar: Calendar) {
        if let lastDay, day <= lastDay { return }
        trailing = lastDay.map { ReadingDay.shift($0, by: 1, calendar: calendar) } == day ? trailing + 1 : 1
        lastDay = day
        longest = max(longest, trailing)
        count += 1
    }

    func progress(today: Date, seconds: Double, calendar: Calendar) -> ReadingStreakProgress {
        let active = lastDay == today || lastDay == ReadingDay.shift(today, by: -1, calendar: calendar)
        return ReadingStreakProgress(current: active ? trailing : 0, longest: longest,
                                     qualifyingDays: count, todaySeconds: seconds)
    }
}

/// The overview keeps this across updates. Only the latest three days can change
/// the result without invalidating the cached history, including the longest streak.
@MainActor final class ReadingStreakCache {
    static let shared = ReadingStreakCache()

    private var revision: UUID?
    private var goalSeconds: Double = 0
    private var calendar: Calendar?
    private var through: Date?
    private var historical = ReadingStreakRun()

    func compute(older: ArraySlice<DailyReading>, recent: ArraySlice<DailyReading>, historyRevision: UUID,
                 minimumSeconds: Double, today: Date, calendar: Calendar) -> ReadingStreakProgress {
        let endOfHistory = ReadingDay.shift(today, by: -3, calendar: calendar)
        if revision != historyRevision || goalSeconds != minimumSeconds || self.calendar != calendar ||
            (through.map { endOfHistory < $0 } ?? true) {
            historical = ReadingStreakRun()
            for day in older where day.date <= endOfHistory && day.seconds >= minimumSeconds {
                historical.add(day.date, calendar: calendar)
            }
        } else if let previous = through, endOfHistory > previous {
            // At rollover only the newly finished days enter the prefix.
            let matured = older.reversed().prefix { $0.date > previous }
            for day in matured.reversed() where day.date <= endOfHistory && day.seconds >= minimumSeconds {
                historical.add(day.date, calendar: calendar)
            }
        }
        revision = historyRevision
        goalSeconds = minimumSeconds
        self.calendar = calendar
        through = endOfHistory
        var run = historical
        for day in recent where day.date > endOfHistory && day.date <= today && day.seconds >= minimumSeconds {
            run.add(day.date, calendar: calendar)
        }
        return run.progress(today: today, seconds: recent.first { $0.date == today }?.seconds ?? 0, calendar: calendar)
    }
}
