import XCTest
import CryptoKit
@testable import Hoshi_Reader

nonisolated final class UsageParityTests: XCTestCase {
    private func event(_ type: UsageEventType, date: Date, started: Date? = nil, text: String? = nil, term: String? = nil, source: String? = nil, found: Bool = true) -> UsageEvent {
        let offset = DateFormatter(); offset.locale = Locale(identifier: "en_US_POSIX"); offset.dateFormat = "xxx"
        return UsageEvent(at: Int64(date.timeIntervalSince1970 * 1000), utcOffset: offset.string(from: date), type: type, session: "session", bookId: "book", bookTitle: "Fixture", contentType: "manga", startedAt: started.map { Int64($0.timeIntervalSince1970 * 1000) }, text: text, term: term, source: source, outcome: found ? "found" : "not-found")
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
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    @MainActor func testJavaGzipRemoteActivityConvergesAndUnchangedCheckTransfersNothing() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let log = UsageLog(directory: directory), lane = HttpUsageLane(log: log), kv = UsageMemoryKV()
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/usage/android-day.ndjson.gz")
        let key = HttpUsageLane.prefix + "android/2026-10-04" + HttpUsageLane.suffix
        _ = try await kv.put(key: key, contentType: "application/gzip", body: Data(contentsOf: fixture))
        let listing = await kv.metadata()
        var errors = await lane.run(transport: kv, listing: listing, deviceID: "ios", scope: "account-a", flush: true, retryFailed: true)
        XCTAssertTrue(errors.isEmpty, "\(errors)")
        let snapshot = await log.read(now: Date(timeIntervalSince1970: 1791043200))
        XCTAssertEqual(snapshot.events.count, 1); XCTAssertEqual(snapshot.events[0].term, "猫")
        XCTAssertTrue(snapshot.events[0].session?.hasPrefix("device:android|") == true)
        let count = await kv.requests
        errors = await lane.run(transport: kv, listing: listing, deviceID: "ios", scope: "account-a", flush: true, retryFailed: true)
        XCTAssertTrue(errors.isEmpty)
        let after = await kv.requests; XCTAssertEqual(count, after)
        let writes = await kv.writes; XCTAssertEqual(writes, [key])
    }
    @MainActor func testOwnRestoredLogMergesBeforeUploadAndPastMonthsCompactOnlyOwnDays() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let calendar = StatisticsZone.calendar(zone: TimeZone(secondsFromGMT: 0)!)
        let now = ReadingDay.parse("2026-10-12", calendar: calendar)!
        let log = UsageLog(directory: directory), lane = HttpUsageLane(log: log, now: { now }), kv = UsageMemoryKV()
        let a = ReadingDay.parse("2026-09-29", calendar: calendar)!.addingTimeInterval(3600)
        let b = a.addingTimeInterval(3600)
        log.append(event(.lookup, date: a, term: "猫", source: "page"))
        var raw = try JSONEncoder().encode(event(.lookup, date: b, term: "犬", source: "page")); raw.append(10)
        let ownDay = HttpUsageLane.prefix + "ios/2026-09-29" + HttpUsageLane.suffix
        let peerDay = HttpUsageLane.prefix + "android/2026-09-29" + HttpUsageLane.suffix
        _ = try await kv.put(key: ownDay, contentType: "application/gzip", body: UsageGzip.compress(raw))
        _ = try await kv.put(key: peerDay, contentType: "application/gzip", body: UsageGzip.compress(raw))
        let errors = await lane.run(transport: kv, listing: await kv.metadata(), deviceID: "ios", scope: "account-a", flush: true, retryFailed: true)
        XCTAssertTrue(errors.isEmpty, "\(errors)")
        let snapshot = await log.read(now: now)
        XCTAssertEqual(snapshot.events.filter { $0.session?.hasPrefix("local|") == true }.count, 2)
        let monthKey = HttpUsageLane.prefix + "ios/2026-09" + HttpUsageLane.suffix
        let uploaded = try await kv.get(key: monthKey)!
        XCTAssertEqual(try UsageGzip.expand(uploaded.body).split(separator: 10).count, 2)
        let deleted = await kv.deleted; XCTAssertEqual(deleted, [ownDay])
        let peerSaved = try await kv.get(key: peerDay); XCTAssertNotNil(peerSaved)
    }
    @MainActor func testUsageAccountSwitchDropsOnlyOtherDevicesAndKeepsLocalReading() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let log = UsageLog(directory: directory), lane = HttpUsageLane(log: log), kv = UsageMemoryKV(), now = Date()
        log.append(event(.lookup, date: now, term: "local"))
        var peer = try JSONEncoder().encode(event(.lookup, date: now, term: "remote")); peer.append(10)
        let day = MangaStatisticsTracker.dateKey(for: now), key = HttpUsageLane.prefix + "android/" + day + HttpUsageLane.suffix
        _ = try await kv.put(key: key, contentType: "application/gzip", body: UsageGzip.compress(peer))
        _ = await lane.run(transport: kv, listing: await kv.metadata(), deviceID: "ios", scope: "account-a", flush: true, retryFailed: true)
        let before = await log.read(); XCTAssertEqual(before.events.count, 2)
        _ = await lane.run(transport: kv, listing: [:], deviceID: "ios", scope: "account-b", flush: true, retryFailed: true)
        let events = await log.read()
        XCTAssertEqual(events.events.map(\.term), ["local"])
    }
    @MainActor func testBadGzipAndFailedOwnReadCannotOverwriteServerOrRemoveDays() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let log = UsageLog(directory: directory), lane = HttpUsageLane(log: log), kv = UsageMemoryKV()
        let day = MangaStatisticsTracker.dateKey(for: .now), key = HttpUsageLane.prefix + "ios/" + day + HttpUsageLane.suffix
        log.append(event(.lookup, date: .now, term: "local"))
        let bad = Data("broken gzip".utf8)
        _ = try await kv.put(key: key, contentType: "application/gzip", body: bad)
        let metadata = HttpSyncKvKeyMeta(key: key, lastModified: "2026-10-04T00:00:00Z", size: bad.count)
        let errors = await lane.run(transport: kv, listing: [key: metadata], deviceID: "ios", scope: "account-a", flush: true, retryFailed: true)
        XCTAssertFalse(errors.isEmpty)
        let server = try await kv.get(key: key); XCTAssertEqual(server?.body, bad)
        let deleted = await kv.deleted; XCTAssertTrue(deleted.isEmpty)
    }
    func testGzipIsDeterministicAndRejectsCorruptionTruncationAndExpansionBombs() throws {
        let raw = Data("日本語\n".utf8), compressed = try UsageGzip.compress(raw)
        XCTAssertEqual(compressed, try UsageGzip.compress(raw))
        XCTAssertEqual(try UsageGzip.expand(compressed), raw)
        XCTAssertThrowsError(try UsageGzip.expand(Data(compressed.dropLast())))
        var bad = compressed; bad[bad.count - 5] ^= 1
        XCTAssertThrowsError(try UsageGzip.expand(bad))
        XCTAssertThrowsError(try UsageGzip.expand(compressed, maxBytes: 2))
        XCTAssertEqual(try UsageGzip.expand(compressed, maxBytes: raw.count), raw)
    }

    @MainActor func testEarlierOwnServerMonthIsRepairedBeforeConfirmingCompaction() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let calendar = StatisticsZone.calendar(zone: TimeZone(secondsFromGMT: 0)!)
        let now = ReadingDay.parse("2026-10-12", calendar: calendar)!
        let log = UsageLog(directory: directory), lane = HttpUsageLane(log: log, now: { now }), kv = UsageMemoryKV()
        let at = ReadingDay.parse("2026-09-29", calendar: calendar)!.addingTimeInterval(3600)
        let first = event(.lookup, date: at, term: "A"), second = event(.lookup, date: at.addingTimeInterval(60), term: "B")
        log.append(first); log.append(second)
        var errors = await lane.run(transport: kv, listing: [:], deviceID: "ios", scope: "a", flush: true, retryFailed: true)
        XCTAssertTrue(errors.isEmpty)
        let key = HttpUsageLane.prefix + "ios/2026-09" + HttpUsageLane.suffix
        let original = try await kv.get(key: key)!
        var older = Data(try UsageGzip.expand(original.body).split(separator: 10).first!); older.append(10)
        _ = try await kv.put(key: key, contentType: "application/gzip", body: UsageGzip.compress(older))
        errors = await lane.run(transport: kv, listing: await kv.metadata(), deviceID: "ios", scope: "a", flush: true, retryFailed: true)
        XCTAssertTrue(errors.isEmpty)
        let restored = try await kv.get(key: key)!
        XCTAssertEqual(try UsageGzip.expand(restored.body).split(separator: 10).count, 2)
    }
    @MainActor func testCorruptPastOwnDayDoesNotBlockIndependentTodayUpload() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(), log = UsageLog(directory: directory), lane = HttpUsageLane(log: log), kv = UsageMemoryKV()
        let calendar = Calendar.current, old = calendar.date(byAdding: .day, value: -1, to: now)!
        log.append(event(.lookup, date: now, term: "today"))
        let badKey = HttpUsageLane.prefix + "ios/" + MangaStatisticsTracker.dateKey(for: old) + HttpUsageLane.suffix
        _ = try await kv.put(key: badKey, contentType: "application/gzip", body: Data("bad gzip".utf8))
        let errors = await lane.run(transport: kv, listing: await kv.metadata(), deviceID: "ios", scope: "a", flush: true, retryFailed: true)
        XCTAssertFalse(errors.isEmpty)
        let todayKey = HttpUsageLane.prefix + "ios/" + MangaStatisticsTracker.dateKey(for: now) + HttpUsageLane.suffix
        let today = try await kv.get(key: todayKey)
        XCTAssertNotNil(today)
    }
    @MainActor func testOwnServerLogRestoresMissingLocalDayEvenWithCachedETag() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(), log = UsageLog(directory: directory), lane = HttpUsageLane(log: log), kv = UsageMemoryKV()
        log.append(event(.lookup, date: now, term: "restored"))
        _ = await lane.run(transport: kv, listing: [:], deviceID: "ios", scope: "a", flush: true, retryFailed: true)
        let file = directory.appendingPathComponent(MangaStatisticsTracker.dateKey(for: now) + ".ndjson")
        try FileManager.default.removeItem(at: file)
        let errors = await lane.run(transport: kv, listing: await kv.metadata(), deviceID: "ios", scope: "a", flush: true, retryFailed: true)
        XCTAssertTrue(errors.isEmpty)
        let restored = await log.read()
        XCTAssertEqual(restored.events.map(\.term), ["restored"])
    }

}

private actor UsageMemoryKV: HttpSyncKvTransport {
    private var data: [String: Data] = [:]
    var requests = 0
    var writes: [String] = []
    var deleted: [String] = []
    func metadata() -> [String: HttpSyncKvKeyMeta] {
        data.mapValues { HttpSyncKvKeyMeta(key: "", lastModified: "2026-10-04T00:00:00Z", etag: "sha256:" + SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined(), size: $0.count) }.reduce(into: [:]) { result, value in
            result[value.key] = HttpSyncKvKeyMeta(key: value.key, lastModified: value.value.lastModified, etag: value.value.etag, size: value.value.size)
        }
    }
    func put(key: String, contentType: String, body: Data) async throws -> HttpSyncKvWriteResponse { requests += 1; writes.append(key); data[key] = body; return metadata()[key]! }
    func get(key: String) async throws -> HttpSyncKvFetched? { requests += 1; return data[key].map { HttpSyncKvFetched(body: $0, contentType: "application/gzip", lastModified: "2026-10-04T00:00:00Z", etag: metadata()[key]!.etag!) } }
    func putFile(key: String, contentType: String, fileURL: URL) async throws -> HttpSyncKvWriteResponse { try await put(key: key, contentType: contentType, body: Data(contentsOf: fileURL)) }
    func downloadToFile(key: String, targetURL: URL) async throws -> HttpSyncKvFileFetched? { nil }
    func list(prefix: String?, since: String?, cursor: String?, limit: Int?) async throws -> HttpSyncKvList { HttpSyncKvList(keys: Array(metadata().values)) }
    func delete(key: String) async throws { requests += 1; deleted.append(key); data.removeValue(forKey: key) }
}
