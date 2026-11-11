import Foundation

/// Shared EPUB/manga accumulator. Count means characters in EPUBs and pages in manga.
/// A device only edits its own daily row; today's display sums all devices.
nonisolated struct MangaStatisticsTracker {
    let title: String
    let enabled: Bool
    let device: ReadingDevice?
    /// Manga records one duration per completed page, independently of periodic time ticks.
    let trackPageDurations: Bool
    private var statisticsByDate: [String: [Statistics]]
    private(set) var isTracking = false
    private(set) var session: Statistics
    private var localToday: Statistics
    private var lastTimestamp: Date
    private var lastTimeZone: TimeZone
    private var lastPageCount = 0
    private var hasUpdated = false
    private var activePageSeconds = 0.0

    var today: Statistics {
        dayTotal(at: .now)
    }
    func dayTotal(at date: Date, resetHour: Int = ReadingDay.resetHour, calendar: Calendar = StatisticsZone.calendar) -> Statistics {
        let day = ReadingDay.date(at: date, resetHour: resetHour, calendar: calendar)
        let dates = readingDaySourceDates(day, calendar: calendar)
        let total = ReadingDay.days(reading: dates.flatMap { rows(on: $0) }, resetHour: resetHour, calendar: calendar)
            .first { $0.date == day }
        var result = Statistics.empty(title: title, day: dates[0])
        result.readingTime = total?.seconds ?? 0; result.charactersRead = total?.characters ?? 0
        result.lastReadingSpeed = StatisticsNumbers.speed(count: result.charactersRead, seconds: result.readingTime)
        return result
    }
    func textTotal(_ text: [MangaTextStatistic], at date: Date = .now, resetHour: Int = ReadingDay.resetHour, calendar: Calendar = StatisticsZone.calendar) -> Int {
        let day = ReadingDay.date(at: date, resetHour: resetHour, calendar: calendar)
        let dates = readingDaySourceDates(day, calendar: calendar)
        let relevantText = text.filter { dates.contains($0.dateKey) }
        return ReadingDay.days(reading: dates.flatMap { rows(on: $0) }, text: relevantText, resetHour: resetHour, calendar: calendar)
            .first { $0.date == day }?.characters ?? 0
    }
    var allTime: Statistics {
        let rows = rows
        var total = Statistics.total(rows, title: title)
        total.mangaPageSeconds = Statistics.sumPageSeconds(rows.map(\.mangaPageSeconds))
        return total
    }
    private var rows: [Statistics] {
        Statistics.merged(statisticsByDate.values.flatMap { $0 }.filter { $0.key != localToday.key } + [localToday])
    }

    private func rows(on date: String) -> [Statistics] {
        let stored = statisticsByDate[date] ?? []
        guard date == localToday.dateKey else { return stored }
        return stored.filter { $0.deviceId != localToday.deviceId } + [localToday]
    }

    /// A row can contain the previous calendar day's pre-reset hours, up to two days back.
    private func readingDaySourceDates(_ day: Date, calendar: Calendar) -> [String] {
        (0...2).map { ReadingDay.key(ReadingDay.shift(day, by: $0, calendar: calendar), calendar: calendar) }
    }

    init(title: String, initialStatistics: [Statistics], enabled: Bool, now: Date = .now, device: ReadingDevice? = nil, trackPageDurations: Bool = false, timeZone: TimeZone = .current) {
        self.title = title
        self.enabled = enabled
        self.device = device
        self.trackPageDurations = trackPageDurations
        statisticsByDate = Dictionary(grouping: Statistics.merged(initialStatistics), by: \.dateKey)
        lastTimestamp = now
        lastTimeZone = timeZone
        let day = ReaderDateFormatting.shared.dayKey(for: now, timeZone: timeZone)
        session = .empty(title: title, day: day, device: device)
        localToday = statisticsByDate[day]?.first { $0.deviceId == device?.id } ?? .empty(title: title, day: day, device: device)
    }

    mutating func start(currentPage: Int, now: Date = .now, timeZone: TimeZone = .current) {
        guard enabled else { return }
        isTracking = true
        resetBaseline(currentPage: currentPage, now: now, timeZone: timeZone)
    }
    mutating func startForPageTurnIfNeeded(currentPage: Int, now: Date = .now) {
        if !isTracking { start(currentPage: currentPage, now: now) }
    }
    @discardableResult mutating func pause(currentPage: Int, now: Date = .now) -> Bool {
        guard isTracking else { return false }
        update(currentPage: currentPage, now: now)
        isTracking = false
        return true
    }
    mutating func update(currentPage: Int, now: Date = .now, timeZone: TimeZone = .current) {
        guard enabled, isTracking else { return }
        // The elapsed interval began under the previous clock. A time zone change starts a
        // new interval while keeping the preceding time under its recorded local hours.
        let elapsed = now.timeIntervalSince(lastTimestamp)
        guard elapsed > 0 else {
            if elapsed < 0 { lastTimestamp = now }
            lastTimeZone = timeZone
            return
        }
        let recordingZone = lastTimeZone
        let day = ReaderDateFormatting.shared.dayKey(for: now, timeZone: recordingZone)
        if day != localToday.dateKey {
            statisticsByDate[localToday.dateKey] = rows(on: localToday.dateKey)
            localToday = statisticsByDate[day]?.first { $0.deviceId == device?.id } ?? .empty(title: title, day: day, device: device)
        }
        if trackPageDurations { activePageSeconds += elapsed }
        let delta = max(-session.charactersRead, currentPage - lastPageCount)
        let stamp = StatisticsNumbers.integer(now.timeIntervalSince1970 * 1000)
        let hours = ReadingDay.hours(from: lastTimestamp, to: now, calendar: StatisticsZone.calendar(zone: recordingZone))
        localToday.record(hours: hours, in: recordingZone)
        session.record(hours: hours, in: recordingZone)
        session.add(seconds: elapsed, count: delta, stamp: stamp)
        localToday.add(seconds: elapsed, count: delta, stamp: stamp)
        hasUpdated = true
        resetBaseline(currentPage: currentPage, now: now, timeZone: timeZone)
    }
    /// Called for every navigation. Only forward turns complete pages; jumps and backtracking
    /// discard the unfinished sample rather than inventing page durations. Pausing keeps active
    /// time on the same page but never counts the paused time. A two-page spread turn splits
    /// its time evenly between the pages it completes.
    mutating func pageChanged(currentPage: Int, completedPages: Int, now: Date = .now) {
        update(currentPage: currentPage, now: now)
        if trackPageDurations, isTracking, completedPages > 0, activePageSeconds > 0 {
            let seconds = max(1, StatisticsNumbers.integer((activePageSeconds / Double(completedPages)).rounded()))
            localToday.mangaPageSeconds = Statistics.sumPageSeconds([localToday.mangaPageSeconds, [seconds: completedPages]])
            localToday.lastStatisticModified = max(StatisticsNumbers.integer(now.timeIntervalSince1970 * 1000),
                                                   StatisticsNumbers.nextStamp(localToday.lastStatisticModified))
            hasUpdated = true
        }
        activePageSeconds = 0
    }
    mutating func resetBaseline(currentPage: Int, now: Date = .now, timeZone: TimeZone = .current) {
        lastPageCount = currentPage
        lastTimestamp = now
        lastTimeZone = timeZone
    }
    mutating func statisticsForPersistence() -> [Statistics]? {
        guard enabled, hasUpdated else { return nil }
        let persisted = rows
        statisticsByDate = Dictionary(grouping: persisted, by: \.dateKey)
        return persisted
    }
    mutating func mergeHistory(_ incoming: [Statistics]) {
        statisticsByDate = Dictionary(grouping: Statistics.merged(rows + incoming), by: \.dateKey)
        if let merged = statisticsByDate[localToday.dateKey]?.first(where: { $0.deviceId == localToday.deviceId }) {
            localToday = merged
        }
    }
    static func deduplicate(_ statistics: [Statistics]) -> [Statistics] { Statistics.merged(statistics) }
    static func dateKey(for date: Date) -> String {
        ReaderDateFormatting.shared.dayKey(for: date)
    }
}

/// Shared by the main-actor tracker and the background usage writer. A timezone is resolved
/// for every call so changing the system zone does not leave the cache on yesterday's zone.
nonisolated final class ReaderDateFormatting: @unchecked Sendable {
    static let shared = ReaderDateFormatting()
    private let lock = NSLock()
    private let dayFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter
    }()

    func dayKey(for date: Date, timeZone: TimeZone = .current) -> String {
        lock.lock()
        defer { lock.unlock() }
        if dayFormatter.timeZone != timeZone { dayFormatter.timeZone = timeZone }
        return dayFormatter.string(from: date)
    }

    static func utcOffset(for date: Date, timeZone: TimeZone = .current) -> String {
        let seconds = timeZone.secondsFromGMT(for: date)
        if seconds == 0 { return "+00:00" }
        let minutes = abs(seconds / 60)
        func pair(_ value: Int) -> String { value < 10 ? "0" + String(value) : String(value) }
        return (seconds < 0 ? "-" : "+") + pair(minutes / 60) + ":" + pair(minutes % 60)
    }
}
