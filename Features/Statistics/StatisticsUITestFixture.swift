#if DEBUG
import SwiftUI

/// Synthetic data for native statistics UI checks; enabled only by the test runner. Four books read on
/// three devices over four months, today's sessions running past midnight, repeated lookups and manga
/// activity. HOSHI_UI_TESTING_STATISTICS_EMPTY=1 shows a fresh install instead.
struct StatisticsUITestFixture: View {
    @State private var ready = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            if ready { StatisticsOverviewView() }
            else if let error { Text(error) }
            else { ProgressView("Preparing statistics") }
        }
        .task {
            guard !ready else { return }
            do {
                try await Self.seed(empty: ProcessInfo.processInfo.environment["HOSHI_UI_TESTING_STATISTICS_EMPTY"] == "1")
                ready = true
            } catch { self.error = error.localizedDescription }
        }
    }

    private struct Book { let id: String, title: String, manga: Bool }
    private static let books = [Book(id: "ui-history", title: "Retained reading history", manga: false),
                                Book(id: "ui-kusuriya", title: "薬屋のひとりごと 1", manga: false),
                                Book(id: "ui-yotsuba", title: "よつばと！ 3", manga: true),
                                Book(id: "ui-konbini", title: "コンビニ人間 — a considerably longer English subtitle to test wrapping", manga: false)]
    private static let words = ["猫", "曖昧", "気配", "呟く", "仕草", "結局", "眩しい"]

    private static func seed(empty: Bool) async throws {
        // Every launch starts from the same synthetic history, not from the previous run's.
        let history = try BookStorage.getBooksDirectory().appendingPathComponent(StatisticsHistory.directoryName)
        for folder in (try? FileManager.default.contentsOfDirectory(at: history, includingPropertiesForKeys: nil)) ?? [] where folder.lastPathComponent.hasPrefix("ui-") {
            try FileManager.default.removeItem(at: folder)
        }
        if FileManager.default.fileExists(atPath: UsageLog.shared.directory.path) { try FileManager.default.removeItem(at: UsageLog.shared.directory) }
        guard !empty else { return }

        let now = Date(), calendar = StatisticsZone.calendar, zone = calendar.timeZone
        let today = ReadingDay.date(at: now, resetHour: 3, calendar: calendar)
        let stamp = Int(now.timeIntervalSince1970 * 1000)
        let devices = [ReadingDevice(id: "android-ui", name: "Pixel Tablet"), ReadingDevice(id: "iphone-ui", name: "Dragos’s iPhone"), ReadingDevice.current]
        var rows: [String: [String: Statistics]] = [:], text: [String: [String: MangaTextStatistic]] = [:]
        var logs: [String: [String: Data]] = [:]
        var random = UInt64(7)
        func next(_ range: ClosedRange<Int>) -> Int {
            random = random &* 6364136223846793005 &+ 1442695040888963407
            return range.lowerBound + Int((random >> 33) % UInt64(range.count))
        }
        func event(_ type: UsageEventType, _ at: Date, _ book: Book, _ session: String, device: ReadingDevice, term: String? = nil, startedAt: Date? = nil) {
            let offset = zone.secondsFromGMT(for: at)
            var value = UsageEvent(at: Int64(at.timeIntervalSince1970 * 1000), utcOffset: String(format: "%@%02d:%02d", offset < 0 ? "-" : "+", abs(offset) / 3600, abs(offset) % 3600 / 60), type: type)
            value.session = session; value.bookTitle = book.title; value.contentType = book.manga ? "manga" : "epub"
            value.term = term; value.source = "page"; value.outcome = term == nil ? nil : "found"
            value.startedAt = startedAt.map { Int64($0.timeIntervalSince1970 * 1000) }
            let folder = device.id == ReadingDevice.current.id ? "" : device.id
            logs[folder, default: [:]][ReadingDay.key(at, calendar: calendar), default: Data()].append(try! JSONEncoder().encode(value) + Data([10]))
        }
        /// One reading session: statistics by hour, as the reader records them, and its usage events.
        func read(_ book: Book, on device: ReadingDevice, from start: Date, minutes: Int, seconds: Int = 0, lookups: [String] = [], logged: Bool) {
            let end = start.addingTimeInterval(Double(minutes * 60 + seconds))
            for (hour, seconds) in ReadingDay.hours(from: start, to: end, calendar: calendar) {
                let day = String(hour.prefix(10)), key = day + "|" + device.id
                var row = rows[book.id]?[key] ?? Statistics.empty(title: book.title, day: day, device: device)
                row.readingTime += seconds; row.readingTimeByHour[hour, default: 0] += seconds
                row.charactersRead += Int(seconds / 60 * (book.manga ? 1.3 : 156))
                row.lastStatisticModified = stamp; row.timeZone = zone.identifier
                rows[book.id, default: [:]][key] = row
                if book.manga {
                    var line = text[book.id]?[key] ?? MangaTextStatistic(dateKey: day, deviceId: device.id, deviceName: device.name)
                    line.charactersRead += Int(seconds / 60 * 48); line.lastModified = stamp
                    text[book.id, default: [:]][key] = line
                }
            }
            guard logged else { return }
            let session = book.id + "-" + String(Int(start.timeIntervalSince1970))
            event(.opened, start, book, session, device: device)
            event(.started, start, book, session, device: device)
            for page in 0..<(minutes * 2 / 3) { event(.page, start.addingTimeInterval(Double(page) * 90 + 30), book, session, device: device) }
            for (index, word) in lookups.enumerated() {
                let at = start.addingTimeInterval(Double(minutes * 60) * Double(index + 1) / Double(lookups.count + 1))
                event(.lookup, at, book, session, device: device, term: word)
                if book.manga {
                    for reveal in 0..<next(1...4) { event(.revealed, at.addingTimeInterval(-Double(reveal + 2) * 4), book, session, device: device) }
                    if index % 3 == 0 { event(.translated, at.addingTimeInterval(2), book, session, device: device) }
                    if index % 5 == 0 { event(.screenshot, at.addingTimeInterval(4), book, session, device: device) }
                }
            }
            event(.stopped, end, book, session, device: device, startedAt: start)
        }
        func at(_ day: Date, _ hour: Int, _ minute: Int) -> Date {
            calendar.date(byAdding: .minute, value: hour * 60 + minute, to: day)!
        }

        // Today, from the morning until after midnight.
        let morning = (0..<11).map { words[$0 % 5] } + ["猫", "猫", "曖昧", "気配"]
        read(books[1], on: devices[2], from: at(today, 9, 10), minutes: 32, seconds: 39, lookups: morning + ["猫", "呟く", "仕草"], logged: true)
        read(books[2], on: devices[0], from: at(today, 13, 0), minutes: 25, lookups: ["猫", "曖昧", "気配", "猫", "曖昧", "気配", "仕草", "呟く", "猫", "曖昧", "気配"], logged: true)
        read(books[2], on: devices[0], from: at(today, 22, 30), minutes: 45, lookups: ["猫", "曖昧", "気配", "猫", "曖昧", "気配", "猫", "曖昧", "仕草", "呟く", "結局"], logged: true)
        read(books[1], on: devices[2], from: at(today, 24, 52), minutes: 32, lookups: ["猫", "猫", "曖昧", "気配", "仕草", "呟く", "眩しい"], logged: true)
        // Four months before it; the usage log only covers the last two, some of them without manga.
        for back in 1...120 where next(0...9) < 8 {
            let day = ReadingDay.shift(today, by: -back, calendar: calendar)
            for session in 0..<next(1...2) {
                let book = books[next(0...3)], device = devices[next(0...2)]
                let lookups = (0..<next(0...8)).map { _ in words[next(0...6)] }
                read(book, on: device, from: at(day, session == 0 ? next(7...12) : next(18...23), next(0...59)), minutes: next(8...70), lookups: lookups, logged: back <= 60)
            }
        }

        for book in books {
            let root = try StatisticsHistory.historyRoot(book.id, title: book.title, type: book.manga ? .mokuro : .epub)
            try ReadingStatisticsStore.save(Array(rows[book.id, default: [:]].values), root: root, scheduleSync: false)
            if book.manga { try ReadingStatisticsStore.saveText(Array(text[book.id, default: [:]].values), root: root, scheduleSync: false) }
        }
        for (device, days) in logs { try await UsageLog.shared.store(days: days, device: device.isEmpty ? nil : device, mergeOwn: false) }
    }
}
#endif
