import Foundation

nonisolated struct UsageSpan: Identifiable {
    let start: Date
    let end: Date
    let title: String
    let session: String
    var id: String { session + "|" + String(start.timeIntervalSince1970) }
    var seconds: Double { max(0, end.timeIntervalSince(start)) }
}
nonisolated struct UsageDay {
    let date: Date
    var sessions = 0, pages = 0, lookups = 0, mangaLookups = 0, revealed = 0, translated = 0, screenshots = 0, copied = 0
    var repeated: [(word: String, count: Int)] = []
    var spans: [UsageSpan] = []
    var firstActivity: Date?
    var lastActivity: Date?
    static func summarize(_ events: [UsageEvent], date: Date, calendar: Calendar = .current, resetHour: Int = 0) -> Self {
        let day = calendar.startOfDay(for: date)
        return summarize(events, dates: [day], calendar: calendar, resetHour: resetHour)[day] ?? Self(date: day)
    }

    /// Resolve sessions and order events once for the whole history. Only a span crossing a
    /// reading-day boundary is split; a large usage log is never rescanned for every chart day.
    static func summarize(_ events: [UsageEvent], dates: [Date], calendar: Calendar = .current, resetHour: Int = 0) -> [Date: Self] {
        let dates = Set(dates.map { calendar.startOfDay(for: $0) }).sorted()
        guard let first = dates.first, let lastDay = dates.last else { return [:] }
        var result = Dictionary(uniqueKeysWithValues: dates.map { ($0, Self(date: $0)) })
        let start = ReadingDay.boundary(on: first, resetHour: resetHour, calendar: calendar)
        let end = ReadingDay.boundary(on: ReadingDay.shift(lastDay, by: 1, calendar: calendar), resetHour: resetHour, calendar: calendar)
        let ordered = events.sorted { $0.at < $1.at }
        var opened: [String: UsageEvent] = [:], last: [String: Date] = [:]
        var words: [Date: [String: (Int, Int)]] = [:]
        func addSpan(from: Date, to: Date, event: UsageEvent) {
            let a = max(start, from), b = min(end, to)
            guard b > a else { return }
            var day = ReadingDay.date(at: a, resetHour: resetHour, calendar: calendar)
            while day <= lastDay {
                let next = ReadingDay.shift(day, by: 1, calendar: calendar)
                let spanStart = max(a, ReadingDay.boundary(on: day, resetHour: resetHour, calendar: calendar))
                let spanEnd = min(b, ReadingDay.boundary(on: next, resetHour: resetHour, calendar: calendar))
                if spanEnd > spanStart, result[day] != nil {
                    result[day]!.spans.append(UsageSpan(start: spanStart, end: spanEnd, title: event.bookTitle ?? "Untitled", session: event.session ?? ""))
                }
                if spanEnd >= b { break }
                day = next
            }
        }
        for (index, event) in ordered.enumerated() {
            let session = event.session ?? "", at = event.date
            last[session] = at
            if event.type == .started { opened[session] = event }
            if event.type == .stopped {
                let began = event.startedAt.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? opened[session]?.date ?? at
                opened[session] = nil; addSpan(from: began, to: at, event: event)
            }
            let day = ReadingDay.date(at: at, resetHour: resetHour, calendar: calendar)
            guard at >= start, at < end, var summary = result[day] else { continue }
            summary.firstActivity = summary.firstActivity ?? at
            summary.lastActivity = at
            switch event.type {
            case .opened: summary.sessions += 1
            case .page: if event.source != "jump" { summary.pages += 1 }
            case .lookup:
                summary.lookups += 1
                if event.contentType == "manga", event.source == "page" { summary.mangaLookups += 1 }
                if event.outcome != "not-found", let word = event.term ?? event.text, !word.isEmpty {
                    let count = (words[day]?[word]?.0 ?? 0) + 1
                    words[day, default: [:]][word] = (count, index)
                }
            case .revealed: summary.revealed += 1
            case .translated: summary.translated += 1
            case .screenshot: summary.screenshots += 1
            case .copied: summary.copied += 1
            default: break
            }
            result[day] = summary
        }
        for (session, event) in opened { addSpan(from: event.date, to: last[session] ?? event.date, event: event) }
        for day in dates {
            var summary = result[day]!
            summary.spans.sort { $0.start < $1.start }
            if let spanStart = summary.spans.first?.start { summary.firstActivity = min(summary.firstActivity ?? spanStart, spanStart) }
            summary.repeated = (words[day] ?? [:]).filter { $0.value.0 > 1 }.sorted { $0.value.0 == $1.value.0 ? $0.value.1 > $1.value.1 : $0.value.0 > $1.value.0 }.prefix(5).map { ($0.key, $0.value.0) }
            result[day] = summary
        }
        return result
    }
}

nonisolated struct ReadingTrendPoint: Identifiable {
    let date: Date
    let value: Double
    let average: Double
    var id: Date { date }
}
nonisolated enum ReadingTrends {
    /// A ratio's average is the ratio of the window sums, never an average of daily ratios.
    static func series(values: [Date: Double], denominators: [Date: Double]? = nil, days: Int, since: Date? = nil, now: Date = .now, resetHour: Int = 0, calendar: Calendar = .current) -> [ReadingTrendPoint] {
        let today = ReadingDay.date(at: now, resetHour: resetHour, calendar: calendar)
        guard days > 0 else { return [] }
        return (0..<days).reversed().compactMap { offset in
            let date = ReadingDay.shift(today, by: -offset, calendar: calendar)
            if let since, date < since { return nil }
            let window = (0..<3).map { ReadingDay.shift(date, by: -$0, calendar: calendar) }.filter { since == nil || $0 >= since! }
            let numerator = window.reduce(0) { $0 + (values[$1] ?? 0) }
            let daily = values[date] ?? 0
            if let denominators {
                let denominator = window.reduce(0) { $0 + (denominators[$1] ?? 0) }
                let count = denominators[date] ?? 0
                return ReadingTrendPoint(date: date, value: count > 0 ? daily / count : 0, average: denominator > 0 ? numerator / denominator : 0)
            }
            return ReadingTrendPoint(date: date, value: daily, average: window.isEmpty ? 0 : numerator / Double(window.count))
        }
    }
}

@Observable @MainActor final class UsageStatisticsModel {
    var events: [UsageEvent] = []
    var firstDay: Date?
    var today = UsageDay(date: ReadingDay.date(at: .now, resetHour: ReadingDay.resetHour))
    private var counts: [Date: UsageDay] = [:]
    private var reloadGeneration = 0
    func reload(resetHour: Int = ReadingDay.resetHour, now: Date = .now, log: UsageLog = .shared) async {
        reloadGeneration += 1
        let generation = reloadGeneration
        let snapshot = await log.read(now: now)
        let calendar = StatisticsZone.calendar
        let readingToday = ReadingDay.date(at: now, resetHour: resetHour, calendar: calendar)
        let summaries = await Task.detached {
            let dates = (0...92).map { ReadingDay.shift(readingToday, by: -$0, calendar: calendar) }
            return UsageDay.summarize(snapshot.events, dates: dates, calendar: calendar, resetHour: resetHour)
        }.value
        guard generation == reloadGeneration else { return }
        events = snapshot.events
        firstDay = snapshot.firstDay.map { ReadingDay.date(at: $0, resetHour: resetHour, calendar: calendar) }
        counts = summaries
        today = summaries[readingToday] ?? UsageDay(date: readingToday)
    }

    func values(_ keyPath: KeyPath<UsageDay, Int>) -> [Date: Double] {
        counts.mapValues { Double($0[keyPath: keyPath]) }
    }
}
