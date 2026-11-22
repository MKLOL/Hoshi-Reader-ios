import Foundation

nonisolated struct ReadingStreakProgress {
    let current: Int
    let longest: Int
    let qualifyingDays: Int
    let todaySeconds: Double
}

nonisolated enum ReadingStreakRules {
    static func run(_ days: some Sequence<DailyReading>, minimumSeconds: Double, through: Date,
                    today: Date? = nil, calendar: Calendar, state: [String: Any]? = nil)
        -> (progress: ReadingStreakProgress, state: [String: Any]) {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        func key(_ date: Date) -> String {
            let parts = gregorian.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        }
        let daily: [[Any]] = days.map { [key($0.date), $0.streakSeconds] }
        var payload: [String: Any] = ["days": daily, "goal": minimumSeconds, "through": key(through)]
        if let state { payload["state"] = state }
        if let today { payload["today"] = key(today) }
        do {
            guard let result = try HoshiCore.call("streak.run", payload: payload) as? [String: Any],
                  let state = result["state"] as? [String: Any],
                  let current = result["current"] as? Int,
                  let longest = result["longest"] as? Int,
                  let count = result["count"] as? Int,
                  let seconds = result["todaySeconds"] as? Double else {
                preconditionFailure("Invalid shared streak result")
            }
            return (ReadingStreakProgress(current: current, longest: longest, qualifyingDays: count, todaySeconds: seconds), state)
        } catch {
            preconditionFailure("Could not compute reading streak: \(error)")
        }
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
    private var historical: [String: Any]?

    func compute(older: ArraySlice<DailyReading>, recent: ArraySlice<DailyReading>, historyRevision: UUID,
                 minimumSeconds: Double, today: Date, calendar: Calendar) -> ReadingStreakProgress {
        let endOfHistory = ReadingDay.shift(today, by: -3, calendar: calendar)
        if revision != historyRevision || goalSeconds != minimumSeconds || self.calendar != calendar ||
            (through.map { endOfHistory < $0 } ?? true) {
            historical = ReadingStreakRules.run(older, minimumSeconds: minimumSeconds, through: endOfHistory, calendar: calendar).state
        } else if let previous = through, endOfHistory > previous {
            let matured = older.reversed().prefix { $0.date > previous }
            historical = ReadingStreakRules.run(matured, minimumSeconds: minimumSeconds, through: endOfHistory,
                                                calendar: calendar, state: historical).state
        }
        revision = historyRevision
        goalSeconds = minimumSeconds
        self.calendar = calendar
        through = endOfHistory
        let live = recent.lazy.filter { $0.date > endOfHistory }
        return ReadingStreakRules.run(live, minimumSeconds: minimumSeconds, through: today, today: today,
                                     calendar: calendar, state: historical).progress
    }
}
