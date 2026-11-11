import Foundation

nonisolated struct UsageSpan: Identifiable {
    let start: Date
    let end: Date
    let title: String
    let session: String
    let zone: TimeZone
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
    var firstActivityZone: TimeZone?
    var lastActivityZone: TimeZone?

    mutating func noteActivity(_ instant: Date, zone: TimeZone) {
        if firstActivity.map({ instant < $0 }) ?? true {
            firstActivity = instant; firstActivityZone = zone
        }
        if lastActivity.map({ instant > $0 }) ?? true {
            lastActivity = instant; lastActivityZone = zone
        }
    }

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
        let ordered = events.sorted { $0.at < $1.at }
        var opened: [String: UsageEvent] = [:], last: [String: Date] = [:]
        var words: [Date: [String: (Int, Int)]] = [:]
        func matchingDate(_ date: Date, from source: Calendar, to target: Calendar) -> Date? {
            guard let day = target.date(from: source.dateComponents([.year, .month, .day], from: date)) else { return nil }
            return target.startOfDay(for: day)
        }
        func addSpan(from: Date, to: Date, event: UsageEvent, zone: TimeZone) {
            let source = StatisticsZone.calendar(zone: zone)
            guard let firstLocal = matchingDate(first, from: calendar, to: source),
                  let lastLocal = matchingDate(lastDay, from: calendar, to: source) else { return }
            let start = ReadingDay.boundary(on: firstLocal, resetHour: resetHour, calendar: source)
            let end = ReadingDay.boundary(on: ReadingDay.shift(lastLocal, by: 1, calendar: source), resetHour: resetHour, calendar: source)
            let a = max(start, from), b = min(end, to)
            guard b > a else { return }
            var day = ReadingDay.date(at: a, resetHour: resetHour, calendar: source)
            while day <= lastLocal {
                let next = ReadingDay.shift(day, by: 1, calendar: source)
                let spanStart = max(a, ReadingDay.boundary(on: day, resetHour: resetHour, calendar: source))
                let spanEnd = min(b, ReadingDay.boundary(on: next, resetHour: resetHour, calendar: source))
                if spanEnd > spanStart, let label = matchingDate(day, from: source, to: calendar), var summary = result[label] {
                    summary.spans.append(UsageSpan(start: spanStart, end: spanEnd, title: event.bookTitle ?? "Untitled",
                        session: event.session ?? "", zone: zone))
                    summary.noteActivity(spanStart, zone: zone)
                    summary.noteActivity(spanEnd, zone: zone)
                    result[label] = summary
                }
                if spanEnd >= b || next <= day { break }
                day = next
            }
        }
        for (index, event) in ordered.enumerated() {
            let session = event.session ?? "", at = event.date
            last[session] = at
            if event.type == .started { opened[session] = event }
            if event.type == .stopped {
                let active = opened[session]
                let start = event.startedAt == nil || active?.at == event.startedAt ? active : nil
                if start != nil { opened[session] = nil }
                let began = event.startedAt.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? start?.date ?? at
                let zone = StatisticsZone.zone(event.startedTimeZone) ?? start?.recordedZone ?? event.recordedZone
                addSpan(from: began, to: at, event: event, zone: zone)
            }
            let zone = event.instantZone
            let source = StatisticsZone.calendar(zone: zone)
            let localDay = ReadingDay.date(at: at, resetHour: resetHour, calendar: source)
            guard let day = matchingDate(localDay, from: source, to: calendar), var summary = result[day] else { continue }
            summary.noteActivity(at, zone: zone)
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
        for (session, event) in opened {
            addSpan(from: event.date, to: last[session] ?? event.date, event: event, zone: event.recordedZone)
        }
        for day in dates {
            var summary = result[day]!
            summary.spans.sort { $0.start < $1.start }
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
        let snapshot = await log.read(now: now, resetHour: resetHour)
        let calendar = StatisticsZone.calendar
        let readingToday = ReadingDay.date(at: now, resetHour: resetHour, calendar: calendar)
        let summaries = await Task.detached {
            let dates = (0...92).map { ReadingDay.shift(readingToday, by: -$0, calendar: calendar) }
            return UsageDay.summarize(snapshot.events, dates: dates, calendar: calendar, resetHour: resetHour)
        }.value
        guard generation == reloadGeneration else { return }
        events = snapshot.events
        firstDay = snapshot.firstDayKey.flatMap { ReadingDay.parse($0, calendar: calendar) }
        counts = summaries
        today = summaries[readingToday] ?? UsageDay(date: readingToday)
    }

    func values(_ keyPath: KeyPath<UsageDay, Int>) -> [Date: Double] {
        counts.mapValues { Double($0[keyPath: keyPath]) }
    }
}
