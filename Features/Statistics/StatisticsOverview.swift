import Foundation

struct BookReadingSummary: Identifiable {
    let book: BookMetadata
    let reading: [Statistics]
    let mangaText: [MangaTextStatistic]
    let finished: Bool
    var id: UUID { book.id }
    var isManga: Bool { book.resolvedContentType == .mokuro }
    var seconds: Double { reading.reduce(0.0) { StatisticsNumbers.adding($0, $1.readingTime) } }
    var characters: Int { isManga ? mangaText.reduce(0) { StatisticsNumbers.adding($0, $1.charactersRead) } : reading.reduce(0) { StatisticsNumbers.adding($0, $1.charactersRead) } }
    var pages: Int { isManga ? reading.reduce(0) { StatisticsNumbers.adding($0, $1.charactersRead) } : 0 }
    var devices: [DeviceReadingSummary] { StatisticsMath.devices(reading: reading, text: mangaText, isManga: isManga) }
    var days: [DailyReading] { StatisticsMath.days(reading: reading, text: isManga ? mangaText : nil) }
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

    static func devices(reading: [Statistics], text: [MangaTextStatistic], isManga: Bool) -> [DeviceReadingSummary] {
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
                lastRead: own.filter { $0.readingTime > 0 }.compactMap { date($0.dateKey) }.max(),
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

    static func date(_ key: String) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"; f.isLenient = false
        return f.date(from: key)
    }
    static func days(reading: [Statistics], text: [MangaTextStatistic]? = nil) -> [DailyReading] {
        var result: [Date: DailyReading] = [:]
        for row in Statistics.merged(reading) {
            guard let date = date(row.dateKey) else { continue }
            var day = result[date] ?? DailyReading(date: date)
            day.seconds = StatisticsNumbers.adding(day.seconds, row.readingTime)
            if text == nil { day.characters = StatisticsNumbers.adding(day.characters, row.charactersRead) }
            result[date] = day
        }
        for row in MangaTextStatistic.merged(text ?? []) {
            guard let date = date(row.dateKey) else { continue }
            var day = result[date] ?? DailyReading(date: date)
            day.characters = StatisticsNumbers.adding(day.characters, row.charactersRead)
            result[date] = day
        }
        return result.values.filter { $0.seconds > 0 || $0.characters > 0 }.sorted { $0.date < $1.date }
    }
    static func combine(_ days: [DailyReading]) -> [DailyReading] {
        Dictionary(grouping: days, by: \.date).map { date, rows in
            DailyReading(date: date, seconds: rows.reduce(0.0) { StatisticsNumbers.adding($0, $1.seconds) }, characters: rows.reduce(0) { StatisticsNumbers.adding($0, $1.characters) })
        }.sorted { $0.date < $1.date }
    }
    static func streak(_ days: [DailyReading], goalMinutes: Int, now: Date = .now) -> (current: Int, longest: Int) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let eligible = Set(days.filter { $0.date <= today && $0.seconds >= Double(goalMinutes * 60) }.map(\.date))
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
    func reload() {
        guard let root = try? BookStorage.getBooksDirectory(), let library = try? BookStorage.loadAllBooks() else { return }
        books = library.compactMap { book in
            guard let folder = book.folder else { return nil }
            let url = root.appendingPathComponent(folder)
            let reading = ReadingStatisticsStore.reading(root: url)
            let text = book.resolvedContentType == .mokuro ? ReadingStatisticsStore.text(root: url) : []
            let bookmark = BookStorage.loadBookmark(root: url)
            let summary = BookReadingSummary(book: book, reading: reading, mangaText: text, finished: StatisticsMath.isFinished(bookmark: bookmark, info: BookStorage.loadBookInfo(root: url), isManga: book.resolvedContentType == .mokuro))
            return summary.seconds > 0 || summary.characters > 0 || summary.pages > 0 ? summary : nil
        }.sorted { $0.seconds > $1.seconds }
    }
}
