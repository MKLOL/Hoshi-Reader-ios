import XCTest
@testable import Hoshi_Reader

nonisolated final class StatisticsParityTests: XCTestCase {
    private func row(_ day: String = "2026-09-24", device: String = "phone", seconds: Double = 60, count: Int = 10, stamp: Int = 1) -> Statistics {
        var row = Statistics.empty(title: "Fixture", day: day, device: ReadingDevice(id: device, name: device))
        row.readingTime = seconds; row.charactersRead = count; row.lastStatisticModified = stamp
        return row
    }
    func testDeviceRowsAddButDuplicatesDoNot() {
        let rows = Statistics.merged([row(), row(), row(device: "tablet", seconds: 120)])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Statistics.total(rows).readingTime, 180)
        XCTAssertEqual(Statistics.total(rows).charactersRead, 20)
    }
    func testEqualStampMergeIsCommutative() {
        let a = row(count: 20), b = row(count: 30)
        XCTAssertEqual(Statistics.merged([a, b]), Statistics.merged([b, a]))
    }
    func testClockRollbackResumesAndStampsRemainMonotonic() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let device = ReadingDevice(id: "phone", name: "phone")
        let day = MangaStatisticsTracker.dateKey(for: now)
        var tracker = MangaStatisticsTracker(title: "Fixture", initialStatistics: [row(day, stamp: Int.max - 100)], enabled: true, now: now, device: device)
        tracker.start(currentPage: 0, now: now)
        tracker.update(currentPage: 0, now: now.addingTimeInterval(-100))
        tracker.update(currentPage: 1, now: now.addingTimeInterval(-90))
        XCTAssertEqual(tracker.session.readingTime, 10)
        XCTAssertEqual(tracker.today.charactersRead, 11)
        XCTAssertGreaterThan(tracker.statisticsForPersistence()!.first!.lastStatisticModified, Int.max - 100)
    }
    func testPausedTimeAndBaselineJumpsAreNotCounted() {
        let now = Date()
        var tracker = MangaStatisticsTracker(title: "Fixture", initialStatistics: [], enabled: true, now: now)
        tracker.start(currentPage: 0, now: now)
        tracker.pause(currentPage: 1, now: now.addingTimeInterval(10))
        tracker.update(currentPage: 100, now: now.addingTimeInterval(100))
        tracker.start(currentPage: 100, now: now.addingTimeInterval(100))
        tracker.update(currentPage: 101, now: now.addingTimeInterval(110))
        XCTAssertEqual(tracker.session.readingTime, 20)
        XCTAssertEqual(tracker.session.charactersRead, 2)
    }
    @MainActor func testLegacyMangaMigrationKeepsPagesAndCreatesIndependentTextSidecar() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("{}".utf8).write(to: root.appendingPathComponent(FileNames.mokuro))
        var legacy = row(); legacy.deviceId = nil; legacy.deviceName = nil
        try BookStorage.save([legacy], inside: root, as: FileNames.mangaStatistics)
        try ReadingStatisticsStore.migrate(root: root)
        XCTAssertEqual(ReadingStatisticsStore.reading(root: root).first?.charactersRead, 10)
        XCTAssertTrue(ReadingStatisticsStore.text(root: root).isEmpty)
        try ReadingStatisticsStore.migrate(root: root)
        XCTAssertEqual(ReadingStatisticsStore.reading(root: root).count, 1)
    }
    @MainActor func testSaveKeepsAnotherDevicesHistory() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        try ReadingStatisticsStore.save([row()], root: root, scheduleSync: false)
        try ReadingStatisticsStore.save([row(device: "tablet")], root: root, scheduleSync: false)
        try ReadingStatisticsStore.save([row(seconds: 90, stamp: 2)], root: root, scheduleSync: false)
        XCTAssertEqual(Statistics.total(ReadingStatisticsStore.reading(root: root)).readingTime, 150)
    }
    @MainActor func testStatisticsExchangeMergesDevicesAndSkipsIdleRequests() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        try ReadingStatisticsStore.save([row()], root: root, scheduleSync: false)
        let transport = StatisticsMemoryKV()
        let key = "books/fixture/statistics"
        _ = try await transport.put(key: key, contentType: "application/json", body: JSONEncoder().encode(ReadingStatisticsBlob(syncId: "fixture", entries: [row(device: "tablet", seconds: 120)])))
        let sync = HttpReadingStatisticsSync()
        try await sync.exchange(root: root, syncId: "fixture", transport: transport)
        XCTAssertEqual(Statistics.total(ReadingStatisticsStore.reading(root: root)).readingTime, 180)
        let before = await transport.requests
        try await sync.exchange(root: root, syncId: "fixture", transport: transport)
        let after = await transport.requests
        XCTAssertEqual(before, after)
    }
    @MainActor func testWrongStatisticsIdentityDoesNotOverwriteHistory() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        try ReadingStatisticsStore.save([row()], root: root, scheduleSync: false)
        let transport = StatisticsMemoryKV()
        _ = try await transport.put(key: "books/fixture/statistics", contentType: "application/json", body: JSONEncoder().encode(ReadingStatisticsBlob(syncId: "wrong", entries: [])))
        do { try await HttpReadingStatisticsSync().exchange(root: root, syncId: "fixture", transport: transport); XCTFail("Expected rejection") } catch {}
        XCTAssertEqual(Statistics.total(ReadingStatisticsStore.reading(root: root)).readingTime, 60)
    }
    func testStreakIncludesYesterdayWhileTodayIsStillOpen() {
        let today = StatisticsMath.date("2026-09-24")!
        let days = ["2026-09-22", "2026-09-23"].map { DailyReading(date: StatisticsMath.date($0)!, seconds: 600) }
        XCTAssertEqual(StatisticsMath.streak(days, goalMinutes: 10, now: today).current, 2)
        XCTAssertEqual(StatisticsMath.streak(days, goalMinutes: 15, now: today).current, 0)
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private actor StatisticsMemoryKV: HttpSyncKvTransport {
    var data: [String: Data] = [:]
    var requests = 0
    func put(key: String, contentType: String, body: Data) async throws -> HttpSyncKvWriteResponse {
        requests += 1; data[key] = body
        return HttpSyncKvKeyMeta(key: key, lastModified: "2026-09-24T10:00:00Z", size: body.count)
    }
    func get(key: String) async throws -> HttpSyncKvFetched? {
        requests += 1
        return data[key].map { HttpSyncKvFetched(body: $0, contentType: "application/json", lastModified: "2026-09-24T10:00:00Z", etag: "") }
    }
    func putFile(key: String, contentType: String, fileURL: URL) async throws -> HttpSyncKvWriteResponse { try await put(key: key, contentType: contentType, body: Data(contentsOf: fileURL)) }
    func downloadToFile(key: String, targetURL: URL) async throws -> HttpSyncKvFileFetched? { nil }
    func list(prefix: String?, since: String?, cursor: String?, limit: Int?) async throws -> HttpSyncKvList { HttpSyncKvList(keys: []) }
    func delete(key: String) async throws { data[key] = nil }
}
