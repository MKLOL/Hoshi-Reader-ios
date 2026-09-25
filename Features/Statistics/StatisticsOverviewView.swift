import SwiftUI
import Charts

struct StatisticsOverviewView: View {
    @Environment(UserConfig.self) private var userConfig
    @State private var model = StatisticsOverview()
    @AppStorage("statistics.dailyGoalMinutes") private var goal = 10
    private var today: DailyReading { model.days.first { Calendar.current.isDateInToday($0.date) } ?? DailyReading(date: .now) }

    var body: some View {
        @Bindable var config = userConfig
        List {
            Section("Today") {
                LabeledContent("Reading time", value: StatisticsMath.duration(today.seconds))
                LabeledContent("Characters", value: today.characters.formatted())
            }
            Section("Reading streak") {
                let streak = StatisticsMath.streak(model.days, goalMinutes: goal)
                LabeledContent("Current", value: "\(streak.current) days")
                LabeledContent("Longest", value: "\(streak.longest) days")
                Picker("Daily goal", selection: $goal) {
                    ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) minutes").tag($0) }
                }
                ProgressView(value: min(today.seconds / Double(goal * 60), 1))
            }
            Section("All time") {
                LabeledContent("Reading time", value: StatisticsMath.duration(model.books.reduce(0) { $0 + $1.seconds }))
                LabeledContent("Characters", value: model.books.reduce(0) { $0 + $1.characters }.formatted())
            }
            Section("Last 16 weeks") { ReadingHeatmap(days: model.days) }
            Section("Time by weekday") { WeekdayReadingChart(days: model.days) }
            DeviceReadingSection(reading: model.books.flatMap(\.reading))
            Section("Books") {
                ForEach(model.books) { item in
                    NavigationLink {
                        BookStatisticsDetailView(bookId: item.id)
                    } label: {
                        HStack {
                            if let url = item.book.coverURL, let image = UIImage(contentsOfFile: url.path) {
                                Image(uiImage: image).resizable().scaledToFit().frame(width: 40, height: 56)
                            } else { Image(systemName: "book.closed").frame(width: 40) }
                            VStack(alignment: .leading) {
                                Text(item.book.title ?? "Untitled")
                                Text("\(StatisticsMath.duration(item.seconds)) · \(item.characters.formatted()) characters").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if config.enableSync {
                Section("ッツ Sync") {
                    Toggle("Sync statistics", isOn: $config.statisticsEnableSync)
                    Picker("Sync behaviour", selection: $config.statisticsSyncMode) {
                        ForEach(StatisticsSyncMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                }
            }
        }
        .navigationTitle("Statistics")
        .onAppear { model.reload() }
        .onReceive(NotificationCenter.default.publisher(for: .readingStatisticsChanged)) { _ in model.reload() }
        .onReceive(NotificationCenter.default.publisher(for: .hoshiLibraryChanged)) { _ in model.reload() }
    }
}

struct BookStatisticsDetailView: View {
    let bookId: UUID
    @State private var model = StatisticsOverview()
    var body: some View {
        List {
            if let item = model.books.first(where: { $0.id == bookId }) {
                Section(item.book.title ?? "Untitled") {
                    LabeledContent("Reading time", value: StatisticsMath.duration(item.seconds))
                    LabeledContent("Characters", value: item.characters.formatted())
                    if item.isManga { LabeledContent("Pages", value: item.pages.formatted()) }
                    if let first = item.days.first { LabeledContent("Started", value: first.date.formatted(date: .abbreviated, time: .omitted)) }
                    if let last = item.days.last {
                        LabeledContent("Last read", value: last.date.formatted(date: .abbreviated, time: .omitted))
                        if item.finished { LabeledContent("Finished", value: last.date.formatted(date: .abbreviated, time: .omitted)) }
                    }
                    let count = item.isManga ? item.pages : item.characters
                    let pace = item.seconds > 0 ? Int(Double(count) / item.seconds * 3600) : 0
                    LabeledContent(item.isManga ? "Pages per hour" : "Characters per hour", value: pace.formatted())
                    if count > 0 { LabeledContent(item.isManga ? "Time per page" : "Time per 100 characters", value: StatisticsMath.duration(item.seconds / Double(count) * (item.isManga ? 1 : 100))) }
                    if let best = item.days.max(by: { $0.seconds < $1.seconds }) {
                        LabeledContent("Best day", value: "\(best.date.formatted(date: .abbreviated, time: .omitted)) · \(StatisticsMath.duration(best.seconds))")
                    }
                }
                Section("Last 16 weeks") { ReadingHeatmap(days: item.days) }
                DeviceReadingSection(reading: item.reading)
                Section("History") {
                    ForEach(item.days.reversed()) { day in
                        VStack(alignment: .leading) {
                            Text(day.date.formatted(date: .abbreviated, time: .omitted))
                            Text("\(StatisticsMath.duration(day.seconds)) · \(day.characters.formatted()) characters").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Book statistics")
        .onAppear { model.reload() }
        .onReceive(NotificationCenter.default.publisher(for: .readingStatisticsChanged)) { _ in model.reload() }
    }
}

struct DeviceReadingSection: View {
    let reading: [Statistics]
    var body: some View {
        Section("By device") {
            let groups = Dictionary(grouping: reading, by: { $0.deviceId ?? "legacy" })
            ForEach(groups.keys.sorted(), id: \.self) { key in
                let rows = groups[key] ?? []
                let name = rows.max(by: { $0.lastStatisticModified < $1.lastStatisticModified })?.deviceName ?? "Earlier history"
                LabeledContent(name, value: StatisticsMath.duration(rows.reduce(0) { $0 + $1.readingTime }))
            }
        }
    }
}

struct ReadingHeatmap: View {
    let days: [DailyReading]
    var body: some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let mondayOffset = (calendar.component(.weekday, from: today) + 5) % 7
        let start = calendar.date(byAdding: .day, value: -(15 * 7 + mondayOffset), to: today)!
        let maximum = days.map(\.seconds).max() ?? 1
        HStack(spacing: 3) {
            ForEach(0..<16, id: \.self) { week in
                VStack(spacing: 3) {
                    ForEach(0..<7, id: \.self) { day in
                        let date = calendar.date(byAdding: .day, value: week * 7 + day, to: start)!
                        let seconds = days.first { $0.date == date }?.seconds ?? 0
                        RoundedRectangle(cornerRadius: 2)
                            .fill(date > today ? Color.clear : seconds == 0 ? Color.secondary.opacity(0.12) : Color.accentColor.opacity(0.25 + 0.75 * seconds / max(1, maximum)))
                            .aspectRatio(1, contentMode: .fit)
                            .accessibilityLabel("\(date.formatted(date: .abbreviated, time: .omitted)): \(StatisticsMath.duration(seconds))")
                    }
                }
            }
        }
    }
}

struct WeekdayReadingChart: View {
    let days: [DailyReading]
    var body: some View {
        Chart(0..<7, id: \.self) { offset in
            let weekday = (offset + 1) % 7 + 1
            let seconds = days.filter { Calendar.current.component(.weekday, from: $0.date) == weekday }.reduce(0) { $0 + $1.seconds }
            BarMark(x: .value("Weekday", Calendar.current.shortWeekdaySymbols[weekday - 1]), y: .value("Minutes", seconds / 60))
        }.frame(height: 150)
    }
}
