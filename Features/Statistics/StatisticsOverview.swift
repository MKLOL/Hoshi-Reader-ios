import Foundation

/// A reading day is a local wall-clock date, never a fixed 24-hour offset (DST can change its length).
nonisolated enum ReadingDay {
    static var calendar: Calendar { StatisticsZone.calendar }
    static let resetKey = "statistics.dayResetHour"
    static let goalKey = "statistics.dailyGoalMinutes"
    static func normalizedGoal(_ minutes: Int) -> Int { min(600, max(1, minutes)) }
    static let travelStartKey = "2026-11-01"
    private static let travelCutoverWindow: DateInterval = {
        let utc = StatisticsZone.calendar(zone: TimeZone(secondsFromGMT: 0)!)
        let midnight = parse(travelStartKey, calendar: utc)!
        return DateInterval(start: midnight.addingTimeInterval(-36 * 3600), end: midnight.addingTimeInterval(48 * 3600))
    }()
    static var resetHour: Int { resetHour(defaults: .standard) }
    static func resetHour(defaults: UserDefaults) -> Int {
        defaults.object(forKey: resetKey) == nil ? 3 : min(23, max(0, defaults.integer(forKey: resetKey)))
    }
    static func date(at instant: Date, resetHour: Int, calendar: Calendar = StatisticsZone.calendar) -> Date {
        let day = calendar.startOfDay(for: instant)
        return calendar.component(.hour, from: instant) < min(23, max(0, resetHour))
            ? shift(day, by: -1, calendar: calendar) : day
    }
    static func travelCutover(resetHour: Int, historyCalendar: Calendar = StatisticsZone.historyCalendar) -> Date {
        boundary(on: parse(travelStartKey, calendar: historyCalendar)!, resetHour: resetHour, calendar: historyCalendar)
    }
    static func cutoverForRecording(from start: Date, to end: Date) -> Date? {
        guard start < travelCutoverWindow.end, end >= travelCutoverWindow.start else { return nil }
        return travelCutover(resetHour: resetHour)
    }
    /// Keep one set of date labels in the display calendar, even when the historical
    /// reading day is still running on a different clock.
    static func today(at instant: Date, resetHour: Int, calendar: Calendar = StatisticsZone.calendar,
                      historyCalendar: Calendar = StatisticsZone.historyCalendar) -> Date {
        guard calendar.timeZone != historyCalendar.timeZone,
              instant < travelCutover(resetHour: resetHour, historyCalendar: historyCalendar) else {
            return date(at: instant, resetHour: resetHour, calendar: calendar)
        }
        let historical = date(at: instant, resetHour: resetHour, calendar: historyCalendar)
        return relabel(historical, from: historyCalendar, to: calendar) ?? calendar.startOfDay(for: instant)
    }
    private static func relabel(_ day: Date, from source: Calendar, to target: Calendar) -> Date? {
        guard source.timeZone != target.timeZone else { return day }
        return gregorian(target).date(from: gregorian(source).dateComponents([.year, .month, .day], from: day))
            .map(target.startOfDay(for:))
    }
    /// The day [days] away, at its first instant. Adding days to a skipped or repeated
    /// midnight lands on another instant of the target day; this always returns its start.
    static func shift(_ day: Date, by days: Int, calendar: Calendar = StatisticsZone.calendar) -> Date {
        calendar.startOfDay(for: calendar.date(byAdding: .day, value: days, to: day.addingTimeInterval(12 * 3600))!)
    }
    static func boundary(on day: Date, resetHour: Int, calendar: Calendar = StatisticsZone.calendar) -> Date {
        calendar.date(bySettingHour: min(23, max(0, resetHour)), minute: 0, second: 0, of: calendar.startOfDay(for: day))!
    }
    private static func gregorian(_ calendar: Calendar) -> Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = calendar.timeZone; return value
    }
    static func key(_ date: Date, calendar: Calendar = StatisticsZone.calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = gregorian(calendar); formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    /// Day and hour keys have a fixed ASCII grammar, and one sync pass reads a key for every
    /// statistics row and every listed server key. Reading the grammar directly avoids building
    /// an ICU formatter each time. Any other text, including dates before the Gregorian
    /// calendar, is `unusual` and keeps the formatter's answer.
    enum FixedKey {
        case valid(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int)
        /// The right shape, but not a real date or time.
        case invalid
        case unusual
    }
    static func fixedKey(_ key: String, time: Bool = false) -> FixedKey {
        let bytes = Array(key.utf8)
        func digits(_ range: Range<Int>) -> Int? {
            var value = 0
            for byte in bytes[range] {
                guard (48...57).contains(byte) else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            return value
        }
        guard bytes.count == (time ? 16 : 10) || (time && bytes.count == 19), bytes[4] == 45, bytes[7] == 45,
              let year = digits(0..<4), let month = digits(5..<7), let day = digits(8..<10), year >= 1583 else { return .unusual }
        var hour = 0, minute = 0, second = 0
        if time {
            guard bytes[10] == 84, bytes[13] == 58, let hours = digits(11..<13), let minutes = digits(14..<16) else { return .unusual }
            hour = hours; minute = minutes
            if bytes.count == 19 {
                guard bytes[16] == 58, let seconds = digits(17..<19) else { return .unusual }
                second = seconds
            }
        }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        guard (1...12).contains(month), day >= 1, day <= [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1],
              hour < 24, minute < 60, second < 60 else { return .invalid }
        return .valid(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    }
    /// Whether the text names a real day, without needing its instant in any zone.
    static func isDay(_ key: String) -> Bool {
        switch fixedKey(key) {
        case .valid: return true
        case .invalid: return false
        case .unusual: return parse(key) != nil
        }
    }
    static func parse(_ key: String, calendar: Calendar = StatisticsZone.calendar) -> Date? {
        switch fixedKey(key) {
        case let .valid(year, month, day, _, _, _):
            // A zone whose DST change skips midnight has no 00:00 that day, but the day still
            // begins at its first valid instant.
            let zoned = gregorian(calendar)
            return zoned.date(from: DateComponents(calendar: zoned, timeZone: calendar.timeZone, year: year, month: month, day: day))
                .map(zoned.startOfDay(for:))
        case .invalid: return nil
        case .unusual: break
        }
        // Validate the text in UTC: a zone whose DST change skips midnight has no 00:00 that day,
        // but the day still begins at its first valid instant.
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let formatter = DateFormatter()
        formatter.calendar = utc; formatter.timeZone = utc.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard let parsed = formatter.date(from: key), formatter.string(from: parsed) == key else { return nil }
        var components = utc.dateComponents([.year, .month, .day], from: parsed)
        components.calendar = gregorian(calendar); components.timeZone = calendar.timeZone
        guard let date = gregorian(calendar).date(from: components) else { return nil }
        return gregorian(calendar).startOfDay(for: date)
    }
    /// Hour keys deliberately have no zone: both clients interpret the reader's recorded local date/hour.
    static func hour(_ key: String, calendar: Calendar = StatisticsZone.calendar) -> (date: Date, hour: Int)? {
        switch fixedKey(key, time: true) {
        case let .valid(year, month, day, hour, _, _):
            let zoned = gregorian(calendar)
            return zoned.date(from: DateComponents(calendar: zoned, timeZone: calendar.timeZone, year: year, month: month, day: day))
                .map { ($0, hour) }
        case .invalid: return nil
        case .unusual: break
        }
        // Parse wall-clock text in UTC first so a historical hour survives a later timezone
        // change or a DST gap in the current zone; only its date and hour are significant.
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let formatter = DateFormatter()
        formatter.calendar = utc; formatter.timeZone = utc.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.isLenient = false
        for format in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss"] {
            formatter.dateFormat = format
            guard let parsed = formatter.date(from: key), formatter.string(from: parsed) == key else { continue }
            var components = utc.dateComponents([.year, .month, .day], from: parsed)
            components.calendar = gregorian(calendar); components.timeZone = calendar.timeZone
            if let date = gregorian(calendar).date(from: components) { return (date, utc.component(.hour, from: parsed)) }
        }
        return nil
    }

    static func hours(from start: Date, to end: Date, calendar: Calendar = .current, splitAt cutoff: Date? = nil) -> [String: Double] {
        guard end > start else { return [:] }
        var result: [String: Double] = [:], cursor = start
        while cursor < end {
            guard let interval = calendar.dateInterval(of: .hour, for: cursor), interval.end > cursor else { break }
            let next = min(end, interval.end, cutoff.flatMap { cursor < $0 ? $0 : nil } ?? end)
            // A half-hour or quarter-hour zone can put the switch inside a local hour.
            // Give the part after the switch its own wall-clock key.
            let minute = cutoff.flatMap { interval.start < $0 && $0 <= cursor ? calendar.component(.minute, from: $0) : nil } ?? 0
            let key = key(cursor, calendar: calendar) + String(format: "T%02d:%02d", calendar.component(.hour, from: cursor), minute)
            result[key] = StatisticsNumbers.adding(result[key] ?? 0, next.timeIntervalSince(cursor))
            cursor = next
        }
        return result
    }
    static func sumHours(_ rows: [[String: Double]]) -> [String: Double] {
        var result: [String: Double] = [:]
        for row in rows { for (key, seconds) in row where seconds.isFinite && seconds > 0 {
            result[key] = StatisticsNumbers.adding(result[key] ?? 0, seconds)
        } }
        return result
    }
    /// Preserve calendar-day storage and redistribute only presentation. Unknown time stays on its own
    /// date. Characters follow each calendar date's time, with largest-remainder rounding preserving totals.
    static func days(reading: [Statistics], text: [MangaTextStatistic]? = nil, resetHour: Int,
                     calendar: Calendar = StatisticsZone.calendar, historyCalendar: Calendar = StatisticsZone.historyCalendar,
                     includeLegacyStreakCredit: Bool = false) -> [DailyReading] {
        let rows = Statistics.merged(reading)
        let projectedRows: [[String: Any]] = rows.compactMap { row in
            guard row.readingTime.isFinite, row.readingTime > 0 else { return nil }
            var fields: [String: Any] = [
                "key": row.key, "date": row.dateKey, "seconds": row.readingTime,
                "updatedAt": row.lastStatisticModified,
                "hours": row.readingTimeByHour.filter { $0.value.isFinite },
                "zones": row.readingTimeByZone.mapValues { $0.filter { $0.value.isFinite } }
            ]
            if let timeZone = row.timeZone { fields["timeZone"] = timeZone }
            return fields
        }
        let characterCounts = text.map { MangaTextStatistic.merged($0).map { ($0.key, $0.dateKey, $0.charactersRead) } }
            ?? rows.map { ($0.key, $0.dateKey, $0.charactersRead) }
        let characters: [[String: Any]] = characterCounts.compactMap { key, date, count in
            count > 0 ? ["key": key, "date": date, "count": count] : nil
        }
        do {
            let result = try HoshiCore.call("streak.project", payload: [
                "rows": projectedRows, "characters": characters, "reset": resetHour,
                "legacyZone": historyCalendar.timeZone.identifier, "includeCredit": includeLegacyStreakCredit
            ])
            guard let days = result as? [String: [String: NSNumber]] else {
                preconditionFailure("Invalid shared reading days")
            }
            return days.compactMap { key, day in
                parse(key, calendar: calendar).map { date in
                    DailyReading(date: date, seconds: day["seconds"]?.doubleValue ?? 0,
                        characters: Int(clamping: day["characters"]?.uint64Value ?? 0),
                        legacyStreakCredit: day["streakCredit"]?.doubleValue ?? 0)
                }
            }.sorted { $0.date < $1.date }
        } catch {
            preconditionFailure("Could not calculate reading days: \(error)")
        }
    }
}

nonisolated struct BookReadingSummary: Identifiable, Sendable {
    var book: BookMetadata
    let reading: [Statistics]
    let mangaText: [MangaTextStatistic]
    var finished: Bool
    let resetHour: Int
    let seconds: Double
    let characters: Int
    let pages: Int
    let devices: [DeviceReadingSummary]
    let days: [DailyReading]
    let streakDays: [DailyReading]
    var id: UUID { book.id }
    var isManga: Bool { book.resolvedContentType == .mokuro }

    init(book: BookMetadata, reading: [Statistics], mangaText: [MangaTextStatistic], finished: Bool,
         resetHour: Int = 3, calendar: Calendar = StatisticsZone.calendar, historyCalendar: Calendar = StatisticsZone.historyCalendar,
         days: [DailyReading]? = nil, devices: [DeviceReadingSummary]? = nil) {
        self.book = book; self.reading = reading; self.mangaText = mangaText
        self.finished = finished; self.resetHour = resetHour
        let isManga = book.resolvedContentType == .mokuro
        seconds = reading.reduce(0.0) { StatisticsNumbers.adding($0, $1.readingTime) }
        characters = isManga ? mangaText.reduce(0) { StatisticsNumbers.adding($0, $1.charactersRead) } : reading.reduce(0) { StatisticsNumbers.adding($0, $1.charactersRead) }
        pages = isManga ? reading.reduce(0) { StatisticsNumbers.adding($0, $1.charactersRead) } : 0
        streakDays = days ?? ReadingDay.days(reading: reading, text: isManga ? mangaText : nil, resetHour: resetHour,
            calendar: calendar, historyCalendar: historyCalendar, includeLegacyStreakCredit: true)
        self.days = streakDays.filter(\.hasActivity)
        self.devices = devices ?? StatisticsMath.devices(reading: reading, text: mangaText, isManga: isManga, resetHour: resetHour,
            calendar: calendar, historyCalendar: historyCalendar)
    }
}

nonisolated struct DailyReading: Identifiable, Sendable {
    let date: Date
    var seconds: Double = 0
    var characters: Int = 0
    var legacyStreakCredit: Double = 0
    var hasActivity: Bool { seconds > 0 || characters > 0 }
    var streakSeconds: Double { StatisticsNumbers.adding(seconds, legacyStreakCredit) }
    var id: Date { date }
}

nonisolated struct DeviceReadingSummary: Identifiable, Sendable {
    let deviceId: String?
    var name: String?
    var seconds: Double
    var characters: Int
    var pages: Int
    var books: Int
    var lastRead: Date?
    var newestStamp: Int
    var id: String { deviceId ?? "" }
}

nonisolated enum StatisticsMath {
    static func isFinished(bookmark: Bookmark?, info: BookInfo?, isManga: Bool) -> Bool {
        guard let bookmark else { return false }
        if let total = info?.characterCount, total > 0 {
            return Double(bookmark.characterCount) / Double(total) >= 0.999
        }
        // EPUB bookmark.progress is relative to one chapter, never the whole book.
        return isManga && bookmark.progress >= 0.999
    }

    static func devices(reading: [Statistics], text: [MangaTextStatistic], isManga: Bool, resetHour: Int = 0,
                        calendar: Calendar = StatisticsZone.calendar, historyCalendar: Calendar = StatisticsZone.historyCalendar) -> [DeviceReadingSummary] {
        let reading = Statistics.merged(reading), text = MangaTextStatistic.merged(text)
        let ids = Set(reading.map(\.deviceId) + text.map(\.deviceId))
        return ids.compactMap { id in
            let own = reading.filter { $0.deviceId == id }, ownText = text.filter { $0.deviceId == id }
            let total = Statistics.total(own)
            let characters = isManga ? ownText.reduce(0) { StatisticsNumbers.adding($0, $1.charactersRead) } : total.charactersRead
            guard total.readingTime > 0 || total.charactersRead > 0 || characters > 0 else { return nil }
            let names = own.map { ($0.lastStatisticModified, $0.deviceName) } + ownText.map { ($0.lastModified, $0.deviceName) }
            let named = names.filter { !($0.1?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }.max { $0.0 < $1.0 }
            return DeviceReadingSummary(deviceId: id, name: named?.1, seconds: total.readingTime, characters: characters,
                pages: isManga ? total.charactersRead : 0, books: 1,
                lastRead: ReadingDay.days(reading: own, resetHour: resetHour, calendar: calendar, historyCalendar: historyCalendar)
                    .last { $0.seconds > 0 }?.date,
                newestStamp: named?.0 ?? names.map(\.0).max() ?? 0)
        }.sorted { $0.seconds == $1.seconds ? $0.id < $1.id : $0.seconds > $1.seconds }
    }

    static func combineDevices(_ devices: [DeviceReadingSummary]) -> [DeviceReadingSummary] {
        Dictionary(grouping: devices, by: \.id).map { _, rows in
            var total = rows[0]
            total.name = rows.filter { $0.name != nil }.max { $0.newestStamp < $1.newestStamp }?.name
            total.seconds = rows.reduce(0.0) { StatisticsNumbers.adding($0, $1.seconds) }
            total.characters = rows.reduce(0) { StatisticsNumbers.adding($0, $1.characters) }
            total.pages = rows.reduce(0) { StatisticsNumbers.adding($0, $1.pages) }
            total.books = rows.reduce(0) { StatisticsNumbers.adding($0, $1.books) }
            total.lastRead = rows.compactMap(\.lastRead).max()
            total.newestStamp = rows.map(\.newestStamp).max() ?? 0
            return total
        }.sorted { $0.seconds == $1.seconds ? $0.id < $1.id : $0.seconds > $1.seconds }
    }

    static func date(_ key: String) -> Date? { ReadingDay.parse(key) }
    static func days(reading: [Statistics], text: [MangaTextStatistic]? = nil, resetHour: Int = 0) -> [DailyReading] {
        ReadingDay.days(reading: reading, text: text, resetHour: resetHour)
    }
    static func combine(_ days: [DailyReading]) -> [DailyReading] {
        Dictionary(grouping: days, by: \.date).map { date, rows in
            DailyReading(date: date, seconds: rows.reduce(0.0) { StatisticsNumbers.adding($0, $1.seconds) },
                characters: rows.reduce(0) { StatisticsNumbers.adding($0, $1.characters) },
                legacyStreakCredit: rows.reduce(0.0) { StatisticsNumbers.adding($0, $1.legacyStreakCredit) })
        }.sorted { $0.date < $1.date }
    }
    static func streak(_ days: [DailyReading], goalMinutes: Int, now: Date = .now, resetHour: Int = 0,
                       calendar: Calendar = StatisticsZone.calendar, historyCalendar: Calendar = StatisticsZone.historyCalendar) -> (current: Int, longest: Int) {
        let today = ReadingDay.today(at: now, resetHour: resetHour, calendar: calendar, historyCalendar: historyCalendar)
        let goal = Double(ReadingDay.normalizedGoal(goalMinutes)) * 60
        let progress = ReadingStreakRules.run(days, minimumSeconds: goal, through: today, today: today, calendar: calendar).progress
        return (progress.current, progress.longest)
    }
    /// Clock-like, for playback positions; reading totals use `readingTime`.
    /// Seconds stay past the hour, so neighbouring transcript lines keep distinct timestamps.
    static func duration(_ seconds: Double) -> String {
        let value = StatisticsNumbers.integer(seconds)
        if value >= 3600 { return "\(value / 3600)h \(value % 3600 / 60)m \(value % 60)s" }
        return "\(value / 60)m \(value % 60)s"
    }
    /// Show reading time to the second, with compact units for long sessions and totals.
    static func readingTime(_ seconds: Double, locale: Locale = .current) -> String {
        let style = Duration.UnitsFormatStyle(allowedUnits: [.hours, .minutes, .seconds], width: .narrow).locale(locale)
        return Duration.seconds(StatisticsNumbers.integer(seconds)).formatted(style)
    }
    /// The smallest round axis top whose half is a round gridline too: 134 → 150, 21,000 → 30,000.
    static func axisTop(_ largest: Double) -> Double {
        guard largest.isFinite, largest > 0 else { return 1 }
        let half = largest / 2, magnitude = pow(10, floor(log10(half)))
        let step = [1, 1.5, 2, 2.5, 3, 4, 5, 6, 7.5, 8, 10].map { $0 * magnitude }.first { $0 >= half * (1 - 1e-9) } ?? half
        return step * 2
    }
    /// Android's four heatmap levels: 0 for nothing read, then each quarter of the busiest day.
    static func heatmapLevel(_ seconds: Double, maximum: Double) -> Int {
        guard seconds > 0, maximum > 0 else { return 0 }
        return min(4, max(1, Int(ceil(seconds / maximum * 4))))
    }
}

@Observable @MainActor final class StatisticsOverview {
    // Retain one library snapshot across Statistics screens. The loader checks the current
    // directory, calendar, reset hour and sidecar fingerprints before reusing it.
    private static var sharedSnapshot: StatisticsOverviewSnapshot?
    private static var nextSharedRead = 0
    private static var latestSharedRead = 0

    var books: [BookReadingSummary] = [] { didSet { snapshot = nil; fallbackRevision = UUID() } }
    private var snapshot: StatisticsOverviewSnapshot?
    private var scheduled: Task<Void, Never>?
    private var reloadGeneration = 0
    private let customLoader: (@Sendable (URL, Int, Calendar) async -> StatisticsOverviewSnapshot)?
    private var fallbackRevision = UUID()
    private(set) var loaded = false
    init(loadSnapshot: (@Sendable (URL, Int, Calendar) async -> StatisticsOverviewSnapshot)? = nil) {
        customLoader = loadSnapshot
    }
    var days: [DailyReading] { snapshot?.days ?? StatisticsMath.combine(books.flatMap(\.days)) }
    var devices: [DeviceReadingSummary] { snapshot?.devices ?? StatisticsMath.combineDevices(books.flatMap(\.devices)) }

    func streakDays(today: Date, calendar: Calendar) -> (older: ArraySlice<DailyReading>, recent: ArraySlice<DailyReading>, revision: UUID) {
        let all = snapshot?.streakDays ?? StatisticsMath.combine(books.flatMap(\.streakDays))
        let cutoff = all.lowerBound(for: ReadingDay.shift(today, by: -2, calendar: calendar))
        let end = all.lowerBound(for: ReadingDay.shift(today, by: 1, calendar: calendar))
        return (all[..<cutoff], all[cutoff..<end], snapshot?.historyRevision ?? fallbackRevision)
    }

    private func loadSnapshot(_ directory: URL, _ resetHour: Int, _ calendar: Calendar) async -> StatisticsOverviewSnapshot {
        if let customLoader { return await customLoader(directory, resetHour, calendar) }
        Self.nextSharedRead += 1
        let read = Self.nextSharedRead
        let previous = Self.sharedSnapshot ?? snapshot
        let result = await StatisticsOverviewSnapshot.read(directory: directory, resetHour: resetHour, calendar: calendar, reusing: previous)
        if !Task.isCancelled && read > Self.latestSharedRead {
            Self.latestSharedRead = read
            Self.sharedSnapshot = result
        }
        return result
    }
    /// Coalesce a shard's per-book notifications while retaining each reader's root notification.
    func scheduleReload(resetHour: Int = ReadingDay.resetHour) {
        scheduled?.cancel()
        reloadGeneration += 1 // Invalidate an already-running snapshot immediately.
        scheduled = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard let self else { return }
            await self.reload(resetHour: resetHour)
        }
    }
    func reload(resetHour: Int = ReadingDay.resetHour, directory: URL? = nil) async {
        reloadGeneration += 1
        let generation = reloadGeneration, calendar = StatisticsZone.calendar
        guard let directory = try? directory ?? BookStorage.getBooksDirectory() else { return }
        var result = await loadSnapshot(directory, resetHour, calendar)
        guard !Task.isCancelled, generation == reloadGeneration else { return }
        // Preserve one-time legacy migration/retained-history absorption. Normal reloads never
        // read/decode history on main; these paths run only for books not yet migrated.
        if result.needsAbsorb || !result.maintenance.isEmpty {
            if result.needsAbsorb { _ = try? StatisticsHistory.roots(directory: directory, onError: { _, _ in }) }
            for root in result.maintenance where FileManager.default.fileExists(atPath: root.path) { try? ReadingStatisticsStore.migrate(root: root) }
            result = await loadSnapshot(directory, resetHour, calendar)
            guard !Task.isCancelled, generation == reloadGeneration else { return }
        }
        books = result.books; snapshot = result; loaded = true
    }
}
