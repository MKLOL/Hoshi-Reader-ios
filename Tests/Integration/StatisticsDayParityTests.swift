import XCTest
import CryptoKit
@testable import Hoshi_Reader

nonisolated final class StatisticsDayParityTests: XCTestCase {
    private var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = .current; return value }
    private func date(_ day: String, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: ReadingDay.parse(day, calendar: calendar)!)!
    }
    private func row(_ day: String, seconds: Double, count: Int = 10, hours: [String: Double] = [:], device: String = "phone", stamp: Int = 1) -> Statistics {
        var result = Statistics.empty(title: "Fixture", day: day, device: ReadingDevice(id: device, name: device))
        result.readingTime = seconds; result.charactersRead = count; result.readingTimeByHour = hours; result.lastStatisticModified = stamp
        return result
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    func testNewSettingsDefaultToThreeAndMidnightRemainsAValidChoice() {
        let suite = "StatisticsDayParityTests." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ReadingDay.resetHour(defaults: defaults), 3)
        defaults.set(0, forKey: ReadingDay.resetKey)
        XCTAssertEqual(ReadingDay.resetHour(defaults: defaults), 0)
        defaults.set(24, forKey: ReadingDay.resetKey)
        XCTAssertEqual(ReadingDay.resetHour(defaults: defaults), 23)
        XCTAssertEqual(ReadingDay.date(at: date("2026-10-01", 2, 59), resetHour: 3), date("2026-09-30"))
        XCTAssertEqual(ReadingDay.date(at: date("2026-10-01", 3), resetHour: 3), date("2026-10-01"))
    }
    func testADayWithoutAMidnightStillCounts() throws {
        var santiago = Calendar(identifier: .gregorian); santiago.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Santiago"))
        let day = try XCTUnwrap(ReadingDay.parse("2026-09-06", calendar: santiago))
        XCTAssertEqual(ReadingDay.key(day, calendar: santiago), "2026-09-06")
        let morning = try XCTUnwrap(santiago.date(bySettingHour: 10, minute: 0, second: 0, of: day))
        XCTAssertEqual(ReadingDay.date(at: morning, resetHour: 3, calendar: santiago), day)
        var reading = row("2026-09-06", seconds: 1200, hours: ["2026-09-06T10:00": 1200])
        reading.timeZone = "America/Santiago"
        XCTAssertEqual(ReadingDay.days(reading: [reading], resetHour: 3, calendar: santiago).map(\.seconds), [1200])
        XCTAssertEqual(ReadingDay.streakHistory([reading], resetHour: 3, calendar: santiago).days.map(\.date), [day])
        XCTAssertNil(ReadingDay.parse("2026-02-30", calendar: santiago))
    }
    func testStreaksAndResetHoursCrossDaysWithMissingOrRepeatedMidnights() throws {
        // Santiago has no 2026-09-06 00:00; Havana repeats 2026-11-01 00:00.
        for (zone, keys) in [("America/Santiago", ["2026-09-05", "2026-09-06", "2026-09-07"]),
                             ("America/Havana", ["2026-10-31", "2026-11-01", "2026-11-02"])] {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
            let days = try keys.map { try XCTUnwrap(ReadingDay.parse($0, calendar: calendar)) }
            for (earlier, later) in zip(days, days.dropFirst()) {
                XCTAssertEqual(ReadingDay.shift(earlier, by: 1, calendar: calendar), later, zone)
                XCTAssertEqual(ReadingDay.shift(later, by: -1, calendar: calendar), earlier, zone)
                let beforeReset = try XCTUnwrap(calendar.date(byAdding: .hour, value: 1, to: later))
                XCTAssertEqual(ReadingDay.date(at: beforeReset, resetHour: 3, calendar: calendar), earlier, zone)
            }
            let rows = keys.map { key -> Statistics in
                var reading = row(key, seconds: 1200, hours: [key + "T10:00": 1200])
                reading.timeZone = zone
                return reading
            }
            let history = ReadingDay.streakHistory(rows, resetHour: 3, calendar: calendar)
            let noon = try XCTUnwrap(calendar.date(byAdding: .hour, value: 12, to: days[2]))
            let streak = StatisticsMath.streak(history.days, goalMinutes: 10, now: noon, resetHour: 3, calendar: calendar)
            XCTAssertEqual(streak.current, 3, zone)
            XCTAssertEqual(streak.longest, 3, zone)
        }
    }
    func testEqualStampRowsDifferingOnlyInZoneMergeInEitherOrderLikeAndroid() {
        var tokyo = row("2026-10-01", seconds: 60, hours: ["2026-10-01T10:00": 60])
        tokyo.timeZone = "Asia/Tokyo"
        var newYork = tokyo
        newYork.timeZone = "America/New_York"
        XCTAssertEqual(Statistics.merged([tokyo, newYork]), [tokyo])
        XCTAssertEqual(Statistics.merged([newYork, tokyo]), [tokyo])
    }
    func testLegacyJSONAndAndroidHourEvidenceRoundTripWithoutLosingFields() throws {
        let legacy = Data(#"{"title":"Fixture","dateKey":"2026-10-01","readingTime":600,"charactersRead":10}"#.utf8)
        XCTAssertTrue(try JSONDecoder().decode(Statistics.self, from: legacy).readingTimeByHour.isEmpty)
        let exact = row("2026-10-01", seconds: 600, hours: ["2026-10-01T01:00": 600])
        let encoded = try JSONEncoder().encode(exact)
        let decoded = try JSONDecoder().decode(Statistics.self, from: encoded)
        XCTAssertEqual(decoded, exact)
        XCTAssertEqual(ReadingDay.days(reading: [decoded], resetHour: 3).first?.date, date("2026-09-30"))
        XCTAssertEqual(ReadingDay.streakHistory([decoded], resetHour: 3).days.first?.date, date("2026-09-30"))
    }
    func testEqualStampOlderClientsCannotStripMoreCompleteTimingEvidence() {
        let exact = row("2026-10-01", seconds: 600, hours: ["2026-10-01T01:00": 600])
        var stripped = exact; stripped.readingTimeByHour = [:]
        XCTAssertEqual(Statistics.merged([exact, stripped]), [exact])
        XCTAssertEqual(Statistics.merged([stripped, exact]), [exact])
        var newer = stripped; newer.lastStatisticModified = 2
        XCTAssertEqual(Statistics.merged([exact, newer]), [newer])
    }
    @MainActor func testAllBookHistoryDeviceLastReadAndTrendsUseOneReadingDay() {
        let rows = [row("2026-09-30", seconds: 600, count: 100, hours: ["2026-09-30T22:00": 600]),
                    row("2026-10-01", seconds: 900, count: 150, hours: ["2026-10-01T01:00": 900])]
        let book = BookMetadata(title: "Fixture", cover: nil, folder: "fixture", lastAccess: .now, contentType: .epub)
        let summary = BookReadingSummary(book: book, reading: rows, mangaText: [], finished: false, resetHour: 3)
        XCTAssertEqual(summary.days.count, 1)
        XCTAssertEqual(summary.days[0].date, date("2026-09-30"))
        XCTAssertEqual(summary.days[0].seconds, 1500)
        XCTAssertEqual(summary.days[0].characters, 250)
        XCTAssertEqual(summary.devices.first?.lastRead, date("2026-09-30"))
        let points = ReadingTrends.series(values: [summary.days[0].date: 25], days: 1, now: date("2026-10-01", 1), resetHour: 3)
        XCTAssertEqual(points[0].date, date("2026-09-30")); XCTAssertEqual(points[0].value, 25)
        let overview = StatisticsOverview(); overview.books = [summary]
        XCTAssertEqual(overview.days[0].seconds, 1500)
        XCTAssertEqual(StatisticsMath.streak(overview.streakHistory.days, goalMinutes: 25, now: date("2026-10-01", 1), resetHour: 3).current, 1)
        XCTAssertEqual(StatisticsMath.streak(overview.streakHistory.days, goalMinutes: 26, now: date("2026-10-01", 1), resetHour: 3).current, 0)
    }
    func testLegacyStreakIsOptimisticButDisplayedTotalsAreNeverDuplicated() {
        let legacy = row("2026-10-01", seconds: 600, count: 19)
        let history = ReadingDay.streakHistory([legacy], resetHour: 3)
        XCTAssertTrue(history.estimated)
        XCTAssertEqual(history.days.map(\.date), [date("2026-09-30"), date("2026-10-01")])
        XCTAssertEqual(StatisticsMath.streak(history.days, goalMinutes: 10, now: date("2026-10-01", 4), resetHour: 3).current, 2)
        let totals = ReadingDay.days(reading: [legacy], resetHour: 3)
        XCTAssertEqual(totals.count, 1); XCTAssertEqual(totals[0].seconds, 600); XCTAssertEqual(totals[0].characters, 19)
        XCTAssertFalse(ReadingDay.streakHistory([legacy], resetHour: 0).estimated)
        XCTAssertEqual(ReadingDay.streakHistory([legacy], resetHour: 0).days.count, 1)
    }
    func testPartialUnknownTimingAndMangaCharactersKeepTotalsWithLargestRemainderRounding() {
        let reading = [row("2026-10-01", seconds: 90, count: 3, hours: ["2026-10-01T01:00": 30, "2026-10-01T04:00": 30])]
        let text = [MangaTextStatistic(dateKey: "2026-10-01", charactersRead: 7, deviceId: "phone")]
        let days = ReadingDay.days(reading: reading, text: text, resetHour: 3)
        XCTAssertEqual(days.map(\.seconds), [30, 60])
        XCTAssertEqual(days.map(\.characters), [2, 5])
        XCTAssertEqual(days.reduce(0) { $0 + $1.characters }, 7)
        XCTAssertEqual(ReadingDay.days(reading: reading, resetHour: 3).map(\.characters), [1, 2])
        let noTime = ReadingDay.days(reading: [], text: text, resetHour: 3)
        XCTAssertEqual(noTime[0].date, date("2026-10-01")); XCTAssertEqual(noTime[0].characters, 7)
    }
    func testMidnightResetKeepsCalendarRowsAndMalformedHoursCannotInflateTotals() {
        let crossing = row("2026-10-01", seconds: 60, hours: ["2026-09-30T23:00": 30, "2026-10-01T00:00": 30])
        XCTAssertEqual(ReadingDay.days(reading: [crossing], resetHour: 0).map(\.date), [date("2026-10-01")])
        let malformed = row("2026-10-01", seconds: 60, hours: ["2026-10-01T01:00": 600, "invalid": 30, "2020-01-01T01:00": 50])
        let days = ReadingDay.days(reading: [malformed], resetHour: 3)
        XCTAssertEqual(days.reduce(0) { $0 + $1.seconds }, 60)
        XCTAssertEqual(days.map(\.date), [date("2026-09-30")])
    }
    func testTrackerRecordsBothHoursAcrossMidnightAndReadsLiveResetSetting() {
        let start = date("2026-09-30", 23, 59), end = date("2026-10-01", 0, 1)
        var tracker = MangaStatisticsTracker(title: "Fixture", initialStatistics: [], enabled: true, now: start, device: ReadingDevice(id: "phone", name: "Phone"))
        tracker.start(currentPage: 0, now: start); tracker.pause(currentPage: 2, now: end)
        let saved = tracker.statisticsForPersistence()!
        XCTAssertEqual(saved.first { $0.dateKey == "2026-10-01" }?.readingTimeByHour, ["2026-09-30T23:00": 60, "2026-10-01T00:00": 60])
        XCTAssertEqual(tracker.dayTotal(at: end, resetHour: 3).readingTime, 120)
        XCTAssertEqual(tracker.dayTotal(at: date("2026-10-01", 3), resetHour: 3).readingTime, 0)
        XCTAssertEqual(tracker.dayTotal(at: date("2026-10-01", 3), resetHour: 0).readingTime, 120)
        XCTAssertEqual(tracker.allTime.readingTime, 120)
        let text = [MangaTextStatistic(dateKey: "2026-10-01", charactersRead: 12, deviceId: "phone")]
        XCTAssertEqual(tracker.textTotal(text, at: end, resetHour: 3), 12)
        XCTAssertEqual(tracker.textTotal(text, at: date("2026-10-01", 3), resetHour: 3), 0)
    }
    func testISOHistoryKeepsGregorianDatesUnderOtherSystemCalendars() {
        var buddhist = Calendar(identifier: .buddhist); buddhist.timeZone = calendar.timeZone
        let expected = date("2026-10-01")
        XCTAssertEqual(ReadingDay.parse("2026-10-01", calendar: buddhist), expected)
        XCTAssertEqual(ReadingDay.key(expected, calendar: buddhist), "2026-10-01")
        XCTAssertEqual(ReadingDay.hour("2026-10-01T01:00", calendar: buddhist)?.date, expected)
        XCTAssertEqual(ReadingDay.days(reading: [row("2026-10-01", seconds: 60, hours: ["2026-10-01T01:00": 60])], resetHour: 3, calendar: buddhist).first?.date, date("2026-09-30"))
    }
    func testDSTBoundariesUseCalendarDaysAndRepeatedHourKeepsElapsedSeconds() {
        var eastern = Calendar(identifier: .gregorian); eastern.timeZone = TimeZone(identifier: "America/New_York")!
        let spring = ReadingDay.parse("2026-03-07", calendar: eastern)!, springNext = eastern.date(byAdding: .day, value: 1, to: spring)!
        XCTAssertEqual(ReadingDay.boundary(on: springNext, resetHour: 3, calendar: eastern).timeIntervalSince(ReadingDay.boundary(on: spring, resetHour: 3, calendar: eastern)), 23 * 3600)
        let fall = ReadingDay.parse("2026-10-31", calendar: eastern)!, fallNext = eastern.date(byAdding: .day, value: 1, to: fall)!
        XCTAssertEqual(ReadingDay.boundary(on: fallNext, resetHour: 3, calendar: eastern).timeIntervalSince(ReadingDay.boundary(on: fall, resetHour: 3, calendar: eastern)), 25 * 3600)
        let parser = ISO8601DateFormatter()
        let start = parser.date(from: "2026-11-01T05:00:00Z")!, end = parser.date(from: "2026-11-01T07:00:00Z")!
        XCTAssertEqual(ReadingDay.hours(from: start, to: end, calendar: eastern), ["2026-11-01T01:00": 7200])
    }
    @MainActor func testUsageTodayAndTrendCountsReadBothCalendarFilesAndChangeWithReset() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let log = UsageLog(directory: root)
        func event(_ type: UsageEventType, _ time: Date, started: Date? = nil) -> UsageEvent {
            UsageEvent(at: Int64(time.timeIntervalSince1970 * 1000), utcOffset: "+00:00", type: type, session: "s", bookTitle: "Fixture", startedAt: started.map { Int64($0.timeIntervalSince1970 * 1000) })
        }
        log.append(event(.lookup, date("2026-09-30", 23, 59)))
        log.append(event(.lookup, date("2026-10-01", 1)))
        log.append(event(.stopped, date("2026-10-01", 1), started: date("2026-09-30", 23, 59)))
        let model = UsageStatisticsModel()
        await model.reload(resetHour: 3, now: date("2026-10-01", 2), log: log)
        XCTAssertEqual(model.today.date, date("2026-09-30")); XCTAssertEqual(model.today.lookups, 2)
        XCTAssertEqual(model.today.spans.first?.seconds, 3660)
        XCTAssertEqual(model.values(\.lookups)[date("2026-09-30")], 2)
        await model.reload(resetHour: 0, now: date("2026-10-01", 2), log: log)
        XCTAssertEqual(model.today.date, date("2026-10-01")); XCTAssertEqual(model.today.lookups, 1)
        XCTAssertEqual(model.today.spans.first?.seconds, 3600)
        XCTAssertEqual(model.values(\.lookups)[date("2026-09-30")], 1)
    }
    func testUsageHistoryResolvesSessionsOnceAndSplitsClosedAndInterruptedSpansAtReset() {
        func event(_ type: UsageEventType, _ at: Date, session: String = "closed", word: String? = nil) -> UsageEvent {
            UsageEvent(at: Int64(at.timeIntervalSince1970 * 1000), utcOffset: "+00:00", type: type, session: session,
                       bookTitle: "Fixture", contentType: "manga", term: word, source: "page", outcome: "found")
        }
        let events = [
            event(.started, date("2026-09-30", 2, 59)),
            event(.lookup, date("2026-09-30", 23, 59), word: "猫"),
            event(.lookup, date("2026-10-01", 1), word: "猫"),
            event(.lookup, date("2026-10-01", 3), word: "犬"),
            event(.stopped, date("2026-10-01", 3, 1)), // No startedAt: resolve from the prior day's start.
            event(.started, date("2026-10-01", 3, 10), session: "interrupted"),
            event(.page, date("2026-10-01", 3, 12), session: "interrupted")
        ]
        let first = date("2026-09-30"), second = date("2026-10-01")
        let days = UsageDay.summarize(Array(events.reversed()), dates: [first, second], calendar: calendar, resetHour: 3)
        XCTAssertEqual(days[first]?.lookups, 2); XCTAssertEqual(days[second]?.lookups, 1)
        XCTAssertEqual(days[first]?.repeated.first?.word, "猫"); XCTAssertEqual(days[first]?.repeated.first?.count, 2)
        XCTAssertTrue(days[second]!.repeated.isEmpty)
        XCTAssertEqual(days[first]?.spans.map(\.seconds), [24 * 3600])
        XCTAssertEqual(days[second]?.spans.map(\.seconds), [60, 120])
        XCTAssertEqual(days[first]?.firstActivity, date("2026-09-30", 3))
        XCTAssertEqual(days[second]?.pages, 1)
        XCTAssertEqual(days[second]?.lastActivity, date("2026-10-01", 3, 12))
    }
    @MainActor func testExchangedHourEvidenceConvergesAndMissingTabletHistoryRecovers() async throws {
        let phone = try directory(), tablet = try directory(); defer { try? FileManager.default.removeItem(at: phone); try? FileManager.default.removeItem(at: tablet) }
        let original = [row("2026-09-30", seconds: 600, hours: ["2026-09-30T22:00": 600]), row("2026-10-01", seconds: 900, hours: ["2026-10-01T01:00": 900])]
        try ReadingStatisticsStore.save(original, root: phone, scheduleSync: false)
        let kv = DayParityKV(), sync = HttpReadingStatisticsSync(), key = "books/fixture/statistics"
        try await sync.exchange(root: phone, syncId: "fixture", transport: kv)
        let metadata = await kv.metadata(key)!
        try await sync.exchange(root: tablet, syncId: "fixture", transport: kv, listing: [key: metadata])
        func verify() {
            let saved = ReadingStatisticsStore.reading(root: tablet)
            XCTAssertEqual(saved, original)
            XCTAssertEqual(ReadingDay.days(reading: saved, resetHour: 3).map(\.seconds), [1500])
            XCTAssertFalse(ReadingDay.streakHistory(saved, resetHour: 3).estimated)
        }
        verify()
        try FileManager.default.removeItem(at: tablet.appendingPathComponent(FileNames.statistics))
        try await sync.exchange(root: tablet, syncId: "fixture", transport: kv, listing: [key: metadata])
        verify()
        let requests = await kv.requests
        try await sync.exchange(root: tablet, syncId: "fixture", transport: kv, listing: [key: metadata])
        let after = await kv.requests; XCTAssertEqual(after, requests)
    }
    @MainActor func testSameSizeSameStampRemoteEditAndListingAbsenceCannotLoseHistory() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let kv = DayParityKV(), sync = HttpReadingStatisticsSync(), key = "books/fixture/statistics"
        let first = row("2026-10-01", seconds: 600)
        try ReadingStatisticsStore.save([first], root: root, scheduleSync: false)
        try await sync.exchange(root: root, syncId: "fixture", transport: kv)
        let before = await kv.metadata(key)!
        let updated = row("2026-10-01", seconds: 900, stamp: 2)
        _ = try await kv.put(key: key, contentType: "application/json", body: JSONEncoder().encode(ReadingStatisticsBlob(syncId: "fixture", entries: [updated])))
        let after = await kv.metadata(key)!
        XCTAssertEqual(before.size, after.size); XCTAssertEqual(before.lastModified, after.lastModified); XCTAssertNotEqual(before.etag, after.etag)
        try await sync.exchange(root: root, syncId: "fixture", transport: kv, listing: [key: after])
        XCTAssertEqual(ReadingStatisticsStore.reading(root: root).first?.readingTime, 900)
        let peer = row("2026-09-30", seconds: 300, device: "tablet")
        _ = try await kv.put(key: key, contentType: "application/json", body: JSONEncoder().encode(ReadingStatisticsBlob(syncId: "fixture", entries: [updated, peer])))
        try await sync.exchange(root: root, syncId: "fixture", transport: kv, listing: [:])
        XCTAssertEqual(Statistics.total(ReadingStatisticsStore.reading(root: root)).readingTime, 1200)
    }
    @MainActor func testAndroidMonthlyShardsCountRemoteOnlyAndDeletedBooks() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let suite = "Lane." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let kv = DayParityKV(), lane = HttpStatisticsLane(directory: root, device: ReadingDevice(id: "ios", name: "iOS"), defaults: defaults)
        let first = row("2026-10-01", seconds: 600, device: "android")
        let shard = HttpStatisticsShard(deviceId: "android", month: "2026-10", books: ["remote_book": HttpStatisticsShardBook(title: "Remote book", contentType: "epub", reading: [first])])
        let key = HttpStatisticsLane.prefix + "android/2026-10.json"
        _ = try await kv.put(key: key, contentType: "application/json", body: JSONEncoder().encode(shard))
        var listing = try await kv.list(prefix: nil, since: nil, cursor: nil, limit: nil)
        var errors = await lane.run(transport: kv, listing: Dictionary(uniqueKeysWithValues: listing.keys.map { ($0.key, $0) }), flush: true)
        XCTAssertTrue(errors.isEmpty, "\(errors)")
        let kept = try StatisticsHistory.historyRoot("remote_book", directory: root)
        XCTAssertEqual(ReadingStatisticsStore.reading(root: kept), [first])
        let roots = try StatisticsHistory.roots(directory: root)
        XCTAssertEqual(roots.count, 1); XCTAssertNil(roots[0].book)
        let meta = StatisticsHistory.metadata(for: roots[0])
        XCTAssertNil(meta.folder); XCTAssertEqual(meta.title, "Remote book")
        XCTAssertEqual(meta.id, StatisticsHistory.metadata(for: roots[0]).id)
        let count = await kv.requests
        listing = try await kv.list(prefix: nil, since: nil, cursor: nil, limit: nil)
        errors = await lane.run(transport: kv, listing: Dictionary(uniqueKeysWithValues: listing.keys.map { ($0.key, $0) }))
        XCTAssertTrue(errors.isEmpty)
        let after = await kv.requests; XCTAssertEqual(after, count)
    }
    @MainActor func testReinstalledBookAbsorbsHistoryWithoutDoubleCounting() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let history = try StatisticsHistory.historyRoot("fixture", title: "Fixture", type: .epub, directory: root)
        let first = row("2026-10-01", seconds: 600)
        try ReadingStatisticsStore.save([first], root: history, scheduleSync: false)
        let installed = root.appendingPathComponent("fixture")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try BookStorage.save(BookMetadata(title: "Fixture", cover: nil, folder: "fixture", lastAccess: .now, syncId: "fixture"), inside: installed, as: FileNames.metadata)
        try BookStorage.save([first, row("2026-10-01", seconds: 120, device: "tablet")], inside: installed, as: FileNames.statistics)
        let roots = try StatisticsHistory.roots(directory: root)
        XCTAssertEqual(roots.count, 1); XCTAssertNotNil(roots[0].book)
        XCTAssertEqual(Statistics.total(ReadingStatisticsStore.reading(root: installed)).readingTime, 720)
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.path))
    }
    @MainActor func testShardRejectsWrongDeviceAndUnsafeBookNamesAndRetriesAfterRepair() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let kv = DayParityKV(), lane = HttpStatisticsLane(directory: root, device: ReadingDevice(id: "ios", name: "iOS"))
        let key = HttpStatisticsLane.prefix + "android/2026-10.json"
        var shard = HttpStatisticsShard(deviceId: "wrong", month: "2026-10", books: [:])
        _ = try await kv.put(key: key, contentType: "application/json", body: JSONEncoder().encode(shard))
        var meta = await kv.metadata(key)!
        let errors = await lane.run(transport: kv, listing: [key: meta])
        XCTAssertFalse(errors.isEmpty); XCTAssertNotNil(lane.problem)
        shard.deviceId = "android"
        shard.books = ["../escape": HttpStatisticsShardBook(reading: [row("2026-10-01", seconds: 600, device: "android")]), "safe": HttpStatisticsShardBook(reading: [row("2026-10-01", seconds: 600, device: "android")])]
        _ = try await kv.put(key: key, contentType: "application/json", body: JSONEncoder().encode(shard))
        meta = await kv.metadata(key)!
        let recovered = await lane.run(transport: kv, listing: [key: meta])
        XCTAssertTrue(recovered.isEmpty); XCTAssertNil(lane.problem)
        XCTAssertEqual(try StatisticsHistory.roots(directory: root).map(\.syncId), ["safe"])
    }
    @MainActor func testStreakPreferencesConvergeAndOlderChoicesCannotUndoNewerOnes() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let suite = "Lane." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let kv = DayParityKV(), lane = HttpStatisticsLane(directory: root, device: ReadingDevice(id: "ios", name: "iOS"), defaults: defaults)
        let key = HttpStatisticsLane.prefix + "android/settings.json"
        _ = try await kv.put(key: key, contentType: "application/json", body: JSONEncoder().encode(HttpStatisticsPreferences(streakMinimumMinutes: 25, dayResetHour: 4, updatedAt: 100)))
        let meta = await kv.metadata(key)!
        let errors = await lane.run(transport: kv, listing: [key: meta], flush: true)
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(StatisticsPreferencesStore.load(defaults: defaults).streakMinimumMinutes, 25)
        XCTAssertEqual(StatisticsPreferencesStore.load(defaults: defaults).dayResetHour, 4)
        StatisticsPreferencesStore.save(HttpStatisticsPreferences(streakMinimumMinutes: 30, dayResetHour: 3, updatedAt: 101), defaults: defaults)
        _ = await lane.run(transport: kv, listing: [key: meta], flush: true)
        XCTAssertEqual(StatisticsPreferencesStore.load(defaults: defaults).streakMinimumMinutes, 30)
    }

    @MainActor func testAndroidCapitalizedMangaTypeAndIOSOwnShardWireFormat() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let kv = DayParityKV(), lane = HttpStatisticsLane(directory: root, device: ReadingDevice(id: "ios", name: "iOS"))
        let fixture = Data(#"{"version":1,"deviceId":"android","month":"2026-10","books":{"manga":{"title":"Manga","contentType":"Mokuro","reading":[{"title":"Manga","dateKey":"2026-10-01","charactersRead":3,"readingTime":60.0,"minReadingSpeed":0,"altMinReadingSpeed":0,"lastReadingSpeed":0,"maxReadingSpeed":0,"lastStatisticModified":1,"deviceId":"android","deviceName":"Android","readingTimeByHour":{},"timeZone":null}],"mangaText":[]}}}"#.utf8)
        let key = HttpStatisticsLane.prefix + "android/2026-10.json"
        _ = try await kv.put(key: key, contentType: "application/json", body: fixture)
        var meta = await kv.metadata(key)!
        let errors = await lane.run(transport: kv, listing: [key: meta], flush: true)
        XCTAssertTrue(errors.isEmpty, "\(errors)")
        let kept = try StatisticsHistory.historyRoot("manga", directory: root)
        XCTAssertEqual(ReadingStatisticsStore.contentType(root: kept), .mokuro)
        try ReadingStatisticsStore.save([row("2026-10-01", seconds: 120, device: "ios")], root: kept, scheduleSync: false)
        meta = await kv.metadata(key)!
        _ = await lane.run(transport: kv, listing: [key: meta], flush: true)
        let uploaded = try await kv.get(key: HttpStatisticsLane.prefix + "ios/2026-10.json")!
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: uploaded.body) as? [String: Any])
        let books = try XCTUnwrap(object["books"] as? [String: [String: Any]])
        XCTAssertEqual(books["manga"]?["contentType"] as? String, "Mokuro")
    }
    @MainActor func testUnsuccessfulOwnShardReadWithoutETagCannotOverwriteServerHistory() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let kept = try StatisticsHistory.historyRoot("fixture", directory: root)
        try ReadingStatisticsStore.save([row("2026-10-01", seconds: 120, device: "ios")], root: kept, scheduleSync: false)
        let kv = DayParityKV(), lane = HttpStatisticsLane(directory: root, device: ReadingDevice(id: "ios", name: "iOS"))
        let key = HttpStatisticsLane.prefix + "ios/2026-10.json", unreadable = Data("bad JSON".utf8)
        _ = try await kv.put(key: key, contentType: "application/json", body: unreadable)
        let errors = await lane.run(transport: kv, listing: [key: HttpSyncKvKeyMeta(key: key, lastModified: "2026-10-01T00:00:00Z", size: unreadable.count)], flush: true, retryFailed: true)
        XCTAssertFalse(errors.isEmpty)
        let server = try await kv.get(key: key)
        XCTAssertEqual(server?.body, unreadable)
    }
    @MainActor func testUnreadableMetadataCannotRemoveBookFromOwnPublishedMonth() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let installed = root.appendingPathComponent("fixture")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try BookStorage.save(BookMetadata(title: "Fixture", cover: nil, folder: "fixture", lastAccess: .now, syncId: "fixture"), inside: installed, as: FileNames.metadata)
        try ReadingStatisticsStore.save([row("2026-10-01", seconds: 120, device: "ios")], root: installed, scheduleSync: false)
        let kv = DayParityKV(), lane = HttpStatisticsLane(directory: root, device: ReadingDevice(id: "ios", name: "iOS"))
        _ = await lane.run(transport: kv, listing: [:], flush: true)
        let key = HttpStatisticsLane.prefix + "ios/2026-10.json"
        let before = try await kv.get(key: key)!
        try Data("broken".utf8).write(to: installed.appendingPathComponent(FileNames.metadata))
        let meta = await kv.metadata(key)!
        let errors = await lane.run(transport: kv, listing: [key: meta], flush: true)
        XCTAssertFalse(errors.isEmpty)
        let after = try await kv.get(key: key)!
        XCTAssertEqual(before.body, after.body)
    }

    func testAndroidLegacyShanghaiNoonRecoversEasternNight() {
        let ny = TimeZone(identifier: "America/New_York")!, calendar = StatisticsZone.calendar(zone: ny)
        var tablet = row("2026-10-03", seconds: 1162.1389999999924, count: 5000, hours: ["2026-10-03T12:00": 1162.1389999999924], device: "tablet", stamp: 1791001743483)
        XCTAssertEqual(tablet.recordedZone(target: ny)?.secondsFromGMT(), 8 * 3600)
        var days = ReadingDay.days(reading: [tablet], resetHour: 3, calendar: calendar)
        XCTAssertEqual(days.map { ReadingDay.key($0.date, calendar: calendar) }, ["2026-10-02"])
        XCTAssertEqual(days[0].characters, 5000)
        tablet.timeZone = "Asia/Shanghai"
        days = ReadingDay.days(reading: [tablet], resetHour: 0, calendar: calendar)
        XCTAssertEqual(days.map { ReadingDay.key($0.date, calendar: calendar) }, ["2026-10-03"])
        tablet.readingTimeByHour = ["2026-10-03T09:00": tablet.readingTime]
        days = ReadingDay.days(reading: [tablet], resetHour: 0, calendar: calendar)
        XCTAssertEqual(days.map { ReadingDay.key($0.date, calendar: calendar) }, ["2026-10-02"])
    }
    func testEachDevicesCharactersFollowItsOwnZoneAndHours() {
        let calendar = StatisticsZone.calendar(zone: TimeZone(identifier: "America/New_York")!)
        var phone = row("2026-10-03", seconds: 3600, count: 1000, hours: ["2026-10-03T20:00": 3600])
        phone.timeZone = "America/New_York"
        var tablet = row("2026-10-03", seconds: 1200, count: 5000, hours: ["2026-10-03T12:00": 1200], device: "tablet")
        tablet.timeZone = "Asia/Shanghai"
        let days = ReadingDay.days(reading: [phone, tablet], resetHour: 3, calendar: calendar)
        XCTAssertEqual(days.map(\.characters), [5000, 1000])
        XCTAssertEqual(days.map(\.seconds), [1200, 3600])
        let manga = [MangaTextStatistic(dateKey: phone.dateKey, charactersRead: 1000, deviceId: "phone"), MangaTextStatistic(dateKey: tablet.dateKey, charactersRead: 5000, deviceId: "tablet")]
        XCTAssertEqual(ReadingDay.days(reading: [phone, tablet], text: manga, resetHour: 3, calendar: calendar).map(\.characters), [5000, 1000])
    }
    func testZoneEvidenceSurvivesOlderClientsAndLiveRecordingRekeysPreviousHours() throws {
        var tagged = row("2026-10-03", seconds: 1200, hours: ["2026-10-03T12:00": 1200], stamp: 1791001743483)
        tagged.timeZone = "Asia/Shanghai"
        var stripped = tagged; stripped.timeZone = nil
        XCTAssertEqual(Statistics.merged([tagged, stripped]), [tagged]); XCTAssertEqual(Statistics.merged([stripped, tagged]), [tagged])
        XCTAssertEqual(try JSONDecoder().decode(Statistics.self, from: JSONEncoder().encode(tagged)), tagged)
        tagged.record(in: TimeZone(identifier: "America/New_York")!)
        XCTAssertEqual(tagged.timeZone, "America/New_York")
        XCTAssertEqual(tagged.readingTimeByHour, ["2026-10-03T00:00": 1200])
    }
    func testSharedZoneDSTBoundaryAndUnrecoverableLegacyEdits() {
        let ny = TimeZone(identifier: "America/New_York")!, calendar = StatisticsZone.calendar(zone: ny)
        let before = ReadingDay.boundary(on: ReadingDay.parse("2026-03-07", calendar: calendar)!, resetHour: 3, calendar: calendar)
        let after = ReadingDay.boundary(on: ReadingDay.parse("2026-03-08", calendar: calendar)!, resetHour: 3, calendar: calendar)
        XCTAssertEqual(after.timeIntervalSince(before), 23 * 3600)
        var edited = row("2026-10-01", seconds: 600, hours: ["2026-10-01T20:00": 600], stamp: 1791072000000)
        XCTAssertNil(edited.recordedZone(target: ny))
        edited.timeZone = "invalid/zone"
        XCTAssertNil(edited.recordedZone(target: ny))
        XCTAssertEqual(ReadingDay.days(reading: [edited], resetHour: 3, calendar: calendar).map { ReadingDay.key($0.date, calendar: calendar) }, ["2026-10-01"])
    }
    @MainActor func testStatisticsTimeZoneSyncPreservesExplicitZoneFromOlderPeers() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let suite = "Zone." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let kv = DayParityKV(), lane = HttpStatisticsLane(directory: root, device: ReadingDevice(id: "ios", name: "iOS"), defaults: defaults)
        let key = HttpStatisticsLane.prefix + "android/settings.json"
        let chosen = HttpStatisticsPreferences(streakMinimumMinutes: 25, dayResetHour: 3, updatedAt: 100, timeZone: "Asia/Shanghai")
        _ = try await kv.put(key: key, contentType: "application/json", body: JSONEncoder().encode(chosen))
        var meta = await kv.metadata(key)!
        _ = await lane.run(transport: kv, listing: [key: meta], flush: true)
        XCTAssertEqual(defaults.string(forKey: StatisticsZone.key), "Asia/Shanghai")
        var old = chosen; old.updatedAt = 101; old.timeZone = nil
        _ = try await kv.put(key: key, contentType: "application/json", body: JSONEncoder().encode(old))
        meta = await kv.metadata(key)!
        _ = await lane.run(transport: kv, listing: [key: meta], flush: true)
        XCTAssertEqual(defaults.string(forKey: StatisticsZone.key), "Asia/Shanghai")
    }

    func testAndroidFixedOffsetTagsRemainAuthoritativeAfterAggregateEdit() {
        let calendar = StatisticsZone.calendar(zone: TimeZone(identifier: "America/New_York")!)
        for zone in ["+08:00", "+08"] {
            var entry = row("2026-10-03", seconds: 1800, hours: ["2026-10-03T12:00": 1200], stamp: 1791072000000)
            entry.timeZone = zone
            let days = ReadingDay.days(reading: [entry], resetHour: 3, calendar: calendar)
            XCTAssertEqual(days.map(\.seconds), [1200, 600], zone)
            XCTAssertEqual(days.map { ReadingDay.key($0.date, calendar: calendar) }, ["2026-10-02", "2026-10-03"])
        }
        XCTAssertEqual(StatisticsZone.zone("Z")?.secondsFromGMT(), 0)
        XCTAssertEqual(StatisticsZone.zone("+05:30")?.secondsFromGMT(), 19_800)
    }
    @MainActor func testAggregateImportPreservesTheZoneOfRetainedHourlyEvidence() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var own = row("2026-10-03", seconds: 1200, hours: ["2026-10-03T12:00": 1200], device: ReadingDevice.current.id)
        own.timeZone = "Asia/Shanghai"
        try ReadingStatisticsStore.save([own], root: root, scheduleSync: false)
        var total = own; total.readingTime = 1800; total.readingTimeByHour = [:]; total.timeZone = nil; total.lastStatisticModified = 1791072000000
        try ReadingStatisticsStore.applyDayTotals([total], root: root, replace: false)
        let saved = ReadingStatisticsStore.reading(root: root)
        XCTAssertEqual(saved[0].timeZone, "Asia/Shanghai")
        let calendar = StatisticsZone.calendar(zone: TimeZone(identifier: "America/New_York")!)
        XCTAssertEqual(ReadingDay.days(reading: saved, resetHour: 3, calendar: calendar).map(\.seconds), [1200, 600])
    }
    @MainActor func testUsageRecordingStartUsesAbsoluteEventRatherThanItsFileName() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let calendar = StatisticsZone.calendar(zone: TimeZone(identifier: "America/New_York")!)
        let at = calendar.date(bySettingHour: 12, minute: 30, second: 0, of: ReadingDay.parse("2026-10-02", calendar: calendar)!)!
        let event = UsageEvent(at: Int64(at.timeIntervalSince1970 * 1000), utcOffset: "+08:00", type: .lookup, term: "猫")
        var data = try JSONEncoder().encode(event); data.append(10)
        try data.write(to: root.appendingPathComponent("2026-10-03.ndjson"))
        let model = UsageStatisticsModel()
        await model.reload(resetHour: 3, now: at.addingTimeInterval(86400), log: UsageLog(directory: root))
        XCTAssertEqual(model.firstDay, ReadingDay.parse("2026-10-02", calendar: calendar))
        XCTAssertEqual(model.values(\.lookups)[ReadingDay.parse("2026-10-02", calendar: calendar)!], 1)
    }

}

private actor DayParityKV: HttpSyncKvTransport {
    private var bodies: [String: Data] = [:]
    var requests = 0
    func metadata(_ key: String) -> HttpSyncKvKeyMeta? {
        bodies[key].map { HttpSyncKvKeyMeta(key: key, lastModified: "2026-10-01T00:00:00Z", etag: "sha256:" + SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined(), size: $0.count) }
    }
    func put(key: String, contentType: String, body: Data) async throws -> HttpSyncKvWriteResponse { requests += 1; bodies[key] = body; return metadata(key)! }
    func get(key: String) async throws -> HttpSyncKvFetched? {
        requests += 1
        return bodies[key].map { HttpSyncKvFetched(body: $0, contentType: "application/json", lastModified: "2026-10-01T00:00:00Z", etag: metadata(key)!.etag!) }
    }
    func putFile(key: String, contentType: String, fileURL: URL) async throws -> HttpSyncKvWriteResponse { try await put(key: key, contentType: contentType, body: Data(contentsOf: fileURL)) }
    func downloadToFile(key: String, targetURL: URL) async throws -> HttpSyncKvFileFetched? { nil }
    func list(prefix: String?, since: String?, cursor: String?, limit: Int?) async throws -> HttpSyncKvList { HttpSyncKvList(keys: bodies.keys.compactMap(metadata)) }
    func delete(key: String) async throws { bodies[key] = nil }
}
