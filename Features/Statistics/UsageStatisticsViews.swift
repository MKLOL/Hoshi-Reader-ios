import SwiftUI
import Charts

struct UsageTodaySection: View {
    let reading: DailyReading
    let usage: UsageDay
    var body: some View {
        Section("Today") {
            LabeledContent("Reading time", value: StatisticsMath.duration(reading.seconds))
            LabeledContent("Characters", value: reading.characters.formatted())
            LabeledContent("Words looked up", value: usage.lookups.formatted())
            LabeledContent("Pages turned", value: usage.pages.formatted())
            LabeledContent("Reading sessions", value: usage.sessions.formatted())
            LabeledContent("Bubbles revealed", value: usage.revealed.formatted())
            LabeledContent("Bubble translations", value: usage.translated.formatted())
            LabeledContent("Screenshot translations", value: usage.screenshots.formatted())
            if !usage.spans.isEmpty {
                Chart(usage.spans) { span in
                    BarMark(xStart: .value("Start", span.start), xEnd: .value("End", span.end), y: .value("Book", span.title))
                        .accessibilityLabel("\(span.title), \(StatisticsMath.duration(span.seconds))")
                }.frame(height: CGFloat(max(1, Set(usage.spans.map(\.title)).count)) * 35 + 30)
                ForEach(usage.spans) { span in
                    VStack(alignment: .leading) {
                        Text(span.title)
                        Text("\(span.start.formatted(date: .omitted, time: .shortened))–\(span.end.formatted(date: .omitted, time: .shortened)) · \(StatisticsMath.duration(span.seconds))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !usage.repeated.isEmpty {
                Text("Words looked up more than once").font(.headline)
                ForEach(usage.repeated, id: \.word) { word in LabeledContent(word.word, value: word.count.formatted()) }
            }
            Text("Lookups, bubbles and the timeline count this device. The reading log stays on this device and is excluded from sync and backups.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct StatisticsTrendsSections: View {
    let reading: [DailyReading]
    let usage: UsageStatisticsModel
    @State private var days = 30
    private func series(_ values: [Date: Double], denominator: [Date: Double]? = nil, local: Bool = false) -> [ReadingTrendPoint] {
        if local && usage.firstDay == nil { return [] }
        return ReadingTrends.series(values: values, denominators: denominator, days: days, since: local ? usage.firstDay : nil)
    }
    var body: some View {
        Section {
            Picker("Period", selection: $days) {
                ForEach([14, 30, 90], id: \.self) { Text("\($0) days").tag($0) }
            }.pickerStyle(.segmented)
            Text("Bars show each day; the line shows the trailing 3-day average. Tap a day for details.").font(.caption).foregroundStyle(.secondary)
        }
        ReadingTrendChart(title: "Reading time (minutes)", points: series(Dictionary(uniqueKeysWithValues: reading.map { ($0.date, $0.seconds / 60) })))
        ReadingTrendChart(title: "Characters read", points: series(Dictionary(uniqueKeysWithValues: reading.map { ($0.date, Double($0.characters)) })))
        ReadingTrendChart(title: "Words looked up", points: series(usage.values(\.lookups), local: true))
        ReadingTrendChart(title: "Lookups per manga bubble", points: series(usage.values(\.mangaLookups), denominator: usage.values(\.revealed), local: true))
        ReadingTrendChart(title: "Translations pressed", points: series(usage.values(\.translated).merging(usage.values(\.screenshots), uniquingKeysWith: +), local: true))
        ReadingTrendChart(title: "Translations per manga bubble", points: series(usage.values(\.translated), denominator: usage.values(\.revealed), local: true))
        Section { Text("Lookup and translation trends count this device, starting when its private reading log began. Per-bubble averages divide the three-day totals.").font(.caption).foregroundStyle(.secondary) }
    }
}

private struct ReadingTrendChart: View {
    let title: String
    let points: [ReadingTrendPoint]
    @State private var selected: Date?
    private var point: ReadingTrendPoint? {
        selected.flatMap { date in points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) } }
    }
    var body: some View {
        Section(title) {
            if points.isEmpty { Text("No reading log yet.").foregroundStyle(.secondary) }
            else {
                Chart(points) { point in
                    BarMark(x: .value("Day", point.date, unit: .day), y: .value("Value", point.value))
                        .foregroundStyle(Color.accentColor.opacity(0.5))
                    LineMark(x: .value("Day", point.date, unit: .day), y: .value("3-day average", point.average))
                        .foregroundStyle(.orange).lineStyle(StrokeStyle(lineWidth: 2))
                }
                .chartXSelection(value: $selected)
                .chartYAxis { AxisMarks(position: .leading) }
                .frame(height: 170)
                if let point {
                    Text("\(point.date.formatted(date: .abbreviated, time: .omitted)): \(point.value.formatted(.number.precision(.fractionLength(0...2)))) · 3-day average \(point.average.formatted(.number.precision(.fractionLength(0...2))))")
                        .font(.caption).monospacedDigit()
                }
            }
        }
    }
}
