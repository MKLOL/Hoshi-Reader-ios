import XCTest
import CryptoKit
@testable import Hoshi_Reader

nonisolated final class StatisticsRobustnessTests: XCTestCase {
    private func row(_ seconds: Int, device: String = "ios", samples: [Int: Int] = [:]) -> Statistics {
        var value = Statistics.empty(title: "Fixture", day: "2026-10-01", device: ReadingDevice(id: device, name: device))
        value.readingTime = Double(seconds); value.charactersRead = seconds; value.lastStatisticModified = seconds
        value.mangaPageSeconds = samples
        return value
    }
    func testWeightedMedianKeepsExactWeightsBeyondTheIntegerTotalLimit() {
        XCTAssertEqual(row(1, samples: [30: .max, 60: .max]).medianPageSeconds, 45)
        XCTAssertEqual(row(1, samples: [10: .max, 20: .max, 30: .max]).medianPageSeconds, 20)
        XCTAssertEqual(row(1, samples: [10: .max, 20: .max - 1]).medianPageSeconds, 10)
        XCTAssertEqual(row(1, samples: [10: .max - 1, 20: .max]).medianPageSeconds, 20)
        XCTAssertEqual(row(1, samples: [10: 2, 20: 1, 30: 1]).medianPageSeconds, 15)
    }
    func testImportedTotalsAndFinishEstimatesStayWithinDurationsRange() {
        let cap = Duration.seconds(Int.max)
        XCTAssertEqual(StatisticsNumbers.safeDuration(.greatestFiniteMagnitude), cap)
        XCTAssertEqual(StatisticsNumbers.safeDuration(.infinity), cap)
        XCTAssertEqual(StatisticsNumbers.safeDuration(.nan), .zero)
        XCTAssertEqual(StatisticsNumbers.safeDuration(-1), .zero)
        XCTAssertEqual(StatisticsNumbers.safeDuration(1.5), .milliseconds(1500))
        let estimate = MangaStatisticsView.secondsRemaining(remainingPages: 100, medianPageSeconds: Double(Int.max))!
        XCTAssertEqual(StatisticsNumbers.safeDuration(estimate), cap)
        XCTAssertFalse(StatisticsNumbers.formattedDuration(estimate).isEmpty)
        XCTAssertFalse(StatisticsNumbers.formattedDuration(.greatestFiniteMagnitude).isEmpty)
    }

    @MainActor private func fixture() throws -> (URL, UserDefaults, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("statistics-robustness-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "StatisticsRobustness." + UUID().uuidString
        return (root, UserDefaults(suiteName: suite)!, suite)
    }
    @MainActor private func install(_ value: Statistics, in root: URL) throws -> URL {
        let folder = root.appendingPathComponent("fixture")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try BookStorage.save(BookMetadata(title: "Fixture", cover: nil, folder: "fixture", lastAccess: .now, syncId: "fixture"), inside: folder, as: FileNames.metadata)
        try ReadingStatisticsStore.save([value], root: folder, scheduleSync: false)
        return folder
    }
    @MainActor func testOwnReadingAndSettingsUploadsDoNotStartTheNextPollPass() async throws {
        let (root, defaults, suite) = try fixture()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let clock = RobustnessClock(), kv = RobustnessKV()
        let folder = try install(row(30), in: root)
        let lane = HttpStatisticsLane(directory: root, device: ReadingDevice(id: "ios", name: "iOS"), defaults: defaults, now: { clock.now })
        await lane.poll(transport: kv, listing: await kv.listing(), scope: "account-a")?.value
        try ReadingStatisticsStore.save([row(60)], root: folder, scheduleSync: false)
        StatisticsPreferencesStore.save(HttpStatisticsPreferences(streakMinimumMinutes: 20, dayResetHour: 3, updatedAt: 20), defaults: defaults)
        clock.now += 31
        let errors = await lane.run(transport: kv, listing: await kv.listing(), scope: "account-a")
        XCTAssertEqual(errors, [])
        let requests = await kv.requests
        let uploaded = await kv.listing()
        XCTAssertNil(lane.poll(transport: kv, listing: uploaded, scope: "account-a"), "our acknowledged uploads must not start another disk pass")
        let after = await kv.requests
        XCTAssertEqual(after, requests)
        clock.now += 60
        let retry = lane.poll(transport: kv, listing: await kv.listing(), scope: "account-a")
        XCTAssertNotNil(retry, "the periodic retry deadline must survive own-upload bookkeeping")
        await retry?.value
    }
    @MainActor func testUploadCannotReplaceAnotherScopesPollObservation() async throws {
        let (root, defaults, suite) = try fixture()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let clock = RobustnessClock(), first = RobustnessKV(), second = RobustnessKV()
        let folder = try install(row(30), in: root)
        let lane = HttpStatisticsLane(directory: root, device: ReadingDevice(id: "ios", name: "iOS"), defaults: defaults, now: { clock.now })
        await lane.poll(transport: first, listing: await first.listing(), scope: "account-a")?.value
        try ReadingStatisticsStore.save([row(60)], root: folder, scheduleSync: false)
        let errors = await lane.run(transport: second, listing: await second.listing(), scope: "account-b", flush: true)
        XCTAssertEqual(errors, [])
        let firstListing = await first.listing()
        XCTAssertNil(lane.poll(transport: first, listing: firstListing, scope: "account-a"))
    }
    @MainActor func testUploadCannotReplaceANewerObservationOfItsKey() async throws {
        let (root, defaults, suite) = try fixture()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let clock = RobustnessClock(), kv = RobustnessKV()
        let folder = try install(row(30), in: root)
        let lane = HttpStatisticsLane(directory: root, device: ReadingDevice(id: "ios", name: "iOS"), defaults: defaults, now: { clock.now })
        await lane.poll(transport: kv, listing: await kv.listing(), scope: "account-a")?.value
        try ReadingStatisticsStore.save([row(60)], root: folder, scheduleSync: false)
        let key = HttpStatisticsLane.prefix + "ios/2026-10.json"
        let newer = HttpStatisticsShard(deviceId: "ios", month: "2026-10", books: ["fixture": HttpStatisticsShardBook(title: "Fixture", reading: [row(90)])])
        let newerBody = try JSONEncoder().encode(newer)
        let queued = RobustnessPoll()
        await kv.afterNextPut(key) { @MainActor in
            _ = try? await kv.put(key: key, contentType: "application/json", body: newerBody)
            queued.task = lane.poll(transport: kv, listing: await kv.listing(), scope: "account-a")
        }
        clock.now += 31
        let errors = await lane.run(transport: kv, listing: await kv.listing(), scope: "account-a")
        XCTAssertEqual(errors, [])
        await queued.task?.value
        let latest = await kv.listing()
        XCTAssertNil(lane.poll(transport: kv, listing: latest, scope: "account-a"), "the older in-flight response must not replace the newer poll's key")
    }
    @MainActor func testUnchangedShardRepairsRemovedAndOlderLocalHistoryWithoutLegacyCopies() async throws {
        for removeFile in [true, false] {
            let (root, defaults, suite) = try fixture()
            defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
            let clock = RobustnessClock(), kv = RobustnessKV()
            let expected = row(90, device: "android", samples: [30: 3])
            let shard = HttpStatisticsShard(deviceId: "android", month: "2026-10", books: ["remote": HttpStatisticsShardBook(title: "Remote", contentType: "Mokuro", reading: [expected], mangaText: [MangaTextStatistic(dateKey: "2026-10-01", charactersRead: 900, lastModified: 90, deviceId: "android")])])
            let key = HttpStatisticsLane.prefix + "android/2026-10.json"
            _ = try await kv.put(key: key, contentType: "application/json", body: JSONEncoder().encode(shard))
            let lane = HttpStatisticsLane(directory: root, device: ReadingDevice(id: "ios", name: "iOS"), defaults: defaults, now: { clock.now })
            var errors = await lane.run(transport: kv, listing: await kv.listing(), scope: "account-a")
            XCTAssertEqual(errors, [])
            for legacy in await kv.listing().keys where legacy.hasPrefix("books/") { try await kv.delete(key: legacy) }
            let kept = root.appendingPathComponent(StatisticsHistory.directoryName).appendingPathComponent("remote")
            if removeFile {
                try FileManager.default.removeItem(at: kept.appendingPathComponent(FileNames.statistics))
                try FileManager.default.removeItem(at: kept.appendingPathComponent(FileNames.mangaStatistics))
            } else {
                try BookStorage.save([row(30, device: "android")], inside: kept, as: FileNames.statistics)
                try BookStorage.save([MangaTextStatistic(dateKey: "2026-10-01", charactersRead: 300, lastModified: 30, deviceId: "android")], inside: kept, as: FileNames.mangaStatistics)
            }
            let before = await kv.gets[key, default: 0]
            clock.now += 10
            errors = await lane.run(transport: kv, listing: await kv.listing(), scope: "account-a")
            XCTAssertEqual(errors, [])
            XCTAssertEqual(try ReadingStatisticsStore.strictReading(root: kept), [expected])
            XCTAssertEqual(try ReadingStatisticsStore.strictText(root: kept).first?.charactersRead, 900)
            let after = await kv.gets[key, default: 0]
            XCTAssertEqual(after, before + 1, "an unchanged ETag must be fetched again after the local cache regresses")
        }
    }
    @MainActor func testAdvancingLocalReadingDoesNotRefetchItsUnchangedShard() async throws {
        let (root, defaults, suite) = try fixture()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let clock = RobustnessClock(), kv = RobustnessKV()
        let folder = try install(row(30), in: root)
        let lane = HttpStatisticsLane(directory: root, device: ReadingDevice(id: "ios", name: "iOS"), defaults: defaults, now: { clock.now })
        _ = await lane.run(transport: kv, listing: await kv.listing(), scope: "account-a")
        let key = HttpStatisticsLane.prefix + "ios/2026-10.json", before = await kv.gets[key, default: 0]
        try ReadingStatisticsStore.save([row(60)], root: folder, scheduleSync: false)
        clock.now += 10
        let errors = await lane.run(transport: kv, listing: await kv.listing(), scope: "account-a")
        XCTAssertEqual(errors, [])
        let after = await kv.gets[key, default: 0]
        XCTAssertEqual(after, before)
    }

    @MainActor func testAccountChangeDuringShardGetCannotApplyUploadOrAcknowledgeOldRows() async throws {
        let (root, defaults, suite) = try fixture()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let kv = RobustnessKV(), operation = RobustnessOperation()
        let folder = try install(row(30), in: root), original = try Data(contentsOf: folder.appendingPathComponent(FileNames.statistics))
        let key = HttpStatisticsLane.prefix + "android/2026-10.json"
        let shard = HttpStatisticsShard(deviceId: "android", month: "2026-10", books: ["fixture": HttpStatisticsShardBook(title: "Fixture", reading: [row(90, device: "android")])])
        _ = try await kv.put(key: key, contentType: "application/json", body: JSONEncoder().encode(shard))
        let lane = HttpStatisticsLane(directory: root, device: ReadingDevice(id: "ios", name: "iOS"), defaults: defaults)
        lane.problem = "Existing account status"
        await kv.afterNextGet(key) { @MainActor in operation.current = false }
        let listing = await kv.listing(), beforePuts = await kv.puts
        let errors = await lane.run(transport: kv, listing: listing, scope: "account-a", flush: true, stillCurrent: { operation.current })
        XCTAssertEqual(errors, [])
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(FileNames.statistics)), original)
        let afterPuts = await kv.puts
        XCTAssertEqual(afterPuts, beforePuts)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".http_sync_statistics_lane.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".http_sync_statistics_cache").path))
        XCTAssertEqual(lane.problem, "Existing account status")
        XCTAssertNil(lane.lastChecked)
    }

    @MainActor func testAStalePollDoesNotSuppressTheNextCurrentPollInTheSameScope() async throws {
        let (root, defaults, suite) = try fixture()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let kv = RobustnessKV(), operation = RobustnessOperation()
        _ = try install(row(30), in: root)
        let key = HttpStatisticsLane.prefix + "android/2026-10.json"
        let shard = HttpStatisticsShard(deviceId: "android", month: "2026-10", books: ["fixture": HttpStatisticsShardBook(title: "Fixture", reading: [row(90, device: "android")])])
        _ = try await kv.put(key: key, contentType: "application/json", body: JSONEncoder().encode(shard))
        let lane = HttpStatisticsLane(directory: root, device: ReadingDevice(id: "ios", name: "iOS"), defaults: defaults)
        await kv.afterNextGet(key) { @MainActor in operation.current = false }
        await lane.poll(transport: kv, listing: await kv.listing(), scope: "account-a", stillCurrent: { operation.current })?.value
        operation.current = true
        let retry = lane.poll(transport: kv, listing: await kv.listing(), scope: "account-a", stillCurrent: { operation.current })
        XCTAssertNotNil(retry)
        await retry?.value
    }

    @MainActor func testAccountChangeDuringLegacyGetCannotApplyOrUploadOldRows() async throws {
        let (root, defaults, suite) = try fixture()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let kv = RobustnessKV(), operation = RobustnessOperation()
        let folder = try install(row(30), in: root), original = try Data(contentsOf: folder.appendingPathComponent(FileNames.statistics))
        let key = "books/fixture/statistics"
        _ = try await kv.put(key: key, contentType: "application/json", body: JSONEncoder().encode(ReadingStatisticsBlob(syncId: "fixture", entries: [row(90, device: "android")])))
        await kv.afterNextGet(key) { @MainActor in operation.current = false }
        let lane = HttpStatisticsLane(directory: root, device: ReadingDevice(id: "ios", name: "iOS"), defaults: defaults)
        let before = await kv.puts
        let errors = await lane.run(transport: kv, listing: await kv.listing(), scope: "account-a", flush: true, stillCurrent: { operation.current })
        XCTAssertEqual(errors, [])
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(FileNames.statistics)), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(HttpReadingStatisticsSync.stateFile).path))
        let after = await kv.puts
        XCTAssertEqual(after, before)
    }

    @MainActor func testAccountChangeDuringUsageGetCannotStoreOrAcknowledgeOldEvents() async throws {
        let (root, defaults, suite) = try fixture()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let kv = RobustnessKV(), operation = RobustnessOperation(), log = UsageLog(directory: root.appendingPathComponent("usage"))
        let day = MangaStatisticsTracker.dateKey(for: .now)
        let key = HttpUsageLane.prefix + "android/" + day + HttpUsageLane.suffix
        let event = UsageEvent(at: Int64(Date().timeIntervalSince1970 * 1000), utcOffset: "+00:00", type: .lookup, session: "old-account", term: "old")
        var body = try JSONEncoder().encode(event); body.append(10)
        _ = try await kv.put(key: key, contentType: "application/gzip", body: UsageGzip.compress(body))
        await kv.afterNextGet(key) { @MainActor in operation.current = false }
        let lane = HttpUsageLane(log: log), before = await kv.puts
        let errors = await lane.run(transport: kv, listing: await kv.listing(), deviceID: "ios", scope: "account-a", flush: true, retryFailed: true, stillCurrent: { operation.current })
        XCTAssertEqual(errors, [])
        let snapshot = await log.read(), after = await kv.puts
        XCTAssertTrue(snapshot.events.isEmpty)
        XCTAssertEqual(after, before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.directory.appendingPathComponent(".http_sync_usage_lane.json").path))
    }
}

@MainActor private final class RobustnessClock { var now = Date(timeIntervalSince1970: 1_791_000_000) }
@MainActor private final class RobustnessPoll { var task: Task<Void, Never>? }
@MainActor private final class RobustnessOperation { var current = true }
private actor RobustnessKV: HttpSyncKvTransport {
    private var bodies: [String: Data] = [:]
    private var hook: (key: String, work: @MainActor @Sendable () async -> Void)?
    private var getHook: (key: String, work: @MainActor @Sendable () async -> Void)?
    var gets: [String: Int] = [:]
    var requests = 0
    var puts = 0
    func afterNextPut(_ key: String, work: @escaping @MainActor @Sendable () async -> Void) { hook = (key, work) }
    func afterNextGet(_ key: String, work: @escaping @MainActor @Sendable () async -> Void) { getHook = (key, work) }
    func listing() -> [String: HttpSyncKvKeyMeta] {
        Dictionary(uniqueKeysWithValues: bodies.map { key, body in
            (key, HttpSyncKvKeyMeta(key: key, lastModified: "2026-10-01T00:00:00Z", etag: SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined(), size: body.count))
        })
    }
    func put(key: String, contentType: String, body: Data) async throws -> HttpSyncKvWriteResponse {
        requests += 1; puts += 1; bodies[key] = body
        let response = listing()[key]!
        if let pending = hook, pending.key == key { hook = nil; await pending.work() }
        return response
    }
    func get(key: String) async throws -> HttpSyncKvFetched? {
        requests += 1; gets[key, default: 0] += 1
        if let pending = getHook, pending.key == key { getHook = nil; await pending.work() }
        return bodies[key].map { HttpSyncKvFetched(body: $0, contentType: "application/json", lastModified: "2026-10-01T00:00:00Z", etag: listing()[key]!.etag!) }
    }
    func putFile(key: String, contentType: String, fileURL: URL) async throws -> HttpSyncKvWriteResponse { try await put(key: key, contentType: contentType, body: Data(contentsOf: fileURL)) }
    func downloadToFile(key: String, targetURL: URL) async throws -> HttpSyncKvFileFetched? { nil }
    func list(prefix: String?, since: String?, cursor: String?, limit: Int?) async throws -> HttpSyncKvList { HttpSyncKvList(keys: Array(listing().values)) }
    func delete(key: String) async throws { requests += 1; bodies[key] = nil }
}
