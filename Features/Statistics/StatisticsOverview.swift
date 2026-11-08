import Foundation

/// A reading day is a local wall-clock date, never a fixed 24-hour offset (DST can change its length).
nonisolated enum ReadingDay {
    static var calendar: Calendar { StatisticsZone.calendar }
    static let resetKey = "statistics.dayResetHour"
    static let goalKey = "statistics.dailyGoalMinutes"
    static var resetHour: Int { resetHour(defaults: .standard) }
    static func resetHour(defaults: UserDefaults) -> Int {
        defaults.object(forKey: resetKey) == nil ? 3 : min(23, max(0, defaults.integer(forKey: resetKey)))
    }
    static func date(at instant: Date, resetHour: Int, calendar: Calendar = StatisticsZone.calendar) -> Date {
        let day = calendar.startOfDay(for: instant)
        return calendar.component(.hour, from: instant) < min(23, max(0, resetHour))
            ? shift(day, by: -1, calendar: calendar) : day
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
    static func parse(_ key: String, calendar: Calendar = StatisticsZone.calendar) -> Date? {
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

    static func hourDay(_ hour: (date: Date, hour: Int), reset: Int, calendar: Calendar) -> Date {
        hour.hour < reset ? shift(hour.date, by: -1, calendar: calendar) : hour.date
    }
    static func hours(from start: Date, to end: Date, calendar: Calendar = .current) -> [String: Double] {
        guard end > start else { return [:] }
        var result: [String: Double] = [:], cursor = start
        while cursor < end {
            guard let interval = calendar.dateInterval(of: .hour, for: cursor), interval.end > cursor else { break }
            let next = min(end, interval.end)
            let key = key(cursor, calendar: calendar) + String(format: "T%02d:00", calendar.component(.hour, from: cursor))
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
    static func days(reading: [Statistics], text: [MangaTextStatistic]? = nil, resetHour: Int, calendar: Calendar = StatisticsZone.calendar) -> [DailyReading] {
        let reset = min(23, max(0, resetHour)), rows = Statistics.merged(reading)
        var seconds: [Date: Double] = [:], shares: [String: [Date: Double]] = [:], dateShares: [String: [Date: Double]] = [:]
        for row in rows {
            guard let date = parse(row.dateKey, calendar: calendar), row.readingTime > 0 else { continue }
            let previous = shift(date, by: -1, calendar: calendar)
            let recorded = row.recordedZone(target: calendar.timeZone)
            let convert = recorded != nil && recorded != calendar.timeZone
            let hours = reset == 0 && !convert ? [] : row.readingTimeByHour.compactMap { key, value -> (Date, Double)? in
                guard value.isFinite, value > 0, let hour = hour(key, calendar: calendar), hour.date == date || hour.date == previous else { return nil }
                guard let moved = StatisticsZone.convert(key, from: recorded, to: calendar) else { return nil }
                return (hourDay(moved, reset: reset, calendar: calendar), value)
            }
            let known = hours.reduce(0.0) { StatisticsNumbers.adding($0, $1.1) }
            let scale = known > row.readingTime ? row.readingTime / known : 1
            func credit(_ day: Date, _ value: Double) {
                guard value > 0 else { return }
                seconds[day] = StatisticsNumbers.adding(seconds[day] ?? 0, value)
                shares[row.key, default: [:]][day] = StatisticsNumbers.adding(shares[row.key]?[day] ?? 0, value)
                dateShares[row.dateKey, default: [:]][day] = StatisticsNumbers.adding(dateShares[row.dateKey]?[day] ?? 0, value)
            }
            for (day, value) in hours { credit(day, value * scale) }
            credit(date, max(0, row.readingTime - known * scale))
        }
        var byDate: [String: Int] = [:]
        if let text {
            for row in MangaTextStatistic.merged(text) { byDate[row.key] = StatisticsNumbers.adding(byDate[row.key] ?? 0, row.charactersRead) }
        } else {
            for row in rows { byDate[row.key] = StatisticsNumbers.adding(byDate[row.key] ?? 0, row.charactersRead) }
        }
        var characters: [Date: Int] = [:]
        for (key, count) in byDate where count > 0 {
            let dateKey = String(key.prefix(10))
            guard let date = parse(dateKey, calendar: calendar) else { continue }
            let dayShares = shares[key] ?? dateShares[dateKey] ?? [:], total = dayShares.values.reduce(0.0, StatisticsNumbers.adding)
            if total == 0 { characters[date] = StatisticsNumbers.adding(characters[date] ?? 0, count); continue }
            let exact = dayShares.mapValues { min(Double(count), Double(count) * ($0 / total)) }
            var allocations = exact.mapValues { min(count, StatisticsNumbers.integer($0)) }
            var remaining = count - allocations.values.reduce(0, StatisticsNumbers.adding)
            for day in exact.keys.sorted(by: {
                let first = exact[$0]! - Double(allocations[$0]!), second = exact[$1]! - Double(allocations[$1]!)
                return first == second ? $0 < $1 : first > second
            }) where remaining > 0 {
                allocations[day]! += 1; remaining -= 1
            }
            for (day, value) in allocations { characters[day] = StatisticsNumbers.adding(characters[day] ?? 0, value) }
        }
        return Set(seconds.keys).union(characters.keys).sorted().compactMap { date in
            let day = DailyReading(date: date, seconds: seconds[date] ?? 0, characters: characters[date] ?? 0)
            return day.seconds > 0 || day.characters > 0 ? day : nil
        }
    }
    /// Missing hour evidence receives streak credit on both plausible dates, never duplicated totals.
    static func streakHistory(_ rows: [Statistics], resetHour: Int, calendar: Calendar = StatisticsZone.calendar) -> (days: [DailyReading], estimated: Bool) {
        let reset = min(23, max(0, resetHour))
        var result: [Date: Double] = [:], estimated = false
        func credit(_ day: Date, _ value: Double) { if value > 0 { result[day] = StatisticsNumbers.adding(result[day] ?? 0, value) } }
        for row in Statistics.merged(rows) {
            guard let date = parse(row.dateKey, calendar: calendar), row.readingTime > 0 else { continue }
            let recorded = row.recordedZone(target: calendar.timeZone)
            let hours = row.readingTimeByHour.compactMap { key, value -> (Date, Double)? in
                guard value.isFinite, value > 0, let hour = StatisticsZone.convert(key, from: recorded, to: calendar) else { return nil }
                return (hourDay(hour, reset: reset, calendar: calendar), value)
            }
            let known = hours.reduce(0.0) { StatisticsNumbers.adding($0, $1.1) }
            let scale = known > row.readingTime ? row.readingTime / known : 1
            for (day, value) in hours { credit(day, value * scale) }
            let unknown = max(0, row.readingTime - known)
            if unknown > 0.001 {
                credit(date, unknown)
                if reset > 0 { credit(shift(date, by: -1, calendar: calendar), unknown); estimated = true }
            }
        }
        return (result.keys.sorted().map { DailyReading(date: $0, seconds: result[$0]!) }, estimated)
    }
}

nonisolated struct BookReadingSummary: Identifiable, Sendable {
    let book: BookMetadata
    let reading: [Statistics]
    let mangaText: [MangaTextStatistic]
    let finished: Bool
    let resetHour: Int
    let seconds: Double
    let characters: Int
    let pages: Int
    let devices: [DeviceReadingSummary]
    let days: [DailyReading]
    let streakHistory: (days: [DailyReading], estimated: Bool)
    var id: UUID { book.id }
    var isManga: Bool { book.resolvedContentType == .mokuro }

    init(book: BookMetadata, reading: [Statistics], mangaText: [MangaTextStatistic], finished: Bool,
         resetHour: Int = 3, calendar: Calendar = StatisticsZone.calendar) {
        self.book = book; self.reading = reading; self.mangaText = mangaText
        self.finished = finished; self.resetHour = resetHour
        let isManga = book.resolvedContentType == .mokuro
        seconds = reading.reduce(0.0) { StatisticsNumbers.adding($0, $1.readingTime) }
        characters = isManga ? mangaText.reduce(0) { StatisticsNumbers.adding($0, $1.charactersRead) } : reading.reduce(0) { StatisticsNumbers.adding($0, $1.charactersRead) }
        pages = isManga ? reading.reduce(0) { StatisticsNumbers.adding($0, $1.charactersRead) } : 0
        days = ReadingDay.days(reading: reading, text: isManga ? mangaText : nil, resetHour: resetHour, calendar: calendar)
        devices = StatisticsMath.devices(reading: reading, text: mangaText, isManga: isManga, resetHour: resetHour, calendar: calendar)
        streakHistory = ReadingDay.streakHistory(reading, resetHour: resetHour, calendar: calendar)
    }
}

nonisolated struct DailyReading: Identifiable, Sendable {
    let date: Date
    var seconds: Double = 0
    var characters: Int = 0
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

    static func devices(reading: [Statistics], text: [MangaTextStatistic], isManga: Bool, resetHour: Int = 0, calendar: Calendar = StatisticsZone.calendar) -> [DeviceReadingSummary] {
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
                lastRead: ReadingDay.days(reading: own, resetHour: resetHour, calendar: calendar).filter { $0.seconds > 0 }.map(\.date).max(),
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
            DailyReading(date: date, seconds: rows.reduce(0.0) { StatisticsNumbers.adding($0, $1.seconds) }, characters: rows.reduce(0) { StatisticsNumbers.adding($0, $1.characters) })
        }.sorted { $0.date < $1.date }
    }
    static func streak(_ days: [DailyReading], goalMinutes: Int, now: Date = .now, resetHour: Int = 0, calendar: Calendar = StatisticsZone.calendar) -> (current: Int, longest: Int) {
        let today = ReadingDay.date(at: now, resetHour: resetHour, calendar: calendar)
        let eligible = Set(days.filter { $0.date <= today && $0.seconds >= Double(min(120, max(1, goalMinutes))) * 60 }.map(\.date))
        var cursor = eligible.contains(today) ? today : ReadingDay.shift(today, by: -1, calendar: calendar)
        var current = 0
        while eligible.contains(cursor) { current += 1; cursor = ReadingDay.shift(cursor, by: -1, calendar: calendar) }
        var longest = 0; var run = 0; var previous: Date?
        for date in eligible.sorted() {
            run = previous.map { ReadingDay.shift($0, by: 1, calendar: calendar) } == date ? run + 1 : 1
            longest = max(longest, run); previous = date
        }
        return (current, longest)
    }
    /// Clock-like, for playback positions; reading totals use `readingTime`.
    static func duration(_ seconds: Double) -> String {
        let value = StatisticsNumbers.integer(seconds)
        if value >= 3600 { return "\(value / 3600)h \(value % 3600 / 60)m" }
        return "\(value / 60)m \(value % 60)s"
    }
    /// Hours and minutes, with seconds only under a minute: "0m", "45s", "32m", "6h", "2h 14m".
    static func readingTime(_ seconds: Double, locale: Locale = .current) -> String {
        let value = StatisticsNumbers.integer(seconds)
        let style = Duration.UnitsFormatStyle(allowedUnits: value == 0 || value >= 60 ? [.hours, .minutes] : [.seconds], width: .narrow).locale(locale)
        return Duration.seconds(value < 60 ? value : value / 60 * 60).formatted(style)
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

/// File IO, JSON decoding and calendar aggregation belong to a background snapshot. Rendering
/// reads only the finished arrays, including book rows, instead of re-parsing every historic day.
nonisolated struct StatisticsOverviewSnapshot: Sendable {
    var books: [BookReadingSummary]
    var days: [DailyReading]
    var devices: [DeviceReadingSummary]
    var streakHistory: (days: [DailyReading], estimated: Bool)
    var maintenance: [URL] = []
    var needsAbsorb = false
    init(books: [BookReadingSummary]) {
        self.books = books
        days = StatisticsMath.combine(books.flatMap(\.days))
        devices = StatisticsMath.combineDevices(books.flatMap(\.devices))
        let histories = books.map(\.streakHistory)
        streakHistory = (StatisticsMath.combine(histories.flatMap(\.days)), histories.contains { $0.estimated })
    }
    private struct FinishInfo: Decodable { let characterCount: Int }
    @concurrent static func read(directory: URL, resetHour: Int, calendar: Calendar) async -> Self {
        let disk = await HttpStatisticsDisk.read(booksDirectory: directory, stateFile: HttpReadingStatisticsSync.stateFile)
        let decoder = JSONDecoder(), manager = FileManager.default
        func load<T: Decodable>(_ type: T.Type, root: URL, name: String) -> T? {
            (try? Data(contentsOf: root.appendingPathComponent(name))).flatMap { try? decoder.decode(type, from: $0) }
        }
        var books: [BookReadingSummary] = []
        for item in disk.roots {
            guard !Task.isCancelled else { break }
            var book = StatisticsHistory.metadata(for: item)
            let isManga = item.book == nil ? item.contentType == .mokuro : ContentType.detect(bookDir: item.root) == .mokuro
            book.contentType = isManga ? .mokuro : .epub
            let reading = Statistics.merged(load([Statistics].self, root: item.root, name: FileNames.statistics) ?? [])
            let text = isManga ? MangaTextStatistic.merged(load([MangaTextStatistic].self, root: item.root, name: FileNames.mangaStatistics) ?? []) : []
            let finished: Bool
            if item.book == nil { finished = (load(StatisticsHistoryInfo.self, root: item.root, name: "history.json")?.progress ?? 0) >= 0.999 }
            else if let bookmark = load(Bookmark.self, root: item.root, name: FileNames.bookmark) {
                if let total = load(FinishInfo.self, root: item.root, name: FileNames.bookinfo)?.characterCount, total > 0 {
                    finished = Double(bookmark.characterCount) / Double(total) >= 0.999
                } else { finished = isManga && bookmark.progress >= 0.999 }
            } else { finished = false }
            let summary = BookReadingSummary(book: book, reading: reading, mangaText: text, finished: finished, resetHour: resetHour, calendar: calendar)
            if summary.seconds > 0 || summary.characters > 0 || summary.pages > 0 { books.append(summary) }
        }
        books.sort { $0.seconds == $1.seconds ? $0.id.uuidString < $1.id.uuidString : $0.seconds > $1.seconds }
        var snapshot = Self(books: books)
        snapshot.needsAbsorb = disk.needsAbsorb
        snapshot.maintenance = disk.roots.filter { !manager.fileExists(atPath: $0.root.appendingPathComponent(ReadingStatisticsStore.migration).path) }.map(\.root)
        return snapshot
    }
}

@Observable @MainActor final class StatisticsOverview {
    var books: [BookReadingSummary] = [] { didSet { snapshot = nil } }
    private var snapshot: StatisticsOverviewSnapshot?
    private var scheduled: Task<Void, Never>?
    private var reloadGeneration = 0
    private let loadSnapshot: @Sendable (URL, Int, Calendar) async -> StatisticsOverviewSnapshot
    private(set) var loaded = false
    init(loadSnapshot: @escaping @Sendable (URL, Int, Calendar) async -> StatisticsOverviewSnapshot = {
        await StatisticsOverviewSnapshot.read(directory: $0, resetHour: $1, calendar: $2)
    }) { self.loadSnapshot = loadSnapshot }
    var days: [DailyReading] { snapshot?.days ?? StatisticsMath.combine(books.flatMap(\.days)) }
    var devices: [DeviceReadingSummary] { snapshot?.devices ?? StatisticsMath.combineDevices(books.flatMap(\.devices)) }
    var streakHistory: (days: [DailyReading], estimated: Bool) {
        if let snapshot { return snapshot.streakHistory }
        let histories = books.map(\.streakHistory)
        return (StatisticsMath.combine(histories.flatMap(\.days)), histories.contains { $0.estimated })
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
