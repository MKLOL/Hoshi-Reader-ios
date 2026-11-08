import SwiftUI
import Charts

struct UsageTodaySection: View {
    let reading: DailyReading
    let usage: UsageDay
    @AppStorage(ReadingDay.resetKey) private var resetHour = 3
    @Environment(\.dynamicTypeSize) private var typeSize

    private func time(_ date: Date) -> String { StatisticsZone.display(date, dateStyle: .none, timeStyle: .short) }
    private var isEmpty: Bool {
        reading.seconds == 0 && usage.spans.isEmpty && usage.lookups == 0 && usage.pages == 0
            && usage.revealed == 0 && usage.translated == 0 && usage.screenshots == 0
    }
    private var tiles: [(String, Int)] {
        var tiles = [("Words looked up", usage.lookups), ("Pages turned", usage.pages), ("Reading sessions", usage.sessions)]
        // Manga counters only matter once manga were read today.
        if usage.revealed + usage.translated + usage.screenshots > 0 {
            tiles += [("Bubbles revealed", usage.revealed), ("Bubble translations", usage.translated), ("Screenshot translations", usage.screenshots)]
        }
        return tiles
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(StatisticsZone.display(usage.date, dateStyle: .full)
                     + (usage.firstActivity.flatMap { first in usage.lastActivity.map { " · Active \(time(first))–\(time($0))" } } ?? ""))
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("Reading time").font(.subheadline).foregroundStyle(.secondary).padding(.top, 6)
                Text(StatisticsMath.duration(reading.seconds)).font(.largeTitle.weight(.semibold)).monospacedDigit()
                if reading.characters > 0 {
                    Text("\(reading.characters.formatted()) characters read").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            if isEmpty {
                Text("Nothing read yet today. Open a book and today's reading shows up here.").foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .topLeading), count: typeSize.isAccessibilitySize ? 2 : 3),
                          alignment: .leading, spacing: 14) {
                    ForEach(tiles, id: \.0) { label, value in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(value.formatted()).font(.title3.weight(.semibold)).monospacedDigit()
                            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.vertical, 4)
            }
            if !usage.spans.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Timeline").font(.subheadline.weight(.semibold))
                    ReadingTimeline(spans: usage.spans, day: usage.date, resetHour: resetHour)
                }
                .padding(.vertical, 4)
                ForEach(usage.spans.suffix(5).reversed()) { span in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(time(span.start))–\(time(span.end)) · \(StatisticsMath.duration(span.seconds))").monospacedDigit()
                        Text(span.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if !usage.repeated.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Looked up more than once").font(.subheadline.weight(.semibold))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(usage.repeated, id: \.word) { word in
                                HStack(spacing: 4) {
                                    Text(word.word)
                                    Text("×\(word.count)").foregroundStyle(.secondary).monospacedDigit()
                                }
                                .padding(.horizontal, 12).padding(.vertical, 5)
                                .background(Color(.tertiarySystemFill), in: Capsule())
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Today")
        } footer: {
            Text("Lookups, bubbles and the timeline include your other devices once they sync over HTTP. Reading activity and looked-up text sync only to your chosen server, and logs stay out of system backups.")
        }
    }
}

/// When the day's reading happened: sessions on a track spanning at least four hours around them,
/// clamped to the reading day, with its start, middle and end times below.
private struct ReadingTimeline: View {
    let spans: [UsageSpan]
    let day: Date
    let resetHour: Int

    private var window: ClosedRange<Date> {
        let calendar = StatisticsZone.calendar
        let dayStart = ReadingDay.boundary(on: day, resetHour: resetHour, calendar: calendar)
        let dayEnd = ReadingDay.boundary(on: ReadingDay.shift(day, by: 1, calendar: calendar), resetHour: resetHour, calendar: calendar)
        let first = spans.map(\.start).min() ?? dayStart, last = spans.map(\.end).max() ?? dayStart
        var low = max(dayStart, (calendar.dateInterval(of: .hour, for: first)?.start ?? first).addingTimeInterval(-3600))
        var high = min(dayEnd, (calendar.dateInterval(of: .hour, for: last)?.end ?? last).addingTimeInterval(3600))
        if high.timeIntervalSince(low) < 4 * 3600 {
            high = min(dayEnd, low.addingTimeInterval(4 * 3600))
            low = max(dayStart, high.addingTimeInterval(-4 * 3600))
        }
        return low...max(high, low.addingTimeInterval(3600))
    }

    var body: some View {
        let window = self.window
        let length = window.upperBound.timeIntervalSince(window.lowerBound)
        let middle = window.lowerBound.addingTimeInterval(length / 2)
        VStack(spacing: 4) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.tertiarySystemFill))
                    ForEach(spans) { span in
                        let start = max(0, span.start.timeIntervalSince(window.lowerBound)) / length
                        let end = min(length, span.end.timeIntervalSince(window.lowerBound)) / length
                        RoundedRectangle(cornerRadius: 4).fill(Color.accentColor)
                            .frame(width: max(4, (end - start) * geometry.size.width))
                            .offset(x: start * geometry.size.width)
                    }
                }
            }
            .frame(height: 20)
            HStack {
                Text(StatisticsZone.display(window.lowerBound, dateStyle: .none, timeStyle: .short))
                Spacer()
                Text(StatisticsZone.display(middle, dateStyle: .none, timeStyle: .short))
                Spacer()
                Text(StatisticsZone.display(window.upperBound, dateStyle: .none, timeStyle: .short))
            }
            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reading timeline from \(StatisticsZone.display(window.lowerBound, dateStyle: .none, timeStyle: .short)) to \(StatisticsZone.display(window.upperBound, dateStyle: .none, timeStyle: .short)), \(spans.count) sessions")
    }
}

struct StatisticsTrendsSections: View {
    let reading: [DailyReading]
    let usage: UsageStatisticsModel
    @State private var days = 30
    @AppStorage(ReadingDay.resetKey) private var resetHour = 3
    private func series(_ values: [Date: Double], denominator: [Date: Double]? = nil, local: Bool = false) -> [ReadingTrendPoint] {
        if local && usage.firstDay == nil { return [] }
        return ReadingTrends.series(values: values, denominators: denominator, days: days, since: local ? usage.firstDay : nil, resetHour: resetHour, calendar: StatisticsZone.calendar)
    }
    var body: some View {
        Section {
            Picker("Period", selection: $days) {
                ForEach([14, 30, 90], id: \.self) { Text("\($0) days").tag($0) }
            }.pickerStyle(.segmented)
        }
        ReadingTrendChart(title: "Reading time (minutes)", points: series(Dictionary(uniqueKeysWithValues: reading.map { ($0.date, $0.seconds / 60) })),
                          format: { StatisticsMath.duration($0 * 60) }, tick: { "\(Int($0))m" })
        ReadingTrendChart(title: "Characters read", points: series(Dictionary(uniqueKeysWithValues: reading.map { ($0.date, Double($0.characters)) })))
        ReadingTrendChart(title: "Words looked up", points: series(usage.values(\.lookups), local: true), since: usage.firstDay)
        // Manga charts only once manga bubbles were revealed or translated.
        if usage.values(\.revealed).values.contains(where: { $0 > 0 }) || usage.values(\.translated).values.contains(where: { $0 > 0 }) {
            ReadingTrendChart(title: "Lookups per manga bubble", points: series(usage.values(\.mangaLookups), denominator: usage.values(\.revealed), local: true),
                              since: usage.firstDay, format: { $0.formatted(.number.precision(.fractionLength(2))) })
            ReadingTrendChart(title: "Translations pressed", points: series(usage.values(\.translated).merging(usage.values(\.screenshots), uniquingKeysWith: +), local: true),
                              since: usage.firstDay)
            ReadingTrendChart(title: "Translations per manga bubble", points: series(usage.values(\.translated), denominator: usage.values(\.revealed), local: true),
                              since: usage.firstDay, format: { $0.formatted(.number.precision(.fractionLength(2))) })
        }
    }
}

private struct ReadingTrendChart: View {
    let title: String
    let points: [ReadingTrendPoint]
    var since: Date? = nil
    var format: (Double) -> String = { $0.formatted(.number.precision(.fractionLength(0...1))) }
    var tick: (Double) -> String = { $0.formatted(.number.notation(.compactName)) }
    @State private var selected: Date?
    /// The selected day, else the latest one: the readout is always there, as on Android.
    private var point: ReadingTrendPoint? {
        selected.flatMap { date in points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) } } ?? points.last
    }
    /// A round axis top with gridlines at its half.
    private var top: Double {
        let largest = points.map { max($0.value, $0.average) }.max() ?? 0
        guard largest > 0 else { return 2 }
        let raw = largest / 2, magnitude = pow(10, floor(log10(raw)))
        let step = [1, 2, 2.5, 5, 10].map { $0 * magnitude }.first { $0 >= raw } ?? raw
        return ceil(largest / step) * step
    }
    var body: some View {
        Section {
            if points.isEmpty { Text("No reading log yet.").foregroundStyle(.secondary) }
            else {
                if let point {
                    Text("\(point.date.formatted(.dateTime.month(.abbreviated).day())) · \(format(point.value)) · 3-day average \(format(point.average))")
                        .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                }
                let top = self.top
                Chart(points) { day in
                    BarMark(x: .value("Day", day.date, unit: .day), y: .value("Daily", day.value))
                        .cornerRadius(3)
                        .foregroundStyle(Color.accentColor.opacity(day.date == point?.date ? 0.65 : 0.3))
                    LineMark(x: .value("Day", day.date, unit: .day), y: .value("3-day average", day.average))
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
                .chartYScale(domain: 0...top)
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0, top / 2, top]) { value in
                        AxisGridLine()
                        AxisValueLabel { Text(tick(value.as(Double.self) ?? 0)) }
                    }
                }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
                .chartXSelection(value: $selected)
                .frame(height: 170)
                HStack(spacing: 14) {
                    Label { Text("Daily") } icon: { RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.3)).frame(width: 12, height: 12) }
                    Label { Text("3-day average") } icon: { Capsule().fill(Color.accentColor).frame(width: 14, height: 3) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text(title)
        } footer: {
            if let since { Text("Recorded since \(StatisticsZone.display(since))") }
        }
    }
}
