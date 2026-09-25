import Foundation

struct BookReadingSummary: Identifiable {
    let book: BookMetadata
    let reading: [Statistics]
    let mangaText: [MangaTextStatistic]
    let finished: Bool
    var id: UUID { book.id }
    var isManga: Bool { book.resolvedContentType == .mokuro }
    var seconds: Double { reading.reduce(0) { $0 + $1.readingTime } }
    var characters: Int { isManga ? mangaText.reduce(0) { $0 + $1.charactersRead } : reading.reduce(0) { $0 + $1.charactersRead } }
    var pages: Int { isManga ? reading.reduce(0) { $0 + $1.charactersRead } : 0 }
    var days: [DailyReading] { StatisticsMath.days(reading: reading, text: isManga ? mangaText : nil) }
}

nonisolated struct DailyReading: Identifiable {
    let date: Date
    var seconds: Double = 0
    var characters: Int = 0
    var id: Date { date }
}

nonisolated enum StatisticsMath {
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
            day.seconds += row.readingTime
            if text == nil { day.characters += row.charactersRead }
            result[date] = day
        }
        for row in MangaTextStatistic.merged(text ?? []) {
            guard let date = date(row.dateKey) else { continue }
            var day = result[date] ?? DailyReading(date: date)
            day.characters += row.charactersRead
            result[date] = day
        }
        return result.values.sorted { $0.date < $1.date }
    }
    static func combine(_ days: [DailyReading]) -> [DailyReading] {
        Dictionary(grouping: days, by: \.date).map { date, rows in
            DailyReading(date: date, seconds: rows.reduce(0) { $0 + $1.seconds }, characters: rows.reduce(0) { $0 + $1.characters })
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
        let value = Int(max(0, seconds))
        if value >= 3600 { return "\(value / 3600)h \(value % 3600 / 60)m" }
        return "\(value / 60)m \(value % 60)s"
    }
}

@Observable @MainActor final class StatisticsOverview {
    var books: [BookReadingSummary] = []
    var days: [DailyReading] { StatisticsMath.combine(books.flatMap(\.days)) }
    func reload() {
        guard let root = try? BookStorage.getBooksDirectory(), let library = try? BookStorage.loadAllBooks() else { return }
        books = library.compactMap { book in
            guard let folder = book.folder else { return nil }
            let url = root.appendingPathComponent(folder)
            let reading = ReadingStatisticsStore.reading(root: url)
            let text = book.resolvedContentType == .mokuro ? ReadingStatisticsStore.text(root: url) : []
            let bookmark = BookStorage.loadBookmark(root: url)
            return BookReadingSummary(book: book, reading: reading, mangaText: text, finished: (bookmark?.progress ?? 0) >= 1)
        }.sorted { $0.seconds > $1.seconds }
    }
}
