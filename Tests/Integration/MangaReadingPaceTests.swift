import XCTest
@testable import Hoshi_Reader

/// Android `MangaReadingPaceTest`: completed manga pages persist as a per-day/device seconds
/// histogram and merge without losing samples. The ETA trims reliable page observations.
nonisolated final class MangaReadingPaceTests: XCTestCase {
    private let phone = ReadingDevice(id: "phone", name: "Phone")
    private let tablet = ReadingDevice(id: "tablet", name: "Tablet")
    private let start = Date(timeIntervalSince1970: 1_793_620_800) // 2026-11-01 12:00 UTC

    private func day(_ device: ReadingDevice? = nil, samples: [Int: Int] = [:], stamp: Int = 1) -> Statistics {
        var row = Statistics.empty(title: "Manga", day: MangaStatisticsTracker.dateKey(for: start), device: device ?? phone)
        row.lastStatisticModified = stamp
        row.mangaPageSeconds = samples
        return row
    }
    private func tracker(_ history: [Statistics] = [], tracking: Bool = true) -> MangaStatisticsTracker {
        MangaStatisticsTracker(title: "Manga", initialStatistics: history, enabled: true, now: start, device: phone, trackPageDurations: tracking)
    }
    private func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    func testAnIdlePageCannotDistortTheMedianOfCompletedPages() {
        let statistics = day(samples: [30: 1, 40: 1, 50: 1, 3600: 1])
        XCTAssertEqual(statistics.medianPageSeconds, 45)
    }
    func testTheMedianWeightsEveryPageRatherThanEveryDistinctDuration() {
        XCTAssertEqual(day(samples: [30: 3, 40: 1, 3600: 1]).medianPageSeconds, 30)
        XCTAssertEqual(day(samples: [30: 2, 40: 2, 3600: 0]).medianPageSeconds, 35)
    }
    func testMergingOlderSnapshotsOrNewerStrippedCountersCannotErasePageEvidence() {
        let old = day(samples: [30: 4, 3600: 1])
        var newer = old
        newer.lastStatisticModified = 2; newer.readingTime = 500; newer.mangaPageSeconds = [30: 2, 40: 2]
        var expected = newer
        expected.mangaPageSeconds = [30: 4, 40: 2, 3600: 1]
        XCTAssertEqual(Statistics.merged([old, newer]), [expected])
        XCTAssertEqual(Statistics.merged([newer, old]), [expected])
        XCTAssertEqual(Statistics.merged([old, newer, old, newer]), [expected])

        var stripped = newer
        stripped.mangaPageSeconds = [:]
        XCTAssertEqual(Statistics.merged([old, stripped]).first?.mangaPageSeconds, old.mangaPageSeconds)
        XCTAssertEqual(Statistics.merged([stripped, old]).first?.mangaPageSeconds, old.mangaPageSeconds)
    }
    @MainActor func testTtuDayExportsDoNotDuplicateDevicePageSamples() {
        XCTAssertEqual(ReadingStatisticsStore.collapsed([day(samples: [30: 2])]).first?.mangaPageSeconds, [:])
    }
    func testRemainingTimeFallsBackToUnroundedAverageWithIncompleteTiming() throws {
        // These short page samples would put the median at 232.3 pages per hour.
        var statistics = day(samples: [15: 75, 16: 75])
        statistics.charactersRead = 150
        statistics.readingTime = 6_164

        let average = try XCTUnwrap(MangaStatisticsView.averagePageSeconds(statistics))
        XCTAssertEqual(3600 / average, 87.60545100584037, accuracy: 0.000_001)
        let estimate = try XCTUnwrap(MangaStatisticsView.estimatedPageSeconds(statistics))
        XCTAssertEqual(estimate, average)
        let seconds = try XCTUnwrap(MangaStatisticsView.secondsRemaining(remainingPages: 103, averagePageSeconds: estimate))
        XCTAssertEqual(seconds, 4_232.613333333334, accuracy: 0.000_001)

        statistics.mangaPageSeconds = [:] // Old history with no page samples works too.
        XCTAssertEqual(MangaStatisticsView.estimatedPageSeconds(statistics), average)
    }

    func testReliableTimingTrimsPageObservationsAndKeepsPartialBuckets() throws {
        var statistics = day(samples: [1: 3, 20: 4, 40: 11, 500: 2, -1: 100, 900: 0])
        statistics.charactersRead = 20
        statistics.readingTime = 1_523
        XCTAssertEqual(MangaStatisticsView.averagePageSeconds(statistics), 76.15)
        let estimate = try XCTUnwrap(MangaStatisticsView.estimatedPageSeconds(statistics))
        XCTAssertEqual(estimate, 32.5625)
        XCTAssertEqual(MangaStatisticsView.secondsRemaining(remainingPages: 103, averagePageSeconds: estimate), 3_353.9375)
    }

    func testSparseOrDisproportionateTimingUsesAllRecordedPagesAndSeconds() {
        var statistics = day(samples: [1: 1, 30: 7, 89: 1])
        statistics.charactersRead = 9
        statistics.readingTime = 300
        XCTAssertEqual(MangaStatisticsView.estimatedPageSeconds(statistics), 300.0 / 9)

        statistics.mangaPageSeconds = [1: 1, 30: 16, 119: 1] // 18 pages and 600 seconds
        statistics.charactersRead = 20
        statistics.readingTime = 600
        XCTAssertEqual(MangaStatisticsView.estimatedPageSeconds(statistics), 30)
        statistics.charactersRead = 21
        XCTAssertEqual(MangaStatisticsView.estimatedPageSeconds(statistics), 600.0 / 21)
        statistics.charactersRead = 17
        XCTAssertEqual(MangaStatisticsView.estimatedPageSeconds(statistics), 600.0 / 17)

        statistics.charactersRead = 20
        statistics.readingTime = 700
        XCTAssertEqual(MangaStatisticsView.estimatedPageSeconds(statistics), 35)
        statistics.readingTime = 500
        XCTAssertEqual(MangaStatisticsView.estimatedPageSeconds(statistics), 25)
    }

    func testTenPagesAndBothTimeCoverageBoundariesCount() {
        var statistics = day(samples: [1: 1, 99: 1, 100: 8]) // 900 of 1,000 seconds
        statistics.charactersRead = 10
        statistics.readingTime = 1_000
        XCTAssertEqual(MangaStatisticsView.estimatedPageSeconds(statistics), 799.0 / 8)
        statistics.mangaPageSeconds = [1: 1, 100: 8, 299: 1] // 1,100 of 1,000 seconds
        XCTAssertEqual(MangaStatisticsView.estimatedPageSeconds(statistics), 100)
    }

    func testExcessiveHistogramCountsCannotOverflow() {
        var statistics = day(samples: [1: .max, 2: .max])
        statistics.charactersRead = .max
        statistics.readingTime = Double(Int.max)
        XCTAssertEqual(MangaStatisticsView.estimatedPageSeconds(statistics), 1)
    }
    func testRemainingTimeRequiresValidReadingHistoryUnlessTheBookIsFinished() {
        var statistics = day(samples: [30: 1])
        XCTAssertNil(MangaStatisticsView.averagePageSeconds(statistics))
        statistics.charactersRead = 10
        for time in [0.0, -30, .nan, .infinity, .leastNonzeroMagnitude] {
            statistics.readingTime = time
            XCTAssertNil(MangaStatisticsView.averagePageSeconds(statistics))
            XCTAssertNil(MangaStatisticsView.estimatedPageSeconds(statistics))
        }
        statistics.charactersRead = 0
        statistics.readingTime = 10
        XCTAssertNil(MangaStatisticsView.averagePageSeconds(statistics))
        XCTAssertNil(MangaStatisticsView.secondsRemaining(remainingPages: 10, averagePageSeconds: nil))
        XCTAssertNil(MangaStatisticsView.secondsRemaining(remainingPages: 10, averagePageSeconds: .greatestFiniteMagnitude))
        XCTAssertEqual(MangaStatisticsView.secondsRemaining(remainingPages: 0, averagePageSeconds: nil), 0)
        XCTAssertEqual(MangaStatisticsView.secondsRemaining(remainingPages: -1, averagePageSeconds: 30), 0)
    }
    func testAndroidWireFormatRoundTripsDropsInvalidBucketsAndOmitsEmptyHistograms() throws {
        let json = #"[{"title":"Manga","dateKey":"2026-11-01","charactersRead":2,"readingTime":70.0,"minReadingSpeed":0,"altMinReadingSpeed":0,"lastReadingSpeed":0,"maxReadingSpeed":0,"lastStatisticModified":5,"deviceId":"tablet","mangaPageSeconds":{"30":1,"40":1,"x":9,"-5":2}}]"#
        let decoded = try JSONDecoder().decode([Statistics].self, from: Data(json.utf8))
        XCTAssertEqual(decoded.first?.mangaPageSeconds, [30: 1, 40: 1])
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [[String: Any]]
        XCTAssertEqual(encoded?.first?["mangaPageSeconds"] as? [String: Int], ["30": 1, "40": 1])
        let empty = try JSONSerialization.jsonObject(with: JSONEncoder().encode([day()])) as? [[String: Any]]
        XCTAssertNil(empty?.first?["mangaPageSeconds"])
    }
    func testCompletedPageDurationsSurviveSavingAndReopening() throws {
        var first = tracker()
        first.start(currentPage: 0, now: start)
        first.pageChanged(currentPage: 1, completedPages: 1, now: at(30))
        first.pause(currentPage: 1, now: at(31))
        let saved = try JSONDecoder().decode([Statistics].self, from: JSONEncoder().encode(first.statisticsForPersistence()!))
        XCTAssertEqual(saved.map(\.mangaPageSeconds), [[30: 1]])
        XCTAssertEqual(saved.first?.deviceId, phone.id)

        var reopened = tracker(saved)
        XCTAssertEqual(reopened.session.mangaPageSeconds, [:])
        XCTAssertEqual(reopened.allTime.medianPageSeconds, 30)
        reopened.start(currentPage: 1, now: at(100))
        reopened.pageChanged(currentPage: 2, completedPages: 1, now: at(150))
        XCTAssertEqual(reopened.statisticsForPersistence()?.first?.mangaPageSeconds, [30: 1, 50: 1])
        XCTAssertEqual(reopened.allTime.medianPageSeconds, 40)
    }
    func testPeriodicTicksAccumulateOnePageWithoutCreatingSamples() {
        var tracker = tracker()
        tracker.start(currentPage: 0, now: start)
        for tick in 1...3 { tracker.update(currentPage: 0, now: at(Double(tick * 10))) }
        XCTAssertEqual(tracker.allTime.mangaPageSeconds, [:])
        XCTAssertEqual(tracker.statisticsForPersistence()?.first?.mangaPageSeconds, [:])

        tracker.pageChanged(currentPage: 1, completedPages: 1, now: at(30))
        XCTAssertEqual(tracker.allTime.mangaPageSeconds, [30: 1])
        XCTAssertEqual(tracker.statisticsForPersistence()?.first?.mangaPageSeconds, [30: 1])
    }
    func testJumpingAndGoingBackDiscardThePreviousPageDuration() {
        var tracker = tracker()
        tracker.start(currentPage: 0, now: start)
        tracker.pageChanged(currentPage: 10, completedPages: 0, now: at(600))
        tracker.pageChanged(currentPage: 10, completedPages: 0, now: at(640))
        XCTAssertEqual(tracker.allTime.mangaPageSeconds, [:])

        tracker.pageChanged(currentPage: 11, completedPages: 1, now: at(670))
        XCTAssertEqual(tracker.allTime.mangaPageSeconds, [30: 1])
        XCTAssertEqual(tracker.allTime.readingTime, 670)
    }
    func testResumingTheSamePageExcludesTimeSpentInTheBackground() {
        var tracker = tracker()
        tracker.start(currentPage: 0, now: start)
        tracker.update(currentPage: 0, now: at(10))
        tracker.pause(currentPage: 0, now: at(15))
        tracker.start(currentPage: 0, now: at(3615))
        tracker.pageChanged(currentPage: 1, completedPages: 1, now: at(3630))
        XCTAssertEqual(tracker.allTime.mangaPageSeconds, [30: 1])
        XCTAssertEqual(tracker.allTime.readingTime, 30)
    }
    func testNavigationWhilePausedInvalidatesTheOldPageDuration() {
        var tracker = tracker()
        tracker.start(currentPage: 0, now: start)
        tracker.pause(currentPage: 0, now: at(20))
        tracker.pageChanged(currentPage: 0, completedPages: 1, now: at(3620))
        tracker.start(currentPage: 0, now: at(3620))
        tracker.pageChanged(currentPage: 1, completedPages: 1, now: at(3630))
        XCTAssertEqual(tracker.allTime.mangaPageSeconds, [10: 1])
        XCTAssertEqual(tracker.allTime.readingTime, 30)
    }
    func testSameDayDeviceHistoriesAreAddedWithoutRewritingAnotherDevicesSamples() {
        let phoneHistory = day(phone, samples: [30: 2]), tabletHistory = day(tablet, samples: [50: 1])
        var tracker = tracker([phoneHistory, tabletHistory])
        XCTAssertEqual(tracker.allTime.medianPageSeconds, 30)
        tracker.start(currentPage: 0, now: start)
        tracker.pageChanged(currentPage: 1, completedPages: 1, now: at(40))

        let persisted = tracker.statisticsForPersistence()!
        XCTAssertEqual(persisted.first { $0.deviceId == tablet.id }, tabletHistory)
        XCTAssertEqual(persisted.first { $0.deviceId == phone.id }?.mangaPageSeconds, [30: 2, 40: 1])
        XCTAssertEqual(tracker.allTime.mangaPageSeconds, [30: 2, 40: 1, 50: 1])
        XCTAssertEqual(tracker.allTime.medianPageSeconds, 35)
    }
    func testZeroElapsedTimeDoesNotInventACompletedPageSample() {
        var tracker = tracker()
        tracker.start(currentPage: 0, now: start)
        tracker.pageChanged(currentPage: 1, completedPages: 1, now: start)
        XCTAssertEqual(tracker.allTime.mangaPageSeconds, [:])
        XCTAssertNil(tracker.allTime.medianPageSeconds)
    }
    func testPageDurationTrackingRequiresTheMangaOptIn() {
        var tracker = tracker(tracking: false)
        tracker.start(currentPage: 0, now: start)
        tracker.pageChanged(currentPage: 1, completedPages: 1, now: at(30))
        XCTAssertEqual(tracker.allTime.mangaPageSeconds, [:])
        XCTAssertEqual(tracker.allTime.readingTime, 30)
    }
    func testTodayIncludesPreviousDayHoursFromTwoDatesAheadAfterSync() throws {
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let calendar = StatisticsZone.calendar(zone: utc)
        let today = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-10T12:00:00Z"))
        var older = Statistics.empty(title: "Manga", day: "2026-01-08", device: phone)
        older.readingTime = 3600
        var tracker = MangaStatisticsTracker(title: "Manga", initialStatistics: [older], enabled: true,
            now: today, device: phone, timeZone: utc)
        XCTAssertEqual(tracker.dayTotal(at: today, resetHour: 3, calendar: calendar).readingTime, 0)

        var ahead = Statistics.empty(title: "Manga", day: "2026-01-12", device: tablet)
        ahead.readingTime = 1200
        ahead.charactersRead = 100
        ahead.readingTimeByHour = ["2026-01-11T02:00": 600, "2026-01-11T04:00": 600]
        tracker.mergeHistory([ahead])
        let text = [
            MangaTextStatistic(dateKey: "2026-01-12", charactersRead: 20, deviceId: tablet.id),
            MangaTextStatistic(dateKey: "2026-01-08", charactersRead: 80, deviceId: phone.id),
        ]
        let total = tracker.dayTotal(at: today, resetHour: 3, calendar: calendar)
        XCTAssertEqual(total.dateKey, "2026-01-10")
        XCTAssertEqual(total.readingTime, 600)
        XCTAssertEqual(total.charactersRead, 50)
        XCTAssertEqual(tracker.textTotal(text, at: today, resetHour: 3, calendar: calendar), 10)
        XCTAssertEqual(tracker.dayTotal(at: today, resetHour: 5, calendar: calendar).readingTime, 1200)
        XCTAssertEqual(tracker.allTime.readingTime, 4800)
    }

    func testASpreadTurnSplitsItsTimeBetweenBothPages() {
        var tracker = tracker()
        tracker.start(currentPage: 0, now: start)
        tracker.pageChanged(currentPage: 2, completedPages: 2, now: at(61))
        XCTAssertEqual(tracker.allTime.mangaPageSeconds, [31: 2])
    }
}
