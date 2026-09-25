import XCTest
@testable import Hoshi_Reader

nonisolated final class UsageParityTests: XCTestCase {
    private func event(_ type: UsageEventType, date: Date, started: Date? = nil, text: String? = nil, term: String? = nil, source: String? = nil, found: Bool = true) -> UsageEvent {
        UsageEvent(at: Int64(date.timeIntervalSince1970 * 1000), utcOffset: "+00:00", type: type, session: "session", bookId: "book", bookTitle: "Fixture", contentType: "manga", startedAt: started.map { Int64($0.timeIntervalSince1970 * 1000) }, text: text, term: term, source: source, outcome: found ? "found" : "not-found")
    }
    func testRepeatedWordsUseDictionaryFormAndIgnoreMisses() {
        let today = Date()
        let events = [event(.lookup, date: today, text: "食べた", term: "食べる", source: "page"), event(.lookup, date: today.addingTimeInterval(1), text: "食べて", term: "食べる", source: "popup"), event(.lookup, date: today.addingTimeInterval(2), text: "unknown", source: "page", found: false), event(.lookup, date: today.addingTimeInterval(3), text: "猫", term: "猫", source: "page")]
        let summary = UsageDay.summarize(events, date: today)
        XCTAssertEqual(summary.lookups, 4)
        XCTAssertEqual(summary.mangaLookups, 3)
        XCTAssertEqual(summary.repeated.count, 1)
        XCTAssertEqual(summary.repeated.first?.word, "食べる")
        XCTAssertEqual(summary.repeated.first?.count, 2)
    }
    func testReadingSpanClipsAtMidnightAndCrashStopsAtLastActivity() {
        let today = Calendar.current.startOfDay(for: Date()), start = today.addingTimeInterval(-60), end = today.addingTimeInterval(120)
        let stopped = event(.stopped, date: end, started: start)
        XCTAssertEqual(UsageDay.summarize([stopped], date: today).spans.first?.seconds, 120)
        let crashed = [event(.started, date: today), event(.page, date: end)]
        XCTAssertEqual(UsageDay.summarize(crashed, date: today).spans.first?.seconds, 120)
    }
    func testJumpDoesNotCountAsPageTurn() {
        let now = Date()
        let day = UsageDay.summarize([event(.page, date: now, source: "jump"), event(.page, date: now)], date: now)
        XCTAssertEqual(day.pages, 1)
    }
    func testRollingRatioUsesWindowTotalsAndRespectsRecordingStart() {
        let calendar = Calendar.current, today = calendar.startOfDay(for: .now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let points = ReadingTrends.series(values: [yesterday: 3, today: 10], denominators: [yesterday: 1, today: 50], days: 14, since: yesterday, now: today)
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].average, 3)
        XCTAssertEqual(points[1].value, 0.2, accuracy: 0.0001)
        XCTAssertEqual(points[1].average, 13.0 / 51, accuracy: 0.0001)
    }
    func testFirstChartDayUsesHistoryBeforeTheVisibleRange() {
        let calendar = Calendar.current, today = calendar.startOfDay(for: .now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let dayBefore = calendar.date(byAdding: .day, value: -2, to: today)!
        let points = ReadingTrends.series(values: [today: 3, yesterday: 6, dayBefore: 9], days: 1, now: today)
        XCTAssertEqual(points.first?.average, 6)
    }
    func testTornLogLineDoesNotSwallowNextEvent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date(), file = directory.appendingPathComponent(MangaStatisticsTracker.dateKey(for: .now) + ".ndjson")
        try Data("{broken".utf8).write(to: file)
        let log = UsageLog(directory: directory)
        log.append(event(.page, date: now))
        let saved = await log.read()
        XCTAssertEqual(saved.events.count, 1)
        XCTAssertEqual(saved.events[0].type, .page)
        XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }
    @MainActor func testBubbleRevealIsCountedOncePerSessionAndCloseIsIdempotent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = UsageLog(directory: directory)
        let book = BookMetadata(title: "Fixture", cover: nil, folder: "fixture", lastAccess: .now, contentType: .mokuro)
        let session = ReaderUsageSession(book: book, log: log)
        session.reading(true)
        session.reveal(text: "猫", block: "p0b0", page: 1)
        session.reveal(text: "猫", block: "p0b0", page: 1)
        session.reveal(text: "犬", block: "p0b1", page: 1)
        session.reveal(text: "鳥", block: "p1b0", page: 2)
        session.close(); session.close(); session.record(.copied, text: "ignored")
        let snapshot = await log.read()
        XCTAssertEqual(snapshot.events.filter { $0.type == .revealed }.count, 3)
        XCTAssertEqual(snapshot.events.filter { $0.type == .closed }.count, 1)
        XCTAssertFalse(snapshot.events.contains { $0.type == .copied })
    }
    @MainActor func testUnidentifiedBubbleRevealsAreNotCollapsedTogether() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = UsageLog(directory: directory)
        let book = BookMetadata(title: "Fixture", cover: nil, folder: "fixture", lastAccess: .now, contentType: .mokuro)
        let session = ReaderUsageSession(book: book, log: log)
        session.reveal(text: "猫", block: "", page: 1)
        session.reveal(text: "犬", block: "", page: 1)
        session.reveal(text: "鳥", block: nil, page: 2)
        let snapshot = await log.read()
        XCTAssertEqual(snapshot.events.filter { $0.type == .revealed }.map(\.text), ["猫", "犬", "鳥"])
    }
}
