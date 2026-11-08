import SwiftUI
import Combine

struct StatisticsOverviewView: View {
    @Environment(UserConfig.self) private var userConfig
    @State private var model = StatisticsOverview()
    @State private var usage = UsageStatisticsModel()
    @State private var selectedTab = 0
    @State private var loaded = false
    @State private var readingDate = ReadingDay.date(at: .now, resetHour: ReadingDay.resetHour)
    @AppStorage(ReadingDay.resetKey) private var resetHour = 3
    @AppStorage(StatisticsZone.key) private var zoneID = StatisticsZone.defaultID
    private var today: DailyReading { model.days.first { $0.date == readingDate } ?? DailyReading(date: readingDate) }

    var body: some View {
        List {
            Picker("Statistics view", selection: $selectedTab) {
                Text("Overview").tag(0)
                Text("Trends").tag(1)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear).listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
            if selectedTab == 0 { overviewSections }
            else { StatisticsTrendsSections(reading: model.days, usage: usage) }
        }
        .modifier(StatisticsReadableWidth())
        .environment(\.calendar, StatisticsZone.calendar)
        .environment(\.timeZone, StatisticsZone.calendar.timeZone)
        .navigationTitle("Statistics")
        .onAppear { refresh(); HttpSyncManager.shared.syncInBackground(); Task { await HttpStatisticsLane.shared.refresh() } }
        .task { await usage.reload() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            refresh(); Task { await HttpStatisticsLane.shared.refresh(); await usage.reload(resetHour: resetHour) }
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now in
            let day = ReadingDay.date(at: now, resetHour: resetHour)
            if day != readingDate { refresh(); Task { await usage.reload(resetHour: resetHour) } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .usageLogChanged).receive(on: RunLoop.main).debounce(for: .milliseconds(200), scheduler: RunLoop.main)) { _ in Task { await usage.reload() } }
        .onReceive(NotificationCenter.default.publisher(for: .readingStatisticsChanged)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .hoshiLibraryChanged)) { _ in refresh() }
        .onChange(of: resetHour) { _, _ in refresh(); Task { await usage.reload(resetHour: resetHour) } }
        .onChange(of: zoneID) { _, _ in refresh(); Task { await usage.reload(resetHour: resetHour) } }
    }
    private func refresh() {
        readingDate = ReadingDay.date(at: .now, resetHour: resetHour)
        model.reload(resetHour: resetHour)
        loaded = true
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
        StreakSections(history: model.streakHistory, readingDate: readingDate, resetHour: resetHour, zoneID: zoneID)
        if model.books.isEmpty {
            if loaded {
                Section {
                    ContentUnavailableView("No Reading Yet", systemImage: "books.vertical",
                                           description: Text("No reading time recorded yet. Your history, charts and books appear here once you read."))
                }
            }
        } else {
            Section("All time") {
                LabeledContent("Reading time", value: StatisticsMath.readingTime(model.books.reduce(0.0) { StatisticsNumbers.adding($0, $1.seconds) }))
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
                        BookReadingRow(item: item)
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
}

/// The streak with today's progress, then the goal and what a reading day is.
private struct StreakSections: View {
    let history: (days: [DailyReading], estimated: Bool)
    let readingDate: Date
    let resetHour: Int
    let zoneID: String
    /// The goal while the slider moves; saving (and syncing) happens when it is released.
    @State private var draftGoal: Double?
    @AppStorage(ReadingDay.goalKey) private var goal = 10
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title2) private var flameSize = 34

    private static func minutes(_ value: Int) -> String { value == 1 ? "1 minute" : "\(value) minutes" }
    private static func hourLabel(_ hour: Int) -> String {
        let utc = StatisticsZone.calendar(zone: TimeZone(secondsFromGMT: 0)!)
        return StatisticsZone.display(ReadingDay.boundary(on: Date(timeIntervalSince1970: 0), resetHour: hour, calendar: utc), dateStyle: .none, timeStyle: .short, calendar: utc)
    }

    var body: some View {
        let goalMinutes = min(120, max(1, goal))
        let goalSeconds = Double(goalMinutes) * 60
        let streak = StatisticsMath.streak(history.days, goalMinutes: goalMinutes, resetHour: resetHour)
        // The streak's day, like Android: it includes the credit for records without hours.
        let todaySeconds = history.days.first { $0.date == readingDate }?.seconds ?? 0
        let reached = todaySeconds >= goalSeconds
        let onGoal = history.days.filter { $0.date <= readingDate && $0.seconds >= goalSeconds }.count
        let zone = StatisticsZone.zone(zoneID) ?? StatisticsZone.calendar.timeZone
        Section("Reading streak") {
            VStack(alignment: .leading, spacing: 14) {
                let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 14))
                layout {
                    Image(systemName: streak.current > 0 ? "flame.fill" : "flame")
                        .font(.system(size: flameSize))
                        .foregroundStyle(streak.current == 0 ? Color.secondary : reached ? Color.orange : Color.orange.opacity(0.55))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(streak.current > 0 ? "\(streak.current)-day streak" : streak.longest > 0 ? "No current streak" : "No streak yet").font(.title2.bold())
                        if streak.longest > 0 {
                            Text("Longest \(streak.longest == 1 ? "1 day" : "\(streak.longest) days") · \(onGoal) \(onGoal == 1 ? "day" : "days") on goal")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: min(todaySeconds / goalSeconds, 1)).tint(reached ? .orange : .accentColor)
                        .accessibilityLabel("Today's goal")
                        .accessibilityValue("\(Int(min(todaySeconds, goalSeconds) / 60)) of \(Self.minutes(goalMinutes))")
                    Text(reached && streak.current > 1 && streak.current == streak.longest ? "Today's goal reached · new record"
                         : reached ? "Today's goal reached"
                         : streak.current > 0 ? "\(StatisticsMath.readingTime(((goalSeconds - todaySeconds) / 60).rounded(.up) * 60)) more today keeps your streak"
                         : todaySeconds > 0 ? "\(StatisticsMath.readingTime(todaySeconds)) of \(StatisticsMath.readingTime(goalSeconds)) today"
                         : "Read \(StatisticsMath.readingTime(goalSeconds)) today to start a streak")
                        .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .padding(.vertical, 6)
            let shownGoal = Int(draftGoal ?? Double(goalMinutes))
            let large = typeSize.isAccessibilitySize
            VStack(alignment: .leading, spacing: 6) {
                (large ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout())) {
                    Text("Daily goal")
                    if !large { Spacer() }
                    Text(Self.minutes(shownGoal)).foregroundStyle(.secondary).monospacedDigit()
                }
                .accessibilityHidden(true)
                // Rounded here rather than with `step:`, which draws 119 tick marks under the track.
                Slider(value: Binding(get: { draftGoal ?? Double(goalMinutes) }, set: { draftGoal = $0.rounded() }), in: 1...120) {
                    Text("Daily goal")
                } minimumValueLabel: {
                    if !large { Text("1 min").font(.caption).foregroundStyle(.secondary) }
                } maximumValueLabel: {
                    if !large { Text("120 min").font(.caption).foregroundStyle(.secondary) }
                } onEditingChanged: { editing in
                    if !editing, let draftGoal { StatisticsPreferencesStore.choose(goal: Int(draftGoal)); self.draftGoal = nil }
                }
                .accessibilityValue(Self.minutes(shownGoal))
            }
        }
        Section {
            Picker("Day resets at", selection: Binding(get: { resetHour }, set: { StatisticsPreferencesStore.choose(reset: $0) })) {
                ForEach(0..<24, id: \.self) { hour in Text(Self.hourLabel(hour)).tag(hour) }
            }
            .accessibilityIdentifier("statistics-day-reset")
            LabeledContent("Time zone", value: StatisticsFormat.zoneName(zone))
                .accessibilityIdentifier("statistics-time-zone")
            // As on Android, a device elsewhere can move every device's days onto its own clock.
            if TimeZone.current.identifier != zone.identifier {
                Button("Count days in this device's time zone (\(StatisticsFormat.zoneName(.current)))") {
                    StatisticsPreferencesStore.choose(zone: TimeZone.current.identifier)
                }
            }
        } header: {
            Text("Reading day")
        } footer: {
            Text("Reading before \(Self.hourLabel(resetHour)) counts toward the previous day everywhere in your statistics. Every device counts days in \(StatisticsFormat.zoneName(zone)) (\(zone.identifier.replacingOccurrences(of: "_", with: " "))), whatever time zone it is set to."
                 + (history.estimated ? "\n\nEarlier history has no exact time, so your streak gets credit on either possible day; reading totals stay unchanged." : ""))
        }
    }
}

private struct BookReadingRow: View {
    let item: BookReadingSummary
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        let last = item.days.last { $0.seconds > 0 }?.date
        let details = [item.pages > 0 ? StatisticsFormat.count(item.pages, "page read", "pages read") : nil,
                       StatisticsFormat.count(item.characters, "character read", "characters read"),
                       last.map { "Last read \(StatisticsFormat.date($0))" },
                       item.book.folder == nil ? "Not on this device" : nil].compactMap { $0 }
        HStack(spacing: 12) {
            // At accessibility sizes the title and figures need the cover's width more than it does.
            if !typeSize.isAccessibilitySize { StatisticsBookCover(book: item.book, width: 40) }
            StatisticsSummaryRow(title: item.book.title ?? "Untitled", subtitle: details.joined(separator: " · "), value: StatisticsMath.readingTime(item.seconds))
        }
    }
}

private struct StatisticsBookCover: View {
    let book: BookMetadata
    let width: CGFloat
    var body: some View {
        Group {
            if let url = book.coverURL, let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "book.closed").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.tertiarySystemFill))
            }
        }
        .frame(width: width, height: width * 1.4)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityHidden(true)
    }
}

struct BookStatisticsDetailView: View {
    let bookId: UUID
    @State private var model = StatisticsOverview()
    @State private var showAllHistory = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage(ReadingDay.resetKey) private var resetHour = 3
    @AppStorage(StatisticsZone.key) private var zoneID = StatisticsZone.defaultID
    private var item: BookReadingSummary? { model.books.first { $0.id == bookId } }
    var body: some View {
        List {
            if let item {
                let days = item.days
                let read = days.filter { $0.seconds > 0 }
                Section {
                    HStack(spacing: 14) {
                        if !typeSize.isAccessibilitySize { StatisticsBookCover(book: item.book, width: 56) }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Reading time").font(.subheadline).foregroundStyle(.secondary)
                            Text(StatisticsMath.readingTime(item.seconds)).font(.largeTitle.weight(.semibold)).monospacedDigit()
                            Text([item.isManga ? StatisticsFormat.count(item.pages, "page", "pages") : nil,
                                  StatisticsFormat.count(item.characters, "character", "characters")].compactMap { $0 }.joined(separator: " · "))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .padding(.vertical, 4)
                } footer: {
                    if item.book.folder == nil { Text("Not on this device") }
                }
                Section("Details") {
                    if let first = read.first { LabeledContent("Started", value: StatisticsFormat.date(first.date)) }
                    if let last = read.last {
                        LabeledContent(item.finished ? "Finished" : "Last read", value: StatisticsFormat.date(last.date))
                    }
                    LabeledContent("Days read", value: read.count.formatted())
                    if !read.isEmpty { LabeledContent("Average per day", value: StatisticsMath.readingTime(item.seconds / Double(read.count))) }
                    if let best = read.max(by: { $0.seconds < $1.seconds }) {
                        LabeledContent("Best day", value: "\(StatisticsFormat.date(best.date)) · \(StatisticsMath.readingTime(best.seconds))")
                    }
                    let count = item.isManga ? item.pages : item.characters
                    LabeledContent(item.isManga ? "Pages per hour" : "Characters per hour", value: StatisticsNumbers.speed(count: count, seconds: item.seconds).formatted())
                    if count > 0 {
                        LabeledContent(item.isManga ? "Time per page" : "Time per 100 characters",
                                       value: StatisticsMath.readingTime(item.seconds / Double(count) * (item.isManga ? 1 : 100)))
                    }
                }
                Section("Last 16 weeks") { ReadingHeatmap(days: days) }
                DeviceReadingSection(devices: item.devices)
                Section("History") {
                    let history = Array(read.reversed())
                    ForEach(showAllHistory ? history : Array(history.prefix(7))) { day in
                        StatisticsSummaryRow(title: StatisticsFormat.weekdayDay(day.date),
                                             subtitle: day.characters > 0 ? StatisticsFormat.count(day.characters, "character", "characters") : nil,
                                             value: StatisticsMath.readingTime(day.seconds), titleLines: 1)
                            .accessibilityElement(children: .combine)
                    }
                    if history.count > 7 {
                        Button(showAllHistory ? "Show Fewer" : "Show All \(history.count) Days") { withAnimation { showAllHistory.toggle() } }
                    }
                }
            }
        }
        .modifier(StatisticsReadableWidth())
        .environment(\.calendar, StatisticsZone.calendar)
        .environment(\.timeZone, StatisticsZone.calendar.timeZone)
        .navigationTitle(item?.book.title ?? "Book")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.reload(resetHour: resetHour) }
        .onChange(of: resetHour) { _, _ in model.reload(resetHour: resetHour) }
        .onChange(of: zoneID) { _, _ in model.reload(resetHour: resetHour) }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in model.reload(resetHour: resetHour) }
        .onReceive(NotificationCenter.default.publisher(for: .readingStatisticsChanged)) { _ in model.reload(resetHour: resetHour) }
    }
}

/// One row per device, as on Android: name, what it read, and its reading time.
struct DeviceReadingSection: View {
    let devices: [DeviceReadingSummary]
    var showBookCount = false
    var body: some View {
        if !devices.isEmpty {
            Section("By device") {
                ForEach(devices) { device in
                    let name = device.name ?? "Earlier history"
                    let details = [device.pages > 0 ? StatisticsFormat.count(device.pages, "page read", "pages read") : nil,
                                   StatisticsFormat.count(device.characters, "character read", "characters read"),
                                   device.lastRead.map { "Last read \(StatisticsFormat.date($0))" },
                                   showBookCount ? StatisticsFormat.count(device.books, "book", "books") : nil].compactMap { $0 }
                    StatisticsSummaryRow(title: device.deviceId == ReadingDevice.current.id ? "\(name) · This device" : name,
                                         subtitle: details.joined(separator: " · "), value: StatisticsMath.readingTime(device.seconds))
                        .accessibilityElement(children: .combine)
                }
            }
        }
    }
}
