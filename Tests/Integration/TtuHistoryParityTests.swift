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

nonisolated final class ReadingPositionRemoteTests: XCTestCase {
    @MainActor private func fixture() throws -> (URL, URL, ReadingPositionRepository) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("position-remote-\(UUID())")
        let root = directory.appendingPathComponent("book")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (directory, root, ReadingPositionRepository(directory: directory.appendingPathComponent("positions"),
            device: ReadingDevice(id: "local", name: "Local")))
    }

    private func event(_ index: Int, distinctOrigin: Bool = false) -> ReadingPositionEvent {
        ReadingPositionEvent(id: "remote-\(index)", deviceId: "remote", deviceName: "Remote",
            originId: distinctOrigin ? "origin-\(index)" : "remote-origin", sequence: Int64(index + 1),
            sessionId: "remote-session", action: "pageTurn", from: nil,
            position: ReadingPosition(chapterIndex: index, progress: 0.5, characterCount: index),
            occurredAt: Double(2000 + index), compatibilityAt: Double(2000 + index), basedOn: nil,
            seen: [:], missingTimestamp: false, bookId: "book")
    }

    @MainActor func testLargeRemoteJournalPreparesOffMainIncludingWinnerAcross512Origins() async throws {
        let (directory, root, repository) = try fixture()
        // Every origin is a concurrent head, exercising the quadratic winner calculation as
        // well as JSON decode, validation and serialization. The body is valid on the wire.
        let events = (0..<512).map { event($0, distinctOrigin: true) }
        let body = try JSONEncoder().encode(ReadingPositionJournal(bookId: "book", deviceId: "remote", events: events, heads: []))
        XCTAssertLessThan(body.count, 2 * 1024 * 1024)
        try await responsive {
            let moved = try await repository.mergeRemote(body: body, bookId: "book", writer: "remote", root: root)
            XCTAssertTrue(moved)
        }
        XCTAssertEqual(BookStorage.loadBookmark(root: root)?.chapterIndex, 511)
        XCTAssertEqual(repository.snapshot(bookId: "book").heads.count, 512)
        // After a process relaunch, loading the existing large local journal belongs in the
        // same budget as the changed incoming body, including its validation and winner.
        let fresh = ReadingPositionRepository(directory: directory.appendingPathComponent("positions"),
            device: ReadingDevice(id: "local", name: "Local"))
        try await responsive {
            let moved = try await fresh.mergeRemote(body: body, bookId: "book", writer: "remote", root: root)
            XCTAssertFalse(moved)
        }
        XCTAssertEqual(fresh.snapshot(bookId: "book").heads.count, 512)

        let session = fresh.open(bookId: "book", root: root)
        let local = try XCTUnwrap(session.navigate(bookmark: Bookmark(chapterIndex: 600, progress: 0.6,
            characterCount: 6000, lastModified: Date(timeIntervalSinceReferenceDate: 10_000))))
        XCTAssertTrue(local.isValid, "a valid imported history must permit the next local move")
        XCTAssertEqual(local.seen.count, 256)
        XCTAssertNotNil(local.seen[local.originId], "reserve the local origin before adding its sequence")
        XCTAssertEqual(local.seen["origin-511"], 512, "the displayed winner remains causally observed")
        XCTAssertEqual(fresh.record(root: root, event: local)?.chapterIndex, 600)
        let imported = fresh.saveLegacy(bookId: "book", root: root,
            bookmark: Bookmark(chapterIndex: 700, progress: 0.7, characterCount: 7000,
                               lastModified: Date(timeIntervalSinceReferenceDate: 20_000)))
        XCTAssertEqual(imported?.chapterIndex, 700)
        let restored = ReadingPositionRepository(directory: directory.appendingPathComponent("positions"),
            device: ReadingDevice(id: "local", name: "Local")).snapshot(bookId: "book")
        XCTAssertEqual(restored.winner?.position.chapterIndex, 700)
        XCTAssertTrue(restored.pending.contains(local.id))
        let legacy = try XCTUnwrap(restored.winner)
        XCTAssertTrue(legacy.isValid)
        XCTAssertLessThanOrEqual(legacy.seen.count, 256)
        XCTAssertEqual(legacy.seen[local.originId], local.sequence)
    }

    func testLargeWinnerIndexExcludesSelfObservationButKeepsOtherHeadsObservations() {
        var events = (0..<10).map { event($0, distinctOrigin: true) }
        for index in events.indices { events[index].seen[events[index].originId] = events[index].sequence }
        var state = ReadingPositionState(bookId: "book", heads: Dictionary(uniqueKeysWithValues: events.map { ($0.originId, $0) }))
        XCTAssertEqual(state.winner?.id, "remote-9")
        events[0].seen[events[9].originId] = events[9].sequence
        state.heads[events[0].originId] = events[0]
        XCTAssertEqual(state.winner?.id, "remote-8")
    }

    @MainActor func testColdOwnHistoryIndexOf80BooksDecodesAwayFromMain() async throws {
        let (directory, _, _) = try fixture()
        let journals = directory.appendingPathComponent("positions")
        try writeOwnHistories(80, in: journals)
        let fresh = ReadingPositionRepository(directory: journals, device: ReadingDevice(id: "local", name: "Local"))
        try await responsive { try await fresh.prepareForSync() }
        XCTAssertEqual(fresh.ownHistories().count, 80)
        XCTAssertEqual(fresh.snapshot(bookId: "book-79").events.count, 50)
    }

    private func writeOwnHistories(_ count: Int, in journals: URL) throws {
        let encoder = JSONEncoder()
        for index in 0..<count {
            let id = "book-\(index)"
            let events = (0..<50).map { number in
                var value = event(number); value.bookId = id; value.deviceId = "local"
                return value
            }
            let state = ReadingPositionState(bookId: id, heads: ["remote-origin": events.last!], events: events, pending: [events.last!.id])
            try encoder.encode(state).write(to: ReadingPositionRepository.journalURL(id, in: journals), options: .atomic)
        }
    }

    @MainActor func testColdHistoryWarmupKeepsNavigationBetweenCommitBatchesAndRelaunch() async throws {
        let (directory, root, _) = try fixture()
        let journals = directory.appendingPathComponent("positions")
        try writeOwnHistories(24, in: journals)
        let fresh = ReadingPositionRepository(directory: journals, device: ReadingDevice(id: "local", name: "Local"))
        let session = fresh.open(bookId: "book-0", root: root)
        let local = try XCTUnwrap(session.navigate(bookmark: Bookmark(chapterIndex: 600, progress: 0.6,
            characterCount: 6000, lastModified: Date(timeIntervalSinceReferenceDate: 10_000))))
        var checks = 0
        try await fresh.prepareForSync(stillCurrent: {
            checks += 1
            if checks == 3 { _ = fresh.record(root: root, event: local) }
            return true
        })
        XCTAssertGreaterThan(checks, 3, "a cold library must yield between commit batches")
        XCTAssertEqual(fresh.ownHistories().count, 24)
        XCTAssertTrue(fresh.ownHistories()["book-0"]?.contains(local.id) == true)
        XCTAssertEqual(fresh.snapshot(bookId: "book-0").winner?.id, local.id)
        let restored = ReadingPositionRepository(directory: journals, device: ReadingDevice(id: "local", name: "Local"))
        XCTAssertEqual(restored.open(bookId: "book-0", root: root).initialBookmark?.chapterIndex, 600)
        XCTAssertTrue(restored.snapshot(bookId: "book-0").pending.contains(local.id))
    }

    @MainActor func testAccountChangeBetweenColdHistoryCommitBatchesCancelsWarmup() async throws {
        let (directory, _, _) = try fixture()
        let journals = directory.appendingPathComponent("positions")
        try writeOwnHistories(24, in: journals)
        let fresh = ReadingPositionRepository(directory: journals, device: ReadingDevice(id: "local", name: "Local"))
        var checks = 0
        do {
            try await fresh.prepareForSync(stillCurrent: { checks += 1; return checks < 3 })
            XCTFail("the old account completed its history warmup")
        } catch is CancellationError { }
        XCTAssertEqual(checks, 3)
        try await fresh.prepareForSync()
        XCTAssertEqual(fresh.ownHistories().count, 24)
    }

    @MainActor func testHistoryResetBetweenColdCommitBatchesDoesNotRestoreDeletedJournals() async throws {
        let (directory, _, _) = try fixture()
        let journals = directory.appendingPathComponent("positions")
        try writeOwnHistories(24, in: journals)
        let fresh = ReadingPositionRepository(directory: journals, device: ReadingDevice(id: "local", name: "Local"))
        var checks = 0
        try await fresh.prepareForSync(stillCurrent: {
            checks += 1
            if checks == 3 { fresh.removeAllHistory() }
            return true
        })
        XCTAssertGreaterThan(checks, 3)
        XCTAssertTrue(fresh.ownHistories().isEmpty)
        XCTAssertTrue(fresh.snapshot(bookId: "book-0").events.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ReadingPositionRepository.journalURL("book-0", in: journals).path))
    }

    @MainActor func testDurableLocalTurnAfterLargeCausalImportStaysWithinAFrameAndNoopsKeepBytes() async throws {
        let (directory, root, repository) = try fixture()
        let frontier = Dictionary(uniqueKeysWithValues: (0..<128).map { (String(format: "frontier-%03d", $0), Int64(1)) })
        let events = (0..<512).map { number in var value = event(number); value.seen = frontier; return value }
        let body = try JSONEncoder().encode(ReadingPositionJournal(bookId: "book", deviceId: "remote", events: events, heads: [events.last!]))
        XCTAssertLessThan(body.count, 2 * 1024 * 1024)
        _ = try await repository.mergeRemote(body: body, bookId: "book", writer: "remote", root: root)
        let file = ReadingPositionRepository.journalURL("book", in: directory.appendingPathComponent("positions"))
        let before = try Data(contentsOf: file), modified = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let session = repository.open(bookId: "book", root: root)
        repository.observe(bookId: "book", root: root)
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified)

        let local = try XCTUnwrap(session.navigate(bookmark: Bookmark(chapterIndex: 600, progress: 0.6,
            characterCount: 6000, lastModified: Date(timeIntervalSinceReferenceDate: 10_000))))
        let startCPU = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID), start = ProcessInfo.processInfo.systemUptime
        let saved = repository.record(root: root, event: local)
        let cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - startCPU, wall = ProcessInfo.processInfo.systemUptime - start
        print("durable position turn after \(body.count)-byte causal import: \(Double(cpu) / 1e6) ms CPU, \(wall * 1000) ms wall")
        XCTAssertLessThan(cpu, 8_000_000, "a durable local page turn exceeded a frame")
        XCTAssertLessThan(wall, 0.1)
        XCTAssertEqual(saved?.chapterIndex, 600)
        XCTAssertEqual(BookStorage.loadBookmark(root: root)?.chapterIndex, 600)

        let after = try Data(contentsOf: file), afterModified = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let fresh = ReadingPositionRepository(directory: directory.appendingPathComponent("positions"),
            device: ReadingDevice(id: "local", name: "Local"))
        XCTAssertEqual(fresh.open(bookId: "book", root: root).initialBookmark?.chapterIndex, 600)
        XCTAssertEqual(fresh.snapshot(bookId: "book").winner?.id, local.id)
        XCTAssertTrue(fresh.snapshot(bookId: "book").pending.contains(local.id))
        XCTAssertEqual(try Data(contentsOf: file), after)
        XCTAssertEqual(try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, afterModified)
    }

    @MainActor private func responsive(_ work: @MainActor () async throws -> Void) async throws {
        var longestCPU: UInt64 = 0, longestWall: TimeInterval = 0
        var lastCPU = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID), lastWall = ProcessInfo.processInfo.systemUptime
        func sample() {
            let cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID), wall = ProcessInfo.processInfo.systemUptime
            longestCPU = max(longestCPU, cpu - lastCPU); longestWall = max(longestWall, wall - lastWall)
            lastCPU = cpu; lastWall = wall
        }
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled { sample(); try? await Task.sleep(for: .milliseconds(1)) }
        }
        do { try await work() }
        catch { heartbeat.cancel(); await heartbeat.value; throw error }
        sample(); heartbeat.cancel(); await heartbeat.value
        print("position sync longest main-thread slice: \(Double(longestCPU) / 1e6) ms CPU, \(longestWall * 1000) ms wall")
        XCTAssertLessThan(longestCPU, 8_000_000, "remote history held the main thread for \(Double(longestCPU) / 1e6) ms CPU")
        XCTAssertLessThan(longestWall, 0.1, "remote history blocked the UI for \(longestWall) seconds")
    }

    @MainActor func testLocalNavigationWhileRemoteMergePreparesSurvivesTheRetryAndRelaunch() async throws {
        let (directory, root, repository) = try fixture(), gate = PositionRemoteGate()
        let session = repository.open(bookId: "book", root: root)
        let first = try XCTUnwrap(session.navigate(bookmark: Bookmark(chapterIndex: 1, progress: 0.1,
            characterCount: 10, lastModified: Date(timeIntervalSinceReferenceDate: 1000))))
        _ = repository.record(root: root, event: first)
        let body = try JSONEncoder().encode(ReadingPositionJournal(bookId: "book", deviceId: "remote", events: [event(0)], heads: []))
        let running = Task { try await repository.mergeRemote(body: body, bookId: "book", writer: "remote", root: root,
                                                              beforeCommit: { await gate.pauseOnce() }) }
        await gate.waitUntilPaused()
        let local = try XCTUnwrap(session.navigate(bookmark: Bookmark(chapterIndex: 3, progress: 0.3,
            characterCount: 30, lastModified: Date(timeIntervalSinceReferenceDate: 3000))))
        _ = repository.record(root: root, event: local)
        await gate.release()
        let moved = try await running.value
        XCTAssertFalse(moved, "the fresher local navigation already projected the final winner")
        XCTAssertEqual(BookStorage.loadBookmark(root: root)?.chapterIndex, 3)
        let restored = ReadingPositionRepository(directory: directory.appendingPathComponent("positions"),
            device: ReadingDevice(id: "local", name: "Local")).snapshot(bookId: "book")
        XCTAssertEqual(restored.winner?.id, local.id)
        XCTAssertTrue(restored.events.contains { $0.id == "remote-0" })
        XCTAssertTrue(restored.pending.contains(local.id))
    }

    @MainActor func testAccountSwitchDuringPreparationDoesNotCommitTheOldAccountsHistory() async throws {
        let (directory, root, repository) = try fixture(), gate = PositionRemoteGate()
        let body = try JSONEncoder().encode(ReadingPositionJournal(bookId: "book", deviceId: "remote", events: [event(0)], heads: []))
        var current = true
        let running = Task { try await repository.mergeRemote(body: body, bookId: "book", writer: "remote", root: root,
            stillCurrent: { current }, beforeCommit: { await gate.pauseOnce() }) }
        await gate.waitUntilPaused(); current = false; await gate.release()
        do { _ = try await running.value; XCTFail("the old account committed") } catch is CancellationError { }
        XCTAssertNil(BookStorage.loadBookmark(root: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ReadingPositionRepository.journalURL("book", in: directory.appendingPathComponent("positions")).path))
        XCTAssertTrue(repository.snapshot(bookId: "book").events.isEmpty)
    }

    @MainActor func testRootRemovedDuringPreparationIsNeverRecreated() async throws {
        let (_, root, repository) = try fixture(), gate = PositionRemoteGate()
        let body = try JSONEncoder().encode(ReadingPositionJournal(bookId: "book", deviceId: "remote", events: [event(0)], heads: []))
        let running = Task { try await repository.mergeRemote(body: body, bookId: "book", writer: "remote", root: root,
                                                              beforeCommit: { await gate.pauseOnce() }) }
        await gate.waitUntilPaused(); try FileManager.default.removeItem(at: root); await gate.release()
        do { _ = try await running.value; XCTFail("a removed root committed") } catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertTrue(repository.snapshot(bookId: "book").events.isEmpty)
    }
}

private actor PositionRemoteGate {
    private var used = false
    private var paused = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func pauseOnce() async {
        guard !used else { return }; used = true; paused = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            for waiter in waiters { waiter.resume() }; waiters = []
        }
    }
    func waitUntilPaused() async { if !paused { await withCheckedContinuation { waiters.append($0) } } }
    func release() { continuation?.resume(); continuation = nil }
}
