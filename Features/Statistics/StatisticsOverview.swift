import Foundation

/// A reading day is a local wall-clock date, never a fixed 24-hour offset (DST can change its length).
nonisolated enum ReadingDay {
    static let resetKey = "statistics.dayResetHour"
    static let goalKey = "statistics.dailyGoalMinutes"
    static var resetHour: Int { resetHour(defaults: .standard) }
    static func resetHour(defaults: UserDefaults) -> Int {
        defaults.object(forKey: resetKey) == nil ? 3 : min(23, max(0, defaults.integer(forKey: resetKey)))
    }
    static func date(at instant: Date, resetHour: Int, calendar: Calendar = .current) -> Date {
        let day = calendar.startOfDay(for: instant)
        return calendar.component(.hour, from: instant) < min(23, max(0, resetHour))
            ? calendar.date(byAdding: .day, value: -1, to: day)! : day
    }
    static func boundary(on day: Date, resetHour: Int, calendar: Calendar = .current) -> Date {
        calendar.date(bySettingHour: min(23, max(0, resetHour)), minute: 0, second: 0, of: calendar.startOfDay(for: day))!
    }
    private static func gregorian(_ calendar: Calendar) -> Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = calendar.timeZone; return value
    }
    static func key(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = gregorian(calendar); formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    static func parse(_ key: String, calendar: Calendar = .current) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = gregorian(calendar); formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard let date = formatter.date(from: key), self.key(date, calendar: calendar) == key else { return nil }
        return date
    }
    /// Hour keys deliberately have no zone: both clients interpret the reader's recorded local date/hour.
    static func hour(_ key: String, calendar: Calendar = .current) -> (date: Date, hour: Int)? {
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
        hour.hour < reset ? calendar.date(byAdding: .day, value: -1, to: hour.date)! : hour.date
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
    static func days(reading: [Statistics], text: [MangaTextStatistic]? = nil, resetHour: Int, calendar: Calendar = .current) -> [DailyReading] {
        let reset = min(23, max(0, resetHour)), rows = Statistics.merged(reading)
        var seconds: [Date: Double] = [:], shares: [String: [Date: Double]] = [:]
        for row in rows {
            guard let date = parse(row.dateKey, calendar: calendar), row.readingTime > 0 else { continue }
            let previous = calendar.date(byAdding: .day, value: -1, to: date)!
            let hours = reset == 0 ? [] : row.readingTimeByHour.compactMap { key, value -> (Date, Double)? in
                guard value.isFinite, value > 0, let hour = hour(key, calendar: calendar), hour.date == date || hour.date == previous else { return nil }
                return (hourDay(hour, reset: reset, calendar: calendar), value)
            }
            let known = hours.reduce(0.0) { StatisticsNumbers.adding($0, $1.1) }
            let scale = known > row.readingTime ? row.readingTime / known : 1
            func credit(_ day: Date, _ value: Double) {
                guard value > 0 else { return }
                seconds[day] = StatisticsNumbers.adding(seconds[day] ?? 0, value)
                shares[row.dateKey, default: [:]][day] = StatisticsNumbers.adding(shares[row.dateKey]?[day] ?? 0, value)
            }
            for (day, value) in hours { credit(day, value * scale) }
            credit(date, max(0, row.readingTime - known * scale))
        }
        var byDate: [String: Int] = [:]
        if let text {
            for row in MangaTextStatistic.merged(text) { byDate[row.dateKey] = StatisticsNumbers.adding(byDate[row.dateKey] ?? 0, row.charactersRead) }
        } else {
            for row in rows { byDate[row.dateKey] = StatisticsNumbers.adding(byDate[row.dateKey] ?? 0, row.charactersRead) }
        }
        var characters: [Date: Int] = [:]
        for (key, count) in byDate where count > 0 {
            guard let date = parse(key, calendar: calendar) else { continue }
            let dayShares = shares[key, default: [:]], total = dayShares.values.reduce(0.0, StatisticsNumbers.adding)
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
    static func streakHistory(_ rows: [Statistics], resetHour: Int, calendar: Calendar = .current) -> (days: [DailyReading], estimated: Bool) {
        let reset = min(23, max(0, resetHour))
        var result: [Date: Double] = [:], estimated = false
        func credit(_ day: Date, _ value: Double) { if value > 0 { result[day] = StatisticsNumbers.adding(result[day] ?? 0, value) } }
        for row in Statistics.merged(rows) {
            guard let date = parse(row.dateKey, calendar: calendar), row.readingTime > 0 else { continue }
            let hours = row.readingTimeByHour.compactMap { key, value -> (Date, Double)? in
                guard value.isFinite, value > 0, let hour = hour(key, calendar: calendar) else { return nil }
                return (hourDay(hour, reset: reset, calendar: calendar), value)
            }
            let known = hours.reduce(0.0) { StatisticsNumbers.adding($0, $1.1) }
            let scale = known > row.readingTime ? row.readingTime / known : 1
            for (day, value) in hours { credit(day, value * scale) }
            let unknown = max(0, row.readingTime - known)
            if unknown > 0.001 {
                credit(date, unknown)
                if reset > 0 { credit(calendar.date(byAdding: .day, value: -1, to: date)!, unknown); estimated = true }
            }
        }
        return (result.keys.sorted().map { DailyReading(date: $0, seconds: result[$0]!) }, estimated)
    }
}

struct BookReadingSummary: Identifiable {
    let book: BookMetadata
    let reading: [Statistics]
    let mangaText: [MangaTextStatistic]
    let finished: Bool
    var resetHour: Int = 3
    var id: UUID { book.id }
    var isManga: Bool { book.resolvedContentType == .mokuro }
    var seconds: Double { reading.reduce(0.0) { StatisticsNumbers.adding($0, $1.readingTime) } }
    var characters: Int { isManga ? mangaText.reduce(0) { StatisticsNumbers.adding($0, $1.charactersRead) } : reading.reduce(0) { StatisticsNumbers.adding($0, $1.charactersRead) } }
    var pages: Int { isManga ? reading.reduce(0) { StatisticsNumbers.adding($0, $1.charactersRead) } : 0 }
    var devices: [DeviceReadingSummary] { StatisticsMath.devices(reading: reading, text: mangaText, isManga: isManga, resetHour: resetHour) }
    var days: [DailyReading] { ReadingDay.days(reading: reading, text: isManga ? mangaText : nil, resetHour: resetHour) }
}

nonisolated struct DailyReading: Identifiable {
    let date: Date
    var seconds: Double = 0
    var characters: Int = 0
    var id: Date { date }
}

nonisolated struct DeviceReadingSummary: Identifiable {
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

    static func devices(reading: [Statistics], text: [MangaTextStatistic], isManga: Bool, resetHour: Int = 0) -> [DeviceReadingSummary] {
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
                lastRead: ReadingDay.days(reading: own, resetHour: resetHour).filter { $0.seconds > 0 }.map(\.date).max(),
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
    static func streak(_ days: [DailyReading], goalMinutes: Int, now: Date = .now, resetHour: Int = 0, calendar: Calendar = .current) -> (current: Int, longest: Int) {
        let today = ReadingDay.date(at: now, resetHour: resetHour, calendar: calendar)
        let eligible = Set(days.filter { $0.date <= today && $0.seconds >= Double(min(120, max(1, goalMinutes))) * 60 }.map(\.date))
        var cursor = eligible.contains(today) ? today : calendar.date(byAdding: .day, value: -1, to: today)!
        var current = 0
        while eligible.contains(cursor) { current += 1; cursor = calendar.date(byAdding: .day, value: -1, to: cursor)! }
        var longest = 0; var run = 0; var previous: Date?
        for date in eligible.sorted() {
            run = previous.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) } == date ? run + 1 : 1
            longest = max(longest, run); previous = date
        }
        return (current, longest)
    }
    static func duration(_ seconds: Double) -> String {
        let value = StatisticsNumbers.integer(seconds)
        if value >= 3600 { return "\(value / 3600)h \(value % 3600 / 60)m" }
        return "\(value / 60)m \(value % 60)s"
    }
}

@Observable @MainActor final class StatisticsOverview {
    var books: [BookReadingSummary] = []
    var days: [DailyReading] { StatisticsMath.combine(books.flatMap(\.days)) }
    var devices: [DeviceReadingSummary] { StatisticsMath.combineDevices(books.flatMap(\.devices)) }
    var streakHistory: (days: [DailyReading], estimated: Bool) {
        let histories = books.map { ReadingDay.streakHistory($0.reading, resetHour: $0.resetHour) }
        return (StatisticsMath.combine(histories.flatMap(\.days)), histories.contains { $0.estimated })
    }
    func reload(resetHour: Int = ReadingDay.resetHour) {
        guard let roots = try? StatisticsHistory.roots(onError: { _, _ in }) else { return }
        books = roots.compactMap { item in
            let book = StatisticsHistory.metadata(for: item), url = item.root
            let reading = ReadingStatisticsStore.reading(root: url)
            let isManga = ReadingStatisticsStore.contentType(root: url) == .mokuro
            let text = isManga ? ReadingStatisticsStore.text(root: url) : []
            var resolved = book; resolved.contentType = isManga ? .mokuro : .epub
            let finished = item.book == nil ? (StatisticsHistory.info(url)?.progress ?? 0) >= 0.999 : StatisticsMath.isFinished(bookmark: BookStorage.loadBookmark(root: url), info: BookStorage.loadBookInfo(root: url), isManga: isManga)
            let summary = BookReadingSummary(book: resolved, reading: reading, mangaText: text, finished: finished, resetHour: resetHour)
            return summary.seconds > 0 || summary.characters > 0 || summary.pages > 0 ? summary : nil
        }.sorted { $0.seconds == $1.seconds ? $0.id.uuidString < $1.id.uuidString : $0.seconds > $1.seconds }
    }
}
