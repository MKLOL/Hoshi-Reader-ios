import XCTest
@testable import Hoshi_Reader

nonisolated final class TtuHistoryParityTests: XCTestCase {
    private func row(_ device: String?, seconds: Double, count: Int, stamp: Int = 100) -> Statistics {
        var row = Statistics.empty(title: "Test", day: "2026-10-31")
        row.deviceId = device; row.readingTime = seconds; row.charactersRead = count
        row.lastStatisticModified = stamp
        return row
    }
    func testSameImportOnTwoDevicesCountsExternalHistoryOnce() {
        let imported = row(nil, seconds: 100, count: 1000)
        let phone = ImportedReadingTotals.applying([imported], to: [], replace: false)
        let tablet = ImportedReadingTotals.applying([imported], to: [], replace: false)
        let merged = Statistics.merged(phone + tablet)
        XCTAssertEqual(Statistics.total(merged).readingTime, 100)
        XCTAssertEqual(Statistics.total(merged).charactersRead, 1000)
        XCTAssertEqual(merged.first?.deviceId, Statistics.ttuDeviceId)
        XCTAssertEqual(ImportedReadingTotals.applying([imported], to: merged, replace: false), merged)
    }
    func testConcurrentImportCheckpointsUnionWithoutCountingLocalReadingTwice() {
        let imported = row(nil, seconds: 100, count: 1000)
        let phoneRead = row("phone", seconds: 20, count: 200)
        let tabletRead = row("tablet", seconds: 30, count: 300)
        let phone = ImportedReadingTotals.applying([imported], to: [phoneRead], replace: false)
        let tablet = ImportedReadingTotals.applying([imported], to: [tabletRead], replace: false)
        let merged = Statistics.merged(phone + tablet)
        XCTAssertEqual(Statistics.total(merged).readingTime, 100)
        XCTAssertEqual(Statistics.total(merged).charactersRead, 1000)
        XCTAssertEqual(merged, Statistics.merged(tablet + phone))
        XCTAssertEqual(merged.first { $0.deviceId == Statistics.ttuDeviceId }?.readingTime, 50)
    }
    func testClearedImportStaysClearedAfterStaleHttpUnionAndKeepsActualReading() {
        let original = ImportedReadingTotals.applying([row(nil, seconds: 100, count: 1000)], to: [], replace: false)
        let local = row("phone", seconds: 5, count: 50, stamp: 200)
        let cleared = ImportedReadingTotals.applying([], to: original + [local], replace: true)
        XCTAssertEqual(Statistics.total(Statistics.merged(original + cleared)).readingTime, 5)
        XCTAssertEqual(Statistics.total(Statistics.merged(cleared + original)).charactersRead, 50)
    }
    func testBaselineWireRoundTripRetainsUnknownToOlderClientsEvidence() throws {
        let source = ImportedReadingTotals.applying([row(nil, seconds: 100, count: 1000)], to: [row("phone", seconds: 20, count: 200)], replace: false)
        XCTAssertEqual(try JSONDecoder().decode([Statistics].self, from: JSONEncoder().encode(source)), source)
        var stripped = source.first { $0.deviceId == Statistics.ttuDeviceId }!
        let rich = stripped
        stripped.importedBaseline = nil
        XCTAssertEqual(Statistics.merged([rich, stripped]).first?.importedBaseline, rich.importedBaseline)
    }
    @MainActor func testFinishedTtuBookKeepsOneHundredPercentAndImportBarrierOrder() throws {
        let info = BookInfo(characterCount: 100, chapterInfo: ["one": .init(spineIndex: 0, currentTotal: 0, chapterCount: 40),
            "two": .init(spineIndex: 1, currentTotal: 40, chapterCount: 60)])
        XCTAssertEqual(SyncManager.importedPosition(characterCount: 100, bookInfo: info)?.progress, 1)
        XCTAssertEqual(SyncManager.importedPosition(characterCount: 101, bookInfo: info)?.spineIndex, 1)
        let coordinator = ReadingImportCoordinator(), root = URL(fileURLWithPath: "/fixture")
        var order: [String] = []
        let observer = coordinator.register(root: root, before: { order.append("flush") }, after: { order.append("reload") })
        coordinator.apply(root: root) { order.append("replace") }
        coordinator.unregister(observer)
        XCTAssertEqual(order, ["flush", "replace", "reload"])
    }
    @MainActor func testJournalTimestampConvergesWithDriveMillisecondsAfterReopening() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ttu-precision-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ReadingPositionRepository(directory: root.appendingPathComponent("journal"),
            device: ReadingDevice(id: "fixture", name: "Fixture"))
        let bookID = UUID().uuidString.lowercased()
        let session = repository.open(bookId: bookID, root: root)
        let timestamp = Date(timeIntervalSince1970: 1_794_100_000.123456)
        let event = try XCTUnwrap(session.navigate(bookmark: Bookmark(chapterIndex: 0, progress: 0.5,
            characterCount: 50, lastModified: timestamp)))
        _ = repository.record(root: root, event: event)
        let original = try XCTUnwrap(BookStorage.loadBookmark(root: root))
        let milliseconds = try XCTUnwrap(SyncManager.progressMilliseconds(timestamp))
        let remote = DriveFile(id: "fixture", name: "progress_1_6_\(milliseconds)_0.5.json")
        XCTAssertEqual(SyncManager.shared.determineSyncDirection(local: original, remoteProgressFile: remote), .synced)
        let reopened = repository.open(bookId: bookID, root: root).initialBookmark
        XCTAssertEqual(reopened?.lastModified, original.lastModified)
        XCTAssertEqual(SyncManager.shared.determineSyncDirection(local: reopened, remoteProgressFile: remote), .synced)
        let newer = DriveFile(id: "fixture", name: "progress_1_6_\(milliseconds + 1)_0.6.json")
        XCTAssertEqual(SyncManager.shared.determineSyncDirection(local: reopened, remoteProgressFile: newer), .importFromTtu)
        XCTAssertNil(SyncManager.progressMilliseconds(Date(timeIntervalSince1970: .infinity)))
    }

}
