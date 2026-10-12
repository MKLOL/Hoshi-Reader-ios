import SwiftUI
import Charts
import Combine

struct StatisticsOverviewView: View {
    @Environment(UserConfig.self) private var userConfig
    @State private var model = StatisticsOverview()
    @State private var usage = UsageStatisticsModel()
    @State private var selectedTab = 0
    @State private var readingDate = ReadingDay.date(at: .now, resetHour: ReadingDay.resetHour)
    @AppStorage(ReadingDay.goalKey) private var goal = 10
    @AppStorage(ReadingDay.resetKey) private var resetHour = 3
    @AppStorage(StatisticsZone.key) private var zoneID = StatisticsZone.defaultID
    private var today: DailyReading { model.days.first { $0.date == readingDate } ?? DailyReading(date: readingDate) }

    var body: some View {
        List {
            Picker("Statistics view", selection: $selectedTab) {
                Text("Overview").tag(0)
                Text("Trends").tag(1)
            }.pickerStyle(.segmented)
            if selectedTab == 0 { overviewSections }
            else { StatisticsTrendsSections(reading: model.days, usage: usage) }
        }
        .environment(\.calendar, StatisticsZone.calendar)
        .environment(\.timeZone, StatisticsZone.calendar.timeZone)
        .navigationTitle("Statistics")
        .onAppear { refresh(); Task { await HttpStatisticsLane.shared.refresh() } }
        .task { await usage.reload() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            refresh(); Task { await HttpStatisticsLane.shared.refresh(); await usage.reload(resetHour: resetHour) }
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now in
            let day = ReadingDay.date(at: now, resetHour: resetHour)
            if day != readingDate { refresh(); Task { await usage.reload(resetHour: resetHour) } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .usageLogChanged).receive(on: RunLoop.main)) { _ in Task { await usage.reload() } }
        .onReceive(NotificationCenter.default.publisher(for: .readingStatisticsChanged)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .hoshiLibraryChanged)) { _ in refresh() }
        .onChange(of: resetHour) { _, _ in refresh(); Task { await usage.reload(resetHour: resetHour) } }
        .onChange(of: zoneID) { _, _ in refresh(); Task { await usage.reload(resetHour: resetHour) } }
    }
    private func refresh() {
        readingDate = ReadingDay.date(at: .now, resetHour: resetHour)
        model.reload(resetHour: resetHour)
    }
    @ViewBuilder private var overviewSections: some View {
        @Bindable var config = userConfig
            if HttpSyncSettingsStore.shared.isConfigured {
                Section {
                    if let problem = HttpStatisticsLane.shared.problem { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
                    else if let checked = HttpStatisticsLane.shared.lastChecked { Text("Other devices checked \(checked.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary) }
                    else { Text("Checking other devices’ reading…").font(.caption).foregroundStyle(.secondary) }
                }
            }
            UsageTodaySection(reading: today, usage: usage.today)
            Section("Reading streak") {
                let streak = StatisticsMath.streak(model.streakHistory.days, goalMinutes: goal, resetHour: resetHour)
                LabeledContent("Current", value: "\(streak.current) days")
                LabeledContent("Longest", value: "\(streak.longest) days")
                LabeledContent("Daily goal", value: "\(min(120, max(1, goal))) minutes")
                Slider(value: Binding(get: { Double(min(120, max(1, goal))) }, set: { StatisticsPreferencesStore.choose(goal: Int($0)) }), in: 1...120, step: 1)
                    .accessibilityLabel("Daily goal")
                Picker("Day resets at", selection: Binding(get: { resetHour }, set: { StatisticsPreferencesStore.choose(reset: $0) })) {
                    ForEach(0..<24, id: \.self) { hour in Text(Self.hourLabel(hour)).tag(hour) }
                }
                Picker("Reading time zone", selection: Binding(get: { zoneID }, set: { StatisticsPreferencesStore.choose(zone: $0) })) {
                    ForEach(Array(Set([StatisticsZone.defaultID, TimeZone.current.identifier, zoneID])).sorted(), id: \.self) { zone in
                        Text(zone.replacingOccurrences(of: "_", with: " ")).tag(zone)
                    }
                }
                Text("Every device counts reading days in this time zone.").font(.caption).foregroundStyle(.secondary)
                Text("All statistics days run from the selected hour until that hour the next morning.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.streakHistory.estimated {
                    Text("Earlier history has no exact time. Your streak receives credit for either possible reading day; reading totals stay unchanged.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ProgressView(value: min(today.seconds / (Double(min(120, max(1, goal))) * 60), 1))
            }
            Section("All time") {
                LabeledContent("Reading time", value: StatisticsMath.duration(model.books.reduce(0.0) { StatisticsNumbers.adding($0, $1.seconds) }))
                LabeledContent("Characters", value: model.books.reduce(0) { StatisticsNumbers.adding($0, $1.characters) }.formatted())
            }
            Section("Last 16 weeks") { ReadingHeatmap(days: model.days) }
            Section("Time by weekday") { WeekdayReadingChart(days: model.days) }
            DeviceReadingSection(devices: model.devices, showBookCount: true)
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

    private static func hourLabel(_ hour: Int) -> String {
        let utc = StatisticsZone.calendar(zone: TimeZone(secondsFromGMT: 0)!)
        return StatisticsZone.display(ReadingDay.boundary(on: Date(timeIntervalSince1970: 0), resetHour: hour, calendar: utc), dateStyle: .none, timeStyle: .short, calendar: utc)
    }
}

struct BookStatisticsDetailView: View {
    let bookId: UUID
    @State private var model = StatisticsOverview()
    @AppStorage(ReadingDay.resetKey) private var resetHour = 3
    @AppStorage(StatisticsZone.key) private var zoneID = StatisticsZone.defaultID
    var body: some View {
        List {
            if let item = model.books.first(where: { $0.id == bookId }) {
                Section(item.book.title ?? "Untitled") {
                    if item.book.folder == nil { Label("Not on this device", systemImage: "icloud").foregroundStyle(.secondary) }
                    LabeledContent("Reading time", value: StatisticsMath.duration(item.seconds))
                    LabeledContent("Characters", value: item.characters.formatted())
                    if item.isManga { LabeledContent("Pages", value: item.pages.formatted()) }
                    if let first = item.days.first(where: { $0.seconds > 0 }) { LabeledContent("Started", value: StatisticsZone.display(first.date)) }
                    if let last = item.days.last(where: { $0.seconds > 0 }) {
                        LabeledContent("Last read", value: StatisticsZone.display(last.date))
                        if item.finished { LabeledContent("Finished", value: StatisticsZone.display(last.date)) }
                    }
                    let count = item.isManga ? item.pages : item.characters
                    let pace = StatisticsNumbers.speed(count: count, seconds: item.seconds)
                    LabeledContent(item.isManga ? "Pages per hour" : "Characters per hour", value: pace.formatted())
                    if count > 0 { LabeledContent(item.isManga ? "Time per page" : "Time per 100 characters", value: StatisticsMath.duration(item.seconds / Double(count) * (item.isManga ? 1 : 100))) }
                    let daysRead = item.days.filter { $0.seconds > 0 }.count
                    LabeledContent("Days read", value: daysRead.formatted())
                    if daysRead > 0 { LabeledContent("Average time per day", value: StatisticsMath.duration(item.seconds / Double(daysRead))) }
                    if let best = item.days.max(by: { $0.seconds < $1.seconds }) {
                        LabeledContent("Best day", value: "\(StatisticsZone.display(best.date)) · \(StatisticsMath.duration(best.seconds))")
                    }
                }
                Section("Last 16 weeks") { ReadingHeatmap(days: item.days) }
                DeviceReadingSection(devices: item.devices)
                Section("History") {
                    ForEach(item.days.reversed()) { day in
                        VStack(alignment: .leading) {
                            Text(StatisticsZone.display(day.date))
                            Text("\(StatisticsMath.duration(day.seconds)) · \(day.characters.formatted()) characters").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .environment(\.calendar, StatisticsZone.calendar)
        .environment(\.timeZone, StatisticsZone.calendar.timeZone)
        .navigationTitle("Book statistics")
        .onAppear { model.reload(resetHour: resetHour) }
        .onChange(of: resetHour) { _, _ in model.reload(resetHour: resetHour) }
        .onChange(of: zoneID) { _, _ in model.reload(resetHour: resetHour) }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in model.reload(resetHour: resetHour) }
        .onReceive(NotificationCenter.default.publisher(for: .readingStatisticsChanged)) { _ in model.reload(resetHour: resetHour) }
    }
}

struct DeviceReadingSection: View {
    let devices: [DeviceReadingSummary]
    var showBookCount = false
    var body: some View {
        if !devices.isEmpty {
            Section("By device") {
                ForEach(devices) { device in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(device.name ?? "Earlier history").font(.headline)
                            if device.deviceId == ReadingDevice.current.id { Text("This device").font(.caption).foregroundStyle(.secondary) }
                        }
                        LabeledContent("Reading time", value: StatisticsMath.duration(device.seconds))
                        LabeledContent("Characters", value: device.characters.formatted())
                        if device.pages > 0 { LabeledContent("Pages", value: device.pages.formatted()) }
                        if showBookCount { LabeledContent("Books", value: device.books.formatted()) }
                        if let last = device.lastRead { LabeledContent("Last read", value: StatisticsZone.display(last)) }
                    }
                }
            }
        }
    }
}

struct ReadingHeatmap: View {
    let days: [DailyReading]
    @AppStorage(ReadingDay.resetKey) private var resetHour = 3
    @AppStorage(StatisticsZone.key) private var zoneID = StatisticsZone.defaultID
    var body: some View {
        let calendar = StatisticsZone.calendar
        let today = ReadingDay.date(at: .now, resetHour: resetHour)
        let mondayOffset = (calendar.component(.weekday, from: today) + 5) % 7
        let start = calendar.date(byAdding: .day, value: -(15 * 7 + mondayOffset), to: today)!
        let maximum = days.filter { $0.date >= start && $0.date <= today }.map(\.seconds).max() ?? 1
        HStack(spacing: 3) {
            ForEach(0..<16, id: \.self) { week in
                VStack(spacing: 3) {
                    ForEach(0..<7, id: \.self) { day in
                        let date = calendar.date(byAdding: .day, value: week * 7 + day, to: start)!
                        let seconds = days.first { $0.date == date }?.seconds ?? 0
                        RoundedRectangle(cornerRadius: 2)
                            .fill(date > today ? Color.clear : seconds == 0 ? Color.secondary.opacity(0.12) : Color.accentColor.opacity(0.25 + 0.75 * seconds / max(1, maximum)))
                            .aspectRatio(1, contentMode: .fit)
                            .accessibilityLabel("\(StatisticsZone.display(date)): \(StatisticsMath.duration(seconds))")
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
            let seconds = days.filter { StatisticsZone.calendar.component(.weekday, from: $0.date) == weekday }.reduce(0.0) { StatisticsNumbers.adding($0, $1.seconds) }
            BarMark(x: .value("Weekday", StatisticsZone.calendar.shortWeekdaySymbols[weekday - 1]), y: .value("Minutes", seconds / 60))
        }.frame(height: 150)
    }
}
