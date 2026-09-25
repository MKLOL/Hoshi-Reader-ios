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
    static func summarize(_ events: [UsageEvent], date: Date, calendar: Calendar = .current) -> Self {
        let start = calendar.startOfDay(for: date), end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))!
        var result = Self(date: start)
        let ordered = events.sorted { $0.at < $1.at }
        var opened: [String: UsageEvent] = [:], last: [String: Date] = [:]
        var words: [String: (Int, Int)] = [:]
        func addSpan(from: Date, to: Date, event: UsageEvent) {
            let a = max(start, from), b = min(end, to)
            if b > a { result.spans.append(UsageSpan(start: a, end: b, title: event.bookTitle ?? "Untitled", session: event.session ?? "")) }
        }
        for (index, event) in ordered.enumerated() {
            let session = event.session ?? "", at = event.date
            last[session] = at
            if event.type == .started { opened[session] = event }
            if event.type == .stopped {
                let began = event.startedAt.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? opened[session]?.date ?? at
                opened[session] = nil; addSpan(from: began, to: at, event: event)
            }
            guard at >= start, at < end else { continue }
            result.firstActivity = result.firstActivity ?? at
            result.lastActivity = at
            switch event.type {
            case .opened: result.sessions += 1
            case .page: if event.source != "jump" { result.pages += 1 }
            case .lookup:
                result.lookups += 1
                if event.contentType == "manga", event.source == "page" { result.mangaLookups += 1 }
                if event.outcome != "not-found", let word = event.term ?? event.text, !word.isEmpty { words[word] = ((words[word]?.0 ?? 0) + 1, index) }
            case .revealed: result.revealed += 1
            case .translated: result.translated += 1
            case .screenshot: result.screenshots += 1
            case .copied: result.copied += 1
            default: break
            }
        }
        for (session, event) in opened { addSpan(from: event.date, to: last[session] ?? event.date, event: event) }
        result.spans.sort { $0.start < $1.start }
        if let spanStart = result.spans.first?.start { result.firstActivity = min(result.firstActivity ?? spanStart, spanStart) }
        result.repeated = words.filter { $0.value.0 > 1 }.sorted { $0.value.0 == $1.value.0 ? $0.value.1 > $1.value.1 : $0.value.0 > $1.value.0 }.prefix(5).map { ($0.key, $0.value.0) }
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
    static func series(values: [Date: Double], denominators: [Date: Double]? = nil, days: Int, since: Date? = nil, now: Date = .now) -> [ReadingTrendPoint] {
        let calendar = Calendar.current, today = Calendar.current.startOfDay(for: now)
        guard days > 0 else { return [] }
        return (0..<days).reversed().compactMap { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: today)!
            if let since, date < since { return nil }
            let window = (0..<3).map { calendar.date(byAdding: .day, value: -$0, to: date)! }.filter { since == nil || $0 >= since! }
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
    var today = UsageDay(date: Calendar.current.startOfDay(for: .now))
    private var counts: [Date: UsageDay] = [:]
    private var reloadGeneration = 0
    func reload() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        let snapshot = await UsageLog.shared.read()
        let summaries = await Task.detached {
            Dictionary(grouping: snapshot.events, by: { Calendar.current.startOfDay(for: $0.date) })
                .mapValues { UsageDay.summarize($0, date: $0[0].date) }
        }.value
        guard generation == reloadGeneration else { return }
        events = snapshot.events; firstDay = snapshot.firstDay; counts = summaries
        today = UsageDay.summarize(events, date: .now)
    }
    func values(_ keyPath: KeyPath<UsageDay, Int>) -> [Date: Double] {
        counts.mapValues { Double($0[keyPath: keyPath]) }
    }
}
