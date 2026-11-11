import SwiftUI
import Charts

/// GitHub-style grid of the last 16 weeks: one column per week, Monday at the top.
struct ReadingHeatmap: View {
    let days: [DailyReading]
    @AppStorage(ReadingDay.resetKey) private var resetHour = 3
    @State private var width: CGFloat = 0
    @ScaledMetric(relativeTo: .caption2) private var labelWidth = 28
    private let gap: CGFloat = 3

    private struct Cell: Identifiable {
        let week: Int, weekday: Int, date: Date, seconds: Double
        var id: Int { week * 7 + weekday }
    }
    static func color(_ level: Int) -> Color {
        level == 0 ? Color(.systemFill) : Color.accentColor.opacity([0.35, 0.55, 0.8, 1][level - 1])
    }

    var body: some View {
        let calendar = StatisticsZone.calendar
        let today = ReadingDay.date(at: .now, resetHour: resetHour)
        let mondayOffset = (calendar.component(.weekday, from: today) + 5) % 7
        let start = ReadingDay.shift(today, by: -(15 * 7 + mondayOffset), calendar: calendar)
        let seconds = Dictionary(days.map { ($0.date, $0.seconds) }, uniquingKeysWith: StatisticsNumbers.adding)
        let cells = (0..<16 * 7).compactMap { index -> Cell? in
            let date = ReadingDay.shift(start, by: index, calendar: calendar)
            return date > today ? nil : Cell(week: index / 7, weekday: index % 7, date: date, seconds: seconds[date] ?? 0)
        }
        let maximum = cells.map(\.seconds).max() ?? 0
        // The labels are capped at xLarge below, and so is their column.
        let labelWidth = min(self.labelWidth, 36)
        // Cells fill a phone's row but stop growing at 18 points on wider screens.
        let step = min(18 + gap, max(8, (width - labelWidth - 6) / 16))
        let read = cells.filter { $0.seconds > 0 }
        let busiest = read.max { $0.seconds < $1.seconds }
        VStack(alignment: .trailing, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Color.clear.frame(width: labelWidth, height: 1)
                    ZStack(alignment: .leading) {
                        ForEach(months(start: start), id: \.week) { Text($0.name).fixedSize().offset(x: CGFloat($0.week) * step) }
                    }
                    .frame(width: step * 16, alignment: .leading)
                }
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(0..<7, id: \.self) { weekday in
                            Text(weekday % 2 == 0 && weekday < 6 ? StatisticsFormat.weekday(ReadingDay.shift(start, by: weekday, calendar: calendar)) : "")
                                .lineLimit(1).minimumScaleFactor(0.6)
                                .frame(width: labelWidth, height: step, alignment: .leading)
                        }
                    }
                    Chart(cells) { cell in
                        RectangleMark(x: .value("Week", Double(cell.week)), y: .value("Weekday", Double(6 - cell.weekday)),
                                      width: .fixed(step - gap), height: .fixed(step - gap))
                            .foregroundStyle(Self.color(StatisticsMath.heatmapLevel(cell.seconds, maximum: maximum)))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    .chartXScale(domain: -0.5...15.5)
                    .chartYScale(domain: -0.5...6.5)
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .frame(width: step * 16, height: step * 7)
                }
            }
            HStack(spacing: 3) {
                Text("Less").padding(.trailing, 3)
                ForEach(0...4, id: \.self) { RoundedRectangle(cornerRadius: 2).fill(Self.color($0)).frame(width: 10, height: 10) }
                Text("More").padding(.leading, 3)
            }
        }
        .font(.caption2).foregroundStyle(.secondary)
        // A picture of sixteen weeks: its labels stop growing so the grid keeps its cells.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .fixedSize()
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reading in the last 16 weeks")
        .accessibilityValue("Read on \(read.count) of \(cells.count) days"
                            + (busiest.map { ". Most on \(StatisticsFormat.weekdayDay($0.date)): \(StatisticsMath.readingTime($0.seconds))" } ?? ""))
    }

    /// A label where a month begins, at least three weeks apart, as on Android.
    private func months(start: Date) -> [(week: Int, name: String)] {
        let calendar = StatisticsZone.calendar
        var labels: [(week: Int, name: String)] = [], last: Int?
        for week in 0..<16 {
            let date = ReadingDay.shift(start, by: week * 7, calendar: calendar)
            let month = calendar.component(.month, from: date)
            guard month != last else { continue }
            last = month
            let label = (week, StatisticsFormat.month(date))
            if let previous = labels.last, week - previous.week < 3 { labels[labels.count - 1] = label } else { labels.append(label) }
        }
        return labels
    }
}

/// Reading time per weekday as labelled bars, Monday first, with each total beside its bar.
struct WeekdayReadingChart: View {
    let days: [DailyReading]
    @ScaledMetric(relativeTo: .subheadline) private var rowHeight = 30
    @Environment(\.dynamicTypeSize) private var typeSize

    private struct Row: Identifiable {
        let id: String, date: Date, seconds: Double
    }

    var body: some View {
        let calendar = StatisticsZone.calendar
        // 1 January 2024 was a Monday; only the weekdays of the week after it matter.
        let monday = calendar.date(from: DateComponents(year: 2024, month: 1, day: 1))!
        let rows = (0..<7).map { offset in
            let date = ReadingDay.shift(monday, by: offset, calendar: calendar)
            let weekday = calendar.component(.weekday, from: date)
            return Row(id: String(offset), date: date, seconds: days.filter { calendar.component(.weekday, from: $0.date) == weekday }.reduce(0.0) { StatisticsNumbers.adding($0, $1.seconds) })
        }
        let maximum = max(1, rows.map(\.seconds).max() ?? 0)
        if typeSize.isAccessibilitySize {
            // Each weekday's name and total above its own bar, so neither squeezes the bar away.
            VStack(alignment: .leading, spacing: 14) {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(StatisticsFormat.weekday(row.date))
                            Spacer()
                            Text(StatisticsMath.readingTime(row.seconds)).fontWeight(.semibold).monospacedDigit()
                        }
                        Chart { bars(row, maximum: maximum) }
                            .chartXScale(domain: 0...maximum).chartXAxis(.hidden).chartYAxis(.hidden)
                            .frame(height: 10)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Self.fullName(row.date))
                    .accessibilityValue(StatisticsMath.readingTime(row.seconds))
                }
            }
            .padding(.vertical, 4)
        } else {
            grid(rows, maximum: maximum)
        }
    }

    private static func fullName(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(timeZone: StatisticsZone.calendar.timeZone).weekday(.wide))
    }
    @ChartContentBuilder private func bars(_ row: Row, maximum: Double) -> some ChartContent {
        BarMark(xStart: .value("Start", 0), xEnd: .value("Most", maximum), y: .value("Weekday", row.id), height: .fixed(10))
            .foregroundStyle(Color(.tertiarySystemFill))
            .clipShape(Capsule())
            .accessibilityHidden(true)
        BarMark(xStart: .value("Start", 0), xEnd: .value("Time", row.seconds), y: .value("Weekday", row.id), height: .fixed(10))
            .foregroundStyle(Color.accentColor)
            .clipShape(Capsule())
            .accessibilityLabel(Self.fullName(row.date))
            .accessibilityValue(StatisticsMath.readingTime(row.seconds))
    }

    private func grid(_ rows: [Row], maximum: Double) -> some View {
        // Labels beside the plot rather than as axes, so large text widens their columns instead of clipping.
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { Text(StatisticsFormat.weekday($0.date)).frame(height: rowHeight) }
            }
            .fixedSize()
            .accessibilityHidden(true)
            Chart(rows) { row in bars(row, maximum: maximum) }
                .chartXScale(domain: 0...maximum)
                .chartYScale(domain: rows.map(\.id))
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: rowHeight * 7)
            VStack(alignment: .trailing, spacing: 0) {
                ForEach(rows) { Text(StatisticsMath.readingTime($0.seconds)).fontWeight(.semibold).monospacedDigit().frame(height: rowHeight) }
            }
            .fixedSize()
            .accessibilityHidden(true)
        }
        .font(.subheadline)
        .padding(.vertical, 4)
    }
}
