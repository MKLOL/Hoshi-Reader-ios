import XCTest
@testable import Hoshi_Reader

/// Background shard preparation must never overwrite a reader save, import or removed book.
nonisolated final class StatisticsPerformanceTests: XCTestCase {
    private func row(_ seconds: Int, device: String = "ios") -> Statistics {
        var row = Statistics.empty(title: "Fixture", day: "2026-10-01", device: ReadingDevice(id: device, name: device))
        row.readingTime = Double(seconds); row.charactersRead = seconds; row.lastStatisticModified = seconds
        row.timeZone = "America/New_York"; row.readingTimeByHour = ["2026-10-01T12:00": Double(seconds)]
        return row
    }
    @MainActor private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("statistics-preparation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try BookStorage.save(BookMetadata(title: "Fixture", cover: nil, folder: "fixture", lastAccess: .now, syncId: "fixture"), inside: root, as: FileNames.metadata)
        try ReadingStatisticsStore.save([row(30)], root: root, scheduleSync: false)
        return root
    }
    func testMonthlyKeyValidationIsStrictWithoutConstructingCalendarFormatters() {
        for month in 1...12 {
            let key = HttpStatisticsLane.prefix + "android/2026-" + (month < 10 ? "0" : "") + String(month) + ".json"
            XCTAssertEqual(HttpStatisticsLane.parse(key)?.month, "2026-" + (month < 10 ? "0" : "") + String(month))
        }
        for month in ["0000-01", "2026-00", "2026-13", "2026-1", "2026-001", "abcd-01", "2026/01", "２０２６-01", "2026-1a", "-026-01"] {
            XCTAssertNil(HttpStatisticsLane.parse(HttpStatisticsLane.prefix + "android/" + month + ".json"), month)
        }
        XCTAssertNotNil(HttpStatisticsLane.parse(HttpStatisticsLane.prefix + "android/0001-01.json"))
        XCTAssertNotNil(HttpStatisticsLane.parse(HttpStatisticsLane.prefix + "android/9999-12.json"))
    }
    @MainActor func testAReaderSaveInvalidatesPreparedBytesAndRetryPreservesBothDevices() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let prepared = try await HttpStatisticsPreparedBook.prepare(root: root, reading: [row(60, device: "android")], text: [])
        try ReadingStatisticsStore.save([row(90)], root: root, scheduleSync: false)
        XCTAssertFalse(try prepared.commit())
        let retry = try await HttpStatisticsPreparedBook.prepare(root: root, reading: [row(60, device: "android")], text: [])
        XCTAssertTrue(try retry.commit())
        let saved = try ReadingStatisticsStore.strictReading(root: root)
        XCTAssertEqual(saved.first { $0.deviceId == "ios" }?.readingTime, 90)
        XCTAssertEqual(saved.first { $0.deviceId == "android" }?.readingTime, 60)
    }
    @MainActor func testAnImportInvalidatesPreparedBytesAndItsCheckpointSurvivesRetry() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let incoming = row(60, device: "android")
        let prepared = try await HttpStatisticsPreparedBook.prepare(root: root, reading: [incoming], text: [])
        try ReadingStatisticsStore.applyDayTotals([row(300)], root: root, replace: false)
        let imported = try ReadingStatisticsStore.strictReading(root: root)
        XCTAssertFalse(try prepared.commit())
        let retry = try await HttpStatisticsPreparedBook.prepare(root: root, reading: [incoming], text: [])
        XCTAssertTrue(try retry.commit())
        let expected = Statistics.merged(imported + [incoming])
        XCTAssertEqual(try ReadingStatisticsStore.strictReading(root: root), expected)
        XCTAssertNotNil(expected.first { $0.deviceId == Statistics.ttuDeviceId }?.importedBaseline)
    }
    @MainActor func testRemovingABookDuringPreparationCannotRecreateItsFolder() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let prepared = try await HttpStatisticsPreparedBook.prepare(root: root, reading: [row(60, device: "android")], text: [])
        try FileManager.default.removeItem(at: root)
        XCTAssertFalse(try prepared.commit())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    @MainActor func testReplacingABookAtTheSamePathRejectsTheEarlierPreparation() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let prepared = try await HttpStatisticsPreparedBook.prepare(root: root, reading: [row(60, device: "android")], text: [])
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try BookStorage.save(BookMetadata(title: "Replacement", cover: nil, folder: "fixture", lastAccess: .now, syncId: "replacement"), inside: root, as: FileNames.metadata)
        XCTAssertFalse(try prepared.commit())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(FileNames.statistics).path))
    }
    @MainActor func testAnInvalidatedAccountCannotCommitPreparedHistory() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let before = try Data(contentsOf: root.appendingPathComponent(FileNames.statistics))
        let prepared = try await HttpStatisticsPreparedBook.prepare(root: root, reading: [row(60, device: "android")], text: [])
        XCTAssertThrowsError(try prepared.commit(stillCurrent: { false })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(FileNames.statistics)), before)
    }
    @MainActor func testPreparedReadingAndTextAreCommittedBeforeOneRootNotification() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let text = MangaTextStatistic(dateKey: "2026-10-01", charactersRead: 100, lastModified: 60, deviceId: "android")
        let prepared = try await HttpStatisticsPreparedBook.prepare(root: root, reading: [row(60, device: "android")], text: [text])
        let notification = expectation(forNotification: .readingStatisticsChanged, object: nil) { note in
            guard note.object as? URL == root else { return false }
            return MainActor.assumeIsolated {
                (try? ReadingStatisticsStore.strictText(root: root)) == [text]
                    && (try? ReadingStatisticsStore.strictReading(root: root).count) == 2
            }
        }
        notification.assertForOverFulfill = true
        XCTAssertTrue(try prepared.commit())
        await fulfillment(of: [notification], timeout: 1)
    }
    @MainActor func testOverviewSnapshotCachesAggregatesAndReloadRetainsAwaitSemantics() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("statistics-overview-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("fixture")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try BookStorage.save(BookMetadata(title: "Fixture", cover: nil, folder: "fixture", lastAccess: .now, syncId: "fixture"), inside: root, as: FileNames.metadata)
        try ReadingStatisticsStore.save([row(300)], root: root, scheduleSync: false)
        let model = StatisticsOverview()
        await model.reload(resetHour: 3, directory: directory)
        XCTAssertTrue(model.loaded)
        XCTAssertEqual(model.books.count, 1)
        XCTAssertEqual(model.days.map(\.seconds), [300])
        XCTAssertEqual(model.devices.map(\.seconds), [300])
        XCTAssertEqual(model.days.map(\.seconds), [300])
        try ReadingStatisticsStore.save([row(600)], root: root, scheduleSync: false)
        await model.reload(resetHour: 3, directory: directory)
        XCTAssertEqual(model.days.map(\.seconds), [600])
        XCTAssertEqual(model.books.first?.days.map(\.seconds), [600])
    }
    @MainActor func testASuspendedOlderOverviewReloadCannotReplaceANewerSnapshot() async {
        let gate = StatisticsSnapshotGate()
        let book = BookMetadata(title: "Fixture", cover: nil, folder: "fixture", lastAccess: .now, syncId: "fixture")
        let earlier = BookReadingSummary(book: book, reading: [row(30)], mangaText: [], finished: false)
        let later = BookReadingSummary(book: book, reading: [row(60)], mangaText: [], finished: false)
        let model = StatisticsOverview { _, reset, _ in
            if reset == 0 { await gate.pause(); return StatisticsOverviewSnapshot(books: [earlier]) }
            return StatisticsOverviewSnapshot(books: [later])
        }
        let directory = FileManager.default.temporaryDirectory
        let first = Task { @MainActor in await model.reload(resetHour: 0, directory: directory) }
        await gate.waitUntilPaused()
        await model.reload(resetHour: 3, directory: directory)
        await gate.release()
        await first.value
        XCTAssertEqual(model.books.first?.seconds, 60)
        XCTAssertEqual(model.days.map(\.seconds), [60])
    }
    @MainActor func testABurstOfBookNotificationsStartsOneOverviewSnapshot() async {
        let started = expectation(description: "debounced snapshot")
        started.assertForOverFulfill = true
        let model = StatisticsOverview { _, _, _ in
            started.fulfill()
            return StatisticsOverviewSnapshot(books: [])
        }
        for _ in 0..<80 { model.scheduleReload() }
        await fulfillment(of: [started], timeout: 2)
    }
}

private actor StatisticsSnapshotGate {
    private var paused = false
    private var pending: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func pause() async {
        await withCheckedContinuation { continuation in
            pending = continuation; paused = true; observer?.resume(); observer = nil
        }
    }
    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { pending?.resume(); pending = nil }
}
