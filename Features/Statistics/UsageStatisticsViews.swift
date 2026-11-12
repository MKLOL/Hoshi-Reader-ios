import SwiftUI
import Charts

private func usageTime(_ date: Date, zone: TimeZone) -> String {
    StatisticsZone.display(date, dateStyle: .none, timeStyle: .short, calendar: StatisticsZone.calendar(zone: zone))
}

private func usageTimeRange(_ start: Date, _ end: Date, startZone: TimeZone, endZone: TimeZone) -> String {
    usageTime(start, zone: startZone) + "\u{00A0}–\u{2060}\u{00A0}" + usageTime(end, zone: endZone)
}

struct UsageTodaySection: View {
    let reading: DailyReading
    let usage: UsageDay
    @AppStorage(ReadingDay.resetKey) private var resetHour = 3
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Whether the usage log saw today; as on Android, reading time alone shows no counts of zero.
    private var hasUsage: Bool {
        !usage.spans.isEmpty || usage.lookups + usage.pages + usage.sessions + usage.revealed + usage.translated + usage.screenshots > 0
    }
    private var isEmpty: Bool { reading.seconds == 0 && !hasUsage }
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
            VStack(alignment: .leading, spacing: 2) {
                Text(StatisticsFormat.longDay(usage.date)).font(.subheadline.weight(.semibold))
                if let first = usage.firstActivity, let last = usage.lastActivity,
                   let firstZone = usage.firstActivityZone, let lastZone = usage.lastActivityZone {
                    Text("Active \(usageTimeRange(first, last, startZone: firstZone, endZone: lastZone))").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                }
                if reading.seconds > 0 || reading.characters > 0 {
                    Text("Reading time").font(.subheadline).foregroundStyle(.secondary).padding(.top, 10)
                    Text(StatisticsMath.readingTime(reading.seconds)).font(.largeTitle.weight(.semibold)).monospacedDigit()
                    if reading.characters > 0 {
                        Text("\(reading.characters.formatted()) characters read").font(.subheadline).foregroundStyle(.secondary)
                    }
                } else if isEmpty {
                    Text("Nothing read yet today. Open a book and today's reading shows up here.")
                        .foregroundStyle(.secondary).padding(.top, 8)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            if hasUsage {
                // One count per line at accessibility sizes, so labels are never cut mid-word.
                let tile = typeSize.isAccessibilitySize ? AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .topLeading), count: typeSize.isAccessibilitySize ? 1 : 3),
                          alignment: .leading, spacing: 14) {
                    ForEach(tiles, id: \.0) { label, value in
                        tile {
                            Text(value.formatted()).font(.title3.weight(.semibold)).monospacedDigit()
                            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.vertical, 6)
            }
            if !usage.spans.isEmpty {
                let colors = StatisticsBookColors(spans: usage.spans)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Timeline").font(.subheadline.weight(.semibold))
                    ReadingTimeline(spans: usage.spans, resetHour: resetHour, colors: colors)
                }
                .padding(.vertical, 6)
                DisclosureGroup(StatisticsFormat.count(usage.spans.count, "session", "sessions")) {
                    ForEach(usage.spans.reversed()) { span in ReadingSessionRow(span: span, color: colors.color(span.title)) }
                }
            }
            if !usage.repeated.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Looked up more than once").font(.subheadline.weight(.semibold))
                    StatisticsFlowLayout {
                        ForEach(usage.repeated, id: \.word) { word in
                            HStack(spacing: 4) {
                                Text(word.word)
                                Text("×\(word.count)").foregroundStyle(.secondary).monospacedDigit()
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                            // One element per chip whose label is the word itself.
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(word.word)
                            .accessibilityValue("looked up \(word.count) times")
                            .accessibilityAddTraits(.isStaticText)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
        } header: {
            Text("Today")
        } footer: {
            if hasUsage { Text("Lookups, bubbles and the timeline include your other devices once they sync over HTTP.") }
        }
    }
}

private struct ReadingSessionRow: View {
    let span: UsageSpan
    let color: Color
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(color).frame(width: 9, height: 9).accessibilityHidden(true)
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
            layout {
                VStack(alignment: .leading, spacing: 2) {
                    Text(span.title).lineLimit(1)
                    Text(usageTimeRange(span.start, span.end, startZone: span.zone, endZone: span.zone))
                        .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.75)
                }
                if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
                Text(StatisticsMath.readingTime(span.seconds)).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Minutes read in each hour of the reading day, stacked by book, like Screen Time's day view.
private struct ReadingTimeline: View {
    let spans: [UsageSpan]
    let resetHour: Int
    let colors: StatisticsBookColors
    @ScaledMetric(relativeTo: .body) private var height = 120

    private struct Slice: Identifiable {
        let start: Date, end: Date, book: String, low: Double, high: Double, top: Bool
        var id: String { "\(start.timeIntervalSince1970)|\(book)" }
    }

    var body: some View {
        let reset = min(23, max(0, resetHour))
        let dayStart = Date(timeIntervalSince1970: Double(reset) * 3600)
        let dayEnd = dayStart.addingTimeInterval(24 * 3600)
        let byHour = minutesByHour(reset: reset)
        let peak = max(60, (byHour.values.map { $0.values.reduce(0, +) }.max() ?? 0))
        let slices = (0..<24).flatMap { hour -> [Slice] in
            let start = dayStart.addingTimeInterval(Double(hour) * 3600)
            let end = start.addingTimeInterval(3600)
            let minutes = byHour[hour, default: [:]]
            let books = colors.names.filter { (minutes[$0] ?? 0) > 0 }
            // A gap between neighbouring hours, as Screen Time draws them.
            let inset = end.timeIntervalSince(start) * 0.12
            var result: [Slice] = [], low = 0.0
            for (index, book) in books.enumerated() {
                let high = low + minutes[book]!
                result.append(Slice(start: start.addingTimeInterval(inset), end: end.addingTimeInterval(-inset), book: book, low: low, high: high, top: index == books.count - 1))
                low = high
            }
            return result
        }
        let totals = colors.names.compactMap { name -> String? in
            let seconds = spans.filter { colors.name($0.title) == name }.reduce(0.0) { $0 + $1.seconds }
            return seconds > 0 ? "\(name), \(StatisticsMath.readingTime(seconds))" : nil
        }
        let total = StatisticsMath.readingTime(spans.reduce(0.0) { $0 + $1.seconds })
        VStack(alignment: .leading, spacing: 10) {
            chart(slices, from: dayStart, to: dayEnd, peak: peak)
            StatisticsFlowLayout(spacing: 12) {
                ForEach(colors.names, id: \.self) { name in
                    Label {
                        Text(name)
                    } icon: {
                        Circle().fill(colors.color(name)).frame(width: 8, height: 8)
                    }
                    .labelStyle(StatisticsLegendLabelStyle())
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reading timeline")
        .accessibilityValue(([total] + totals).joined(separator: "; "))
    }

    private func minutesByHour(reset: Int) -> [Int: [String: Double]] {
        var byHour: [Int: [String: Double]] = [:]
        for span in spans {
            let calendar = StatisticsZone.calendar(zone: span.zone)
            let book = colors.name(span.title)
            var cursor = span.start
            while cursor < span.end, let hour = calendar.dateInterval(of: .hour, for: cursor), hour.end > cursor {
                let next = min(span.end, hour.end)
                let slot = (calendar.component(.hour, from: cursor) - reset + 24) % 24
                byHour[slot, default: [:]][book, default: 0] += next.timeIntervalSince(cursor) / 60
                cursor = next
            }
        }
        return byHour
    }

    private func chart(_ slices: [Slice], from dayStart: Date, to dayEnd: Date, peak: Double) -> some View {
        let marks = [0, 6, 12, 18, 24].map { dayStart.addingTimeInterval(Double($0) * 3600) }
        let utc = TimeZone(secondsFromGMT: 0)!
        return Chart(slices) { slice in
            let radius: CGFloat = slice.top ? 3 : 0
            RectangleMark(xStart: .value("Hour", slice.start), xEnd: .value("Hour end", slice.end),
                          yStart: .value("Minutes", slice.low), yEnd: .value("Minutes", slice.high))
                .foregroundStyle(colors.color(slice.book))
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: radius, topTrailingRadius: radius))
        }
        .chartXScale(domain: dayStart...dayEnd)
        .chartYScale(domain: 0...peak)
        .chartXAxis {
            AxisMarks(values: marks) { value in
                let date = value.as(Date.self) ?? dayEnd
                AxisGridLine()
                // The day's last gridline closes the chart; its hour is already the first label.
                AxisValueLabel(anchor: .topLeading) { Text(date < dayEnd ? date.formatted(Date.FormatStyle(timeZone: utc).hour()) : "") }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel { Text(Self.minuteTick(Int(value.as(Double.self) ?? 0))) }
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .frame(height: min(height, 180))
    }
    private static func minuteTick(_ minutes: Int) -> String { minutes == 0 ? "0" : "\(minutes)m" }
}

struct StatisticsLegendLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) { configuration.icon; configuration.title }
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
    /// Days whose three-day window revealed a bubble: only they have a rate to draw.
    private func rated(_ points: [ReadingTrendPoint], by denominator: [Date: Double]) -> Set<Date> {
        let calendar = StatisticsZone.calendar
        return Set(points.map(\.date).filter { date in
            (0..<3).map { ReadingDay.shift(date, by: -$0, calendar: calendar) }
                .filter { usage.firstDay == nil || $0 >= usage.firstDay! }
                .contains { (denominator[$0] ?? 0) > 0 }
        })
    }
    var body: some View {
        Picker("Period", selection: $days) {
            ForEach([14, 30, 90], id: \.self) { Text("\($0) days").tag($0) }
        }
        .pickerStyle(.segmented)
        .listRowBackground(Color.clear).listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
        let since = usage.firstDay.map { "Recorded since \(StatisticsFormat.date($0))" }
        let perBubble = usage.firstDay.map { "Per revealed manga bubble, since \(StatisticsFormat.date($0))" }
        let rate: (Double) -> String = { $0.formatted(.number.precision(.fractionLength(0...2))) }
        let seconds = Dictionary(uniqueKeysWithValues: reading.map { ($0.date, min($0.seconds, Double(Int.max))) })
        ReadingTrendChart(title: "Daily reading time", points: series(seconds),
                          empty: "No reading in the last \(days) days.",
                          format: { StatisticsMath.readingTime($0) }, tick: { $0 == 0 ? "0" : StatisticsMath.readingTime($0) },
                          yAxisMaximum: { StatisticsMath.axisTop($0 / 60) * 60 })
        ReadingTrendChart(title: "Characters read", points: series(Dictionary(uniqueKeysWithValues: reading.map { ($0.date, Double($0.characters)) })),
                          empty: "No characters read in the last \(days) days.")
        ReadingTrendChart(title: "Words looked up", subtitle: since, points: series(usage.values(\.lookups), local: true),
                          empty: usage.firstDay == nil ? "No reading log yet." : "No words looked up in the last \(days) days.")
        // Manga charts only once manga bubbles were revealed or translated.
        let revealed = usage.values(\.revealed)
        if revealed.values.contains(where: { $0 > 0 }) || usage.values(\.translated).values.contains(where: { $0 > 0 }) {
            let lookups = series(usage.values(\.mangaLookups), denominator: revealed, local: true)
            ReadingTrendChart(title: "Words looked up per bubble", subtitle: perBubble, points: lookups, rated: rated(lookups, by: revealed),
                              empty: "No bubbles revealed in the last \(days) days.", format: rate, tick: rate)
            ReadingTrendChart(title: "Translations pressed", subtitle: since,
                              points: series(usage.values(\.translated).merging(usage.values(\.screenshots), uniquingKeysWith: +), local: true),
                              empty: "No translations in the last \(days) days.")
            let translations = series(usage.values(\.translated), denominator: revealed, local: true)
            ReadingTrendChart(title: "Translations pressed per bubble", subtitle: perBubble, points: translations, rated: rated(translations, by: revealed),
                              empty: "No bubbles revealed in the last \(days) days.", format: rate, tick: rate)
        }
    }
}

private struct ReadingTrendChart: View {
    let title: String
    var subtitle: String? = nil
    let points: [ReadingTrendPoint]
    /// For rates: the days that have one. A day without bubbles is a gap, not a zero.
    var rated: Set<Date>? = nil
    var empty = "Nothing recorded yet."
    var format: (Double) -> String = { $0.formatted(.number.precision(.fractionLength(0...1))) }
    var tick: (Double) -> String = { $0.formatted(.number.notation(.compactName)) }
    var yAxisMaximum: (Double) -> Double = StatisticsMath.axisTop
    @State private var selected: Date?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var height = 170

    private func hasRate(_ point: ReadingTrendPoint) -> Bool { rated?.contains(point.date) ?? true }
    private func middle(_ date: Date) -> Date { date.addingTimeInterval(12 * 3600) }
    /// The selected day, else the latest one: the readout is always there, as on Android.
    private var point: ReadingTrendPoint? {
        selected.flatMap { date in points.min { abs(middle($0.date).timeIntervalSince(date)) < abs(middle($1.date).timeIntervalSince(date)) } } ?? points.last
    }
    /// Consecutive days with a value, each drawn as its own line.
    private var runs: [(run: Int, point: ReadingTrendPoint)] {
        var run = 0, previous = true
        return points.compactMap { point in
            let has = hasRate(point)
            if has && !previous { run += 1 }
            previous = has
            return has ? (run, point) : nil
        }
    }
    var body: some View {
        Section {
            if points.allSatisfy({ $0.value == 0 && (!hasRate($0) || $0.average == 0) }) {
                Text(empty).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    if let point { readout(point) }
                    chart
                    StatisticsFlowLayout(spacing: 16) {
                        Label { Text("Daily") } icon: { RoundedRectangle(cornerRadius: 2).fill(barColor).frame(width: 10, height: 10) }
                        Label { Text("3-day average") } icon: { Capsule().fill(Color.accentColor).frame(width: 14, height: 3) }
                    }
                    .labelStyle(StatisticsLegendLabelStyle())
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                }
                .padding(.vertical, 6)
            }
        } header: {
            Text(title)
        } footer: {
            if let subtitle { Text(subtitle) }
        }
    }

    private var barColor: Color { Color.accentColor.opacity(colorScheme == .dark ? 0.5 : 0.35) }

    private func readout(_ point: ReadingTrendPoint) -> some View {
        let has = hasRate(point)
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(alignment: .bottom))
        return layout {
            VStack(alignment: .leading, spacing: 2) {
                Text(StatisticsFormat.weekdayDay(point.date)).font(.subheadline).foregroundStyle(.secondary)
                Text(has || point.value > 0 ? format(point.value) : "–").font(.title2.weight(.semibold)).monospacedDigit()
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: 12) }
            VStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing, spacing: 2) {
                Text("3-day average").font(.subheadline).foregroundStyle(.secondary)
                Text(has ? format(point.average) : "–").font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(Color.accentColor)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var chart: some View {
        let calendar = StatisticsZone.calendar
        let top = yAxisMaximum(points.map { max($0.value, hasRate($0) ? $0.average : 0) }.max() ?? 0)
        // Ticks at chosen days' middles, labelled in the statistics zone, not the device's.
        let stride = max(1, Int((Double(points.count) / (typeSize.isAccessibilitySize ? 2 : 4)).rounded(.up)))
        let ticks = points.isEmpty ? [] : Swift.stride(from: max(0, points.count - 1 - stride / 2), through: 0, by: -stride).map { middle(points[$0].date) }
        let selectedDate = point?.date
        return Chart {
            ForEach(points) { day in
                let next = ReadingDay.shift(day.date, by: 1, calendar: calendar)
                let inset = next.timeIntervalSince(day.date) * 0.12
                RectangleMark(xStart: .value("Day", day.date.addingTimeInterval(inset)), xEnd: .value("Day end", next.addingTimeInterval(-inset)),
                              yStart: .value("Daily", 0.0), yEnd: .value("Daily", day.value))
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2))
                    .foregroundStyle(day.date == selectedDate ? Color.accentColor.opacity(0.8) : barColor)
                    .accessibilityLabel(StatisticsFormat.weekdayDay(day.date))
                    .accessibilityValue(hasRate(day) || day.value > 0 ? format(day.value) : "no bubbles")
            }
            ForEach(runs, id: \.point.id) { run, day in
                LineMark(x: .value("Day", middle(day.date)), y: .value("3-day average", day.average), series: .value("Run", run))
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .accessibilityHidden(true)
            }
            if let point, hasRate(point) {
                PointMark(x: .value("Day", middle(point.date)), y: .value("3-day average", point.average))
                    .symbolSize(40)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
        }
        .chartXScale(domain: (points.first?.date ?? .now)...(points.last.map { ReadingDay.shift($0.date, by: 1, calendar: calendar) } ?? .now))
        .chartYScale(domain: 0...top)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, top / 2, top]) { value in
                AxisGridLine()
                AxisValueLabel { Text(tick(value.as(Double.self) ?? 0)) }
            }
        }
        .chartXAxis {
            AxisMarks(values: ticks) { value in
                AxisTick()
                AxisValueLabel(anchor: .top, collisionResolution: .greedy) { Text(value.as(Date.self).map(StatisticsFormat.day) ?? "") }
            }
        }
        .chartXSelection(value: $selected)
        // A tap selects a day; a drag stays free to scroll the list.
        .chartGesture { proxy in SpatialTapGesture().onEnded { proxy.selectXValue(at: $0.location.x) } }
        .sensoryFeedback(.selection, trigger: selectedDate)
        // Axis labels stop growing before they crowd out the plot; the readout above carries large text.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .frame(height: min(height, 260))
    }
}
