import Foundation

/// Keep per-source contributions so a changed sidecar updates only the reading days it affected.
private nonisolated struct CachedReadingDays<Source: Hashable & Sendable>: Sendable {
    private var contributions: [Date: [Source: DailyReading]] = [:]
    private(set) var days: [DailyReading] = []

    mutating func replace(source: Source, old: [DailyReading], new: [DailyReading], dirty: inout Set<Date>) {
        for day in old {
            contributions[day.date]?[source] = nil
            dirty.insert(day.date)
        }
        for day in new {
            contributions[day.date, default: [:]][source] = day
            dirty.insert(day.date)
        }
    }

    mutating func refresh(_ dirty: Set<Date>) -> Set<Date> {
        guard !dirty.isEmpty else { return [] }
        var secondsChanged: Set<Date> = []
        var updated: [Date: DailyReading] = [:]
        for date in dirty {
            let index = days.lowerBound(for: date)
            let previous = index < days.count && days[index].date == date ? days[index].seconds : 0
            if let rows = contributions[date], !rows.isEmpty {
                let next = DailyReading(date: date,
                    seconds: rows.values.reduce(0) { StatisticsNumbers.adding($0, $1.seconds) },
                    characters: rows.values.reduce(0) { StatisticsNumbers.adding($0, $1.characters) })
                updated[date] = next
                if next.seconds != previous { secondsChanged.insert(date) }
            } else {
                contributions[date] = nil
                if previous > 0 { secondsChanged.insert(date) }
            }
        }
        if dirty.count <= 3 {
            for date in dirty.sorted() {
                let index = days.lowerBound(for: date)
                let exists = index < days.count && days[index].date == date
                if let day = updated[date] {
                    if exists { days[index] = day } else { days.insert(day, at: index) }
                } else if exists { days.remove(at: index) }
            }
        } else {
            days = (days.filter { !dirty.contains($0.date) } + updated.values).sorted { $0.date < $1.date }
        }
        return secondsChanged
    }
}

nonisolated extension Array where Element == DailyReading {
    func lowerBound(for date: Date) -> Int {
        var lower = 0, upper = count
        while lower < upper {
            let mid = lower + (upper - lower) / 2
            if self[mid].date < date { lower = mid + 1 } else { upper = mid }
        }
        return lower
    }
}

nonisolated struct StatisticsOverviewSnapshot: Sendable {
    /// Each source calendar date can contribute to multiple displayed days around midnight and the reset.
    nonisolated final class DateTotals: Sendable {
        let reading: [Statistics]
        let text: [MangaTextStatistic]
        let days: [DailyReading]
        let devices: [DeviceReadingSummary]

        init(reading: [Statistics], text: [MangaTextStatistic], manga: Bool, resetHour: Int, calendar: Calendar) {
            self.reading = reading; self.text = text
            days = ReadingDay.days(reading: reading, text: manga ? text : nil, resetHour: resetHour, calendar: calendar)
            devices = StatisticsMath.devices(reading: reading, text: text, isManga: manga, resetHour: resetHour, calendar: calendar)
        }
    }

    nonisolated struct CachedBook: Sendable {
        fileprivate let root: URL
        fileprivate let readingStamp: HttpStatisticsPreparedBook.Stamp?
        fileprivate let textStamp: HttpStatisticsPreparedBook.Stamp?
        fileprivate var aggregate = CachedReadingDays<String>()
        fileprivate(set) var sourceDates: [String: DateTotals] = [:]
        fileprivate var summary: BookReadingSummary
    }

    private(set) var books: [BookReadingSummary]
    private(set) var days: [DailyReading]
    private(set) var devices: [DeviceReadingSummary]
    private(set) var historyRevision = UUID()
    private(set) var cachedBooks: [String: CachedBook] = [:]
    private var directory: URL?
    private var resetHour: Int?
    private var calendar: Calendar?
    private var cutoff: Date?
    private var aggregate = CachedReadingDays<String>()
    var maintenance: [URL] = []
    var needsAbsorb = false

    init(books: [BookReadingSummary]) {
        self.books = books
        days = StatisticsMath.combine(books.flatMap(\.days))
        devices = StatisticsMath.combineDevices(books.flatMap(\.devices))
    }

    private struct FinishInfo: Decodable { let characterCount: Int }

    @concurrent static func read(directory: URL, resetHour: Int, calendar: Calendar,
                                reusing previous: Self? = nil, now: Date = .now) async -> Self {
        let disk = await HttpStatisticsDisk.read(booksDirectory: directory, stateFile: HttpReadingStatisticsSync.stateFile)
        let decoder = JSONDecoder(), manager = FileManager.default
        func load<T: Decodable>(_ type: T.Type, root: URL, name: String) -> T? {
            (try? Data(contentsOf: root.appendingPathComponent(name))).flatMap { try? decoder.decode(type, from: $0) }
        }

        let reused = previous.flatMap { old in
            old.directory == directory && old.resetHour == resetHour && old.calendar == calendar ? old : nil
        }
        var snapshot = reused ?? Self(books: [])
        var nextBooks: [String: CachedBook] = [:]
        var dirty: Set<Date> = []
        for item in disk.roots {
            guard !Task.isCancelled else { return snapshot }
            var book = StatisticsHistory.metadata(for: item)
            let isManga = item.book == nil ? item.contentType == .mokuro : ContentType.detect(bookDir: item.root) == .mokuro
            book.contentType = isManga ? .mokuro : .epub
            let finished: Bool
            if item.book == nil { finished = (load(StatisticsHistoryInfo.self, root: item.root, name: "history.json")?.progress ?? 0) >= 0.999 }
            else if let bookmark = load(Bookmark.self, root: item.root, name: FileNames.bookmark) {
                let info = load(FinishInfo.self, root: item.root, name: FileNames.bookinfo)
                if let total = info?.characterCount, total > 0 { finished = Double(bookmark.characterCount) / Double(total) >= 0.999 }
                else { finished = isManga && bookmark.progress >= 0.999 }
            } else { finished = false }

            let prior = snapshot.cachedBooks[item.syncId]
            let readingStamp = HttpStatisticsPreparedBook.Stamp.read(item.root.appendingPathComponent(FileNames.statistics))
            let textStamp = isManga ? HttpStatisticsPreparedBook.Stamp.read(item.root.appendingPathComponent(FileNames.mangaStatistics)) : nil
            let sameRoot = prior?.root == item.root && prior?.summary.isManga == isManga
            if var unchanged = prior, sameRoot, unchanged.readingStamp == readingStamp, unchanged.textStamp == textStamp {
                unchanged.summary.book = book
                unchanged.summary.finished = finished
                nextBooks[item.syncId] = unchanged
                continue
            }

            // Sidecars are cumulative JSON. A changed file is decoded once; compare its source dates
            // with the cached inputs before doing calendar allocation or calculating device totals.
            let reading = sameRoot && prior?.readingStamp == readingStamp ? prior!.summary.reading
                : Statistics.merged(load([Statistics].self, root: item.root, name: FileNames.statistics) ?? [])
            let text: [MangaTextStatistic]
            if !isManga { text = [] }
            else if sameRoot && prior?.textStamp == textStamp { text = prior!.summary.mangaText }
            else { text = MangaTextStatistic.merged(load([MangaTextStatistic].self, root: item.root, name: FileNames.mangaStatistics) ?? []) }
            let byDate = Dictionary(grouping: reading, by: \.dateKey)
            let textByDate = Dictionary(grouping: text, by: \.dateKey)
            let priorDates = prior?.sourceDates ?? [:]
            let sourceKeys = Set(byDate.keys).union(textByDate.keys).union(priorDates.keys)
            var nextDates: [String: DateTotals] = [:]
            var bookAggregate = prior?.aggregate ?? CachedReadingDays<String>()
            var bookDirty: Set<Date> = []
            for key in sourceKeys {
                let old = priorDates[key]
                let rows = byDate[key] ?? [], textRows = textByDate[key] ?? []
                if let old, sameRoot, old.reading == rows, old.text == textRows {
                    nextDates[key] = old
                    continue
                }
                let next = rows.isEmpty && textRows.isEmpty ? nil
                    : DateTotals(reading: rows, text: textRows, manga: isManga, resetHour: resetHour, calendar: calendar)
                nextDates[key] = next
                bookAggregate.replace(source: key, old: old?.days ?? [], new: next?.days ?? [], dirty: &bookDirty)
            }
            _ = bookAggregate.refresh(bookDirty)
            var devices = StatisticsMath.combineDevices(nextDates.keys.sorted().flatMap { nextDates[$0]!.devices })
            for index in devices.indices { devices[index].books = 1 }
            let summary = BookReadingSummary(book: book, reading: reading, mangaText: text, finished: finished,
                resetHour: resetHour, calendar: calendar, days: bookAggregate.days, devices: devices)
            nextBooks[item.syncId] = CachedBook(root: item.root, readingStamp: readingStamp, textStamp: textStamp,
                aggregate: bookAggregate, sourceDates: nextDates, summary: summary)

            // Only replace this book's contributions where its reduced reading days changed.
            let oldDays = prior?.summary.days ?? []
            let before = bookDirty.compactMap { date -> DailyReading? in
                let index = oldDays.lowerBound(for: date)
                return index < oldDays.count && oldDays[index].date == date ? oldDays[index] : nil
            }
            let after = bookDirty.compactMap { date -> DailyReading? in
                let index = summary.days.lowerBound(for: date)
                return index < summary.days.count && summary.days[index].date == date ? summary.days[index] : nil
            }
            snapshot.aggregate.replace(source: item.syncId, old: before, new: after, dirty: &dirty)
        }
        for (id, old) in snapshot.cachedBooks where nextBooks[id] == nil {
            snapshot.aggregate.replace(source: id, old: old.summary.days, new: [], dirty: &dirty)
        }

        let secondsChanged = snapshot.aggregate.refresh(dirty)
        let today = ReadingDay.date(at: now, resetHour: resetHour, calendar: calendar)
        let cutoff = ReadingDay.shift(today, by: -2, calendar: calendar)
        if let priorCutoff = snapshot.cutoff, secondsChanged.contains(where: { $0 < max(priorCutoff, cutoff) }) {
            snapshot.historyRevision = UUID()
        }
        snapshot.cutoff = cutoff
        snapshot.directory = directory
        snapshot.resetHour = resetHour
        snapshot.calendar = calendar
        snapshot.cachedBooks = nextBooks
        snapshot.books = nextBooks.values.map(\.summary).filter { $0.seconds > 0 || $0.characters > 0 || $0.pages > 0 }
            .sorted { $0.seconds == $1.seconds ? $0.id.uuidString < $1.id.uuidString : $0.seconds > $1.seconds }
        snapshot.days = snapshot.aggregate.days
        snapshot.devices = StatisticsMath.combineDevices(snapshot.books.flatMap(\.devices))
        snapshot.needsAbsorb = disk.needsAbsorb
        snapshot.maintenance = disk.roots.filter { !manager.fileExists(atPath: $0.root.appendingPathComponent(ReadingStatisticsStore.migration).path) }.map(\.root)
        return snapshot
    }
}

