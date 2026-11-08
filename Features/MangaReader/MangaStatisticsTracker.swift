import Foundation

/// Shared EPUB/manga accumulator. Count means characters in EPUBs and pages in manga.
/// A device only edits its own daily row; today's display sums all devices.
nonisolated struct MangaStatisticsTracker {
    let title: String
    let enabled: Bool
    let device: ReadingDevice?
    /// Manga records one duration per completed page, independently of periodic time ticks.
    let trackPageDurations: Bool
    private(set) var allStats: [Statistics]
    private(set) var isTracking = false
    private(set) var session: Statistics
    private var localToday: Statistics
    private var lastTimestamp: Date
    private var lastPageCount = 0
    private var hasUpdated = false
    private var activePageSeconds = 0.0

    var today: Statistics {
        dayTotal(at: .now)
    }
    func dayTotal(at date: Date, resetHour: Int = ReadingDay.resetHour, calendar: Calendar = StatisticsZone.calendar) -> Statistics {
        let day = ReadingDay.date(at: date, resetHour: resetHour, calendar: calendar)
        let total = ReadingDay.days(reading: rows, resetHour: resetHour, calendar: calendar).first { $0.date == day }
        var result = Statistics.empty(title: title, day: ReadingDay.key(day, calendar: calendar))
        result.readingTime = total?.seconds ?? 0; result.charactersRead = total?.characters ?? 0
        result.lastReadingSpeed = StatisticsNumbers.speed(count: result.charactersRead, seconds: result.readingTime)
        return result
    }
    func textTotal(_ text: [MangaTextStatistic], at date: Date = .now, resetHour: Int = ReadingDay.resetHour, calendar: Calendar = StatisticsZone.calendar) -> Int {
        let day = ReadingDay.date(at: date, resetHour: resetHour, calendar: calendar)
        return ReadingDay.days(reading: rows, text: text, resetHour: resetHour, calendar: calendar).first { $0.date == day }?.characters ?? 0
    }
    var allTime: Statistics {
        let rows = rows
        var total = Statistics.total(rows, title: title)
        total.mangaPageSeconds = Statistics.sumPageSeconds(rows.map(\.mangaPageSeconds))
        return total
    }
    private var rows: [Statistics] { Statistics.merged(allStats.filter { $0.key != localToday.key } + [localToday]) }

    init(title: String, initialStatistics: [Statistics], enabled: Bool, now: Date = .now, device: ReadingDevice? = nil, trackPageDurations: Bool = false) {
        self.title = title
        self.enabled = enabled
        self.device = device
        self.trackPageDurations = trackPageDurations
        allStats = Statistics.merged(initialStatistics)
        lastTimestamp = now
        let day = Self.dateKey(for: now)
        session = .empty(title: title, day: day, device: device)
        localToday = allStats.first { $0.dateKey == day && $0.deviceId == device?.id } ?? .empty(title: title, day: day, device: device)
    }

    mutating func start(currentPage: Int, now: Date = .now) {
        guard enabled else { return }
        isTracking = true
        resetBaseline(currentPage: currentPage, now: now)
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
    mutating func update(currentPage: Int, now: Date = .now) {
        guard enabled, isTracking else { return }
        let day = Self.dateKey(for: now)
        if day != localToday.dateKey {
            allStats = rows
            localToday = allStats.first { $0.dateKey == day && $0.deviceId == device?.id } ?? .empty(title: title, day: day, device: device)
        }
        let elapsed = now.timeIntervalSince(lastTimestamp)
        if elapsed < 0 { lastTimestamp = now }
        guard elapsed > 0 else { return }
        if trackPageDurations { activePageSeconds += elapsed }
        let delta = max(-session.charactersRead, currentPage - lastPageCount)
        let stamp = StatisticsNumbers.integer(now.timeIntervalSince1970 * 1000)
        localToday.record(in: .current)
        session.record(in: .current)
        session.add(seconds: elapsed, count: delta, stamp: stamp)
        localToday.add(seconds: elapsed, count: delta, stamp: stamp)
        let hours = ReadingDay.hours(from: lastTimestamp, to: now)
        localToday.readingTimeByHour = ReadingDay.sumHours([localToday.readingTimeByHour, hours])
        session.readingTimeByHour = ReadingDay.sumHours([session.readingTimeByHour, hours])
        hasUpdated = true
        resetBaseline(currentPage: currentPage, now: now)
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
    mutating func resetBaseline(currentPage: Int, now: Date = .now) {
        lastPageCount = currentPage
        lastTimestamp = now
    }
    mutating func statisticsForPersistence() -> [Statistics]? {
        guard enabled, hasUpdated else { return nil }
        allStats = rows
        return allStats
    }
    mutating func mergeHistory(_ incoming: [Statistics]) {
        allStats = Statistics.merged(rows + incoming)
        if let merged = allStats.first(where: { $0.key == localToday.key }) { localToday = merged }
    }
    static func deduplicate(_ statistics: [Statistics]) -> [Statistics] { Statistics.merged(statistics) }
    static func dateKey(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withFullDate]
        return formatter.string(from: date)
    }
}
