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
    @MainActor func testDeviceIdentitySurvivesUpgradeButChangesAfterRestoreToAnotherDevice() {
        let suite = "StatisticsParityTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("existing-install", forKey: "statistics.deviceId")
        XCTAssertEqual(ReadingDevice.resolve(defaults: defaults, vendorID: "phone", name: "Phone").id, "existing-install")
        XCTAssertEqual(ReadingDevice.resolve(defaults: defaults, vendorID: "phone", name: "Renamed phone").id, "existing-install")
        let restored = ReadingDevice.resolve(defaults: defaults, vendorID: "tablet", name: "Tablet")
        XCTAssertNotEqual(restored.id, "existing-install")
        XCTAssertEqual(ReadingDevice.resolve(defaults: defaults, vendorID: nil, name: "Tablet").id, restored.id)
        XCTAssertEqual(ReadingDevice.resolve(defaults: defaults, vendorID: "tablet", name: "Tablet").id, restored.id)
    }
    func testEqualStampMergeIsCommutative() {
        let a = row(count: 20), b = row(count: 30)
        XCTAssertEqual(Statistics.merged([a, b]), Statistics.merged([b, a]))
    }
    func testEqualStampMergeUsesKotlinScientificNotation() {
        XCTAssertEqual(StatisticsNumbers.kotlinDoubleText(10_000_000), "1.0E7")
        XCTAssertEqual(StatisticsNumbers.kotlinDoubleText(10_100_000), "1.01E7")
        XCTAssertEqual(StatisticsNumbers.kotlinDoubleText(0.0001), "1.0E-4")
        XCTAssertEqual(StatisticsNumbers.kotlinDoubleText(0.001), "0.001")
        XCTAssertEqual(StatisticsNumbers.kotlinDoubleText(1e20), "1.0E20")
        XCTAssertEqual(StatisticsNumbers.kotlinDoubleText(0), "0.0")
        for (a, b) in [(10_000_000.0, 10_100_000.0), (0.0001, 0.000101)] {
            // Kotlin compares E after the shared '1.0', so the shorter mantissa wins here.
            XCTAssertEqual(Statistics.merged([row(seconds: a), row(seconds: b)]).first?.readingTime, a)
            XCTAssertEqual(Statistics.merged([row(seconds: b), row(seconds: a)]).first?.readingTime, a)
        }
    }
    func testEqualStampMergeUsesKotlinUTF16OrderingForDeviceNames() {
        var emoji = row(), privateUse = row()
        emoji.deviceName = "😀"; privateUse.deviceName = "\u{e000}"
        XCTAssertEqual(Statistics.merged([emoji, privateUse]).first?.deviceName, privateUse.deviceName)
        XCTAssertEqual(Statistics.merged([privateUse, emoji]).first?.deviceName, privateUse.deviceName)
        let first = MangaTextStatistic(dateKey: emoji.dateKey, deviceId: "phone", deviceName: emoji.deviceName)
        let second = MangaTextStatistic(dateKey: emoji.dateKey, deviceId: "phone", deviceName: privateUse.deviceName)
        XCTAssertEqual(MangaTextStatistic.merged([first, second]).first?.deviceName, privateUse.deviceName)
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
        XCTAssertEqual(tracker.dayTotal(at: now.addingTimeInterval(-90), resetHour: 0).charactersRead, 11)
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
    func testPausedTodaySupportsMidnightResetWithoutLosingHistory() {
        let midnight = Calendar.current.startOfDay(for: .now)
        let yesterday = midnight.addingTimeInterval(-60)
        var tracker = MangaStatisticsTracker(title: "Fixture", initialStatistics: [], enabled: true, now: yesterday)
        tracker.start(currentPage: 0, now: yesterday)
        tracker.pause(currentPage: 2, now: yesterday.addingTimeInterval(30))
        XCTAssertEqual(tracker.dayTotal(at: .now, resetHour: 0).readingTime, 0)
        XCTAssertEqual(tracker.dayTotal(at: midnight, resetHour: 0).readingTime, 0)
        XCTAssertEqual(tracker.dayTotal(at: yesterday, resetHour: 0).readingTime, 30)
        XCTAssertEqual(tracker.allTime.charactersRead, 2)
    }
    func testLiveTrackerMergesOtherDevicesWithoutLosingSession() {
        let now = Date(), device = ReadingDevice(id: "phone", name: "phone")
        let day = MangaStatisticsTracker.dateKey(for: now)
        var tracker = MangaStatisticsTracker(title: "Fixture", initialStatistics: [row(day)], enabled: true, now: now, device: device)
        tracker.start(currentPage: 0, now: now)
        tracker.update(currentPage: 3, now: now.addingTimeInterval(10))
        tracker.mergeHistory([row(day), row(day, device: "tablet", seconds: 120, count: 20)])
        XCTAssertEqual(tracker.session.charactersRead, 3)
        XCTAssertEqual(tracker.dayTotal(at: now, resetHour: 0).charactersRead, 33)
        tracker.update(currentPage: 4, now: now.addingTimeInterval(20))
        let saved = tracker.statisticsForPersistence()!
        XCTAssertEqual(saved.first { $0.deviceId == "phone" }?.charactersRead, 14)
        XCTAssertEqual(saved.first { $0.deviceId == "tablet" }?.readingTime, 120)
    }
    func testExtremeImportedNumbersDoNotTrapOrBecomeNonfinite() {
        var extreme = row(seconds: .greatestFiniteMagnitude, count: .max, stamp: .max)
        extreme.add(seconds: .greatestFiniteMagnitude, count: 1, stamp: 1)
        XCTAssertEqual(extreme.charactersRead, .max)
        XCTAssertEqual(extreme.lastStatisticModified, .max)
        XCTAssertTrue(extreme.readingTime.isFinite)
        XCTAssertEqual(StatisticsNumbers.speed(count: .max, seconds: .leastNonzeroMagnitude), .max)
        XCTAssertFalse(StatisticsMath.duration(.infinity).isEmpty)
        let total = Statistics.total([extreme, row(device: "tablet", count: .max)])
        XCTAssertEqual(total.charactersRead, .max)
        XCTAssertTrue(total.readingTime.isFinite)
    }
    func testReadingTimesAxisTopsAndHeatmapLevels() {
        let en = Locale(identifier: "en_US")
        XCTAssertEqual([0, 27, 59, 60, 1920, 1947, 21600, 8079].map { StatisticsMath.readingTime($0, locale: en) },
                       ["0m", "27s", "59s", "1m", "32m", "32m", "6h", "2h 14m"])
        XCTAssertFalse(StatisticsMath.readingTime(.infinity, locale: en).isEmpty)
        XCTAssertEqual([0, 2, 7, 59, 134, 21_000, 0.37].map(StatisticsMath.axisTop), [1, 2, 8, 60, 150, 30_000, 0.4])
        XCTAssertEqual([0, 1, 25, 26, 50, 75, 76, 100].map { StatisticsMath.heatmapLevel($0, maximum: 100) }, [0, 1, 1, 2, 2, 3, 4, 4])
    }
    @MainActor func testCompletionUsesWholeBookCountInsteadOfChapterProgress() {
        let info = BookInfo(characterCount: 10000, chapterInfo: [:])
        XCTAssertFalse(StatisticsMath.isFinished(bookmark: Bookmark(chapterIndex: 0, progress: 1, characterCount: 1000), info: info, isManga: false))
        XCTAssertTrue(StatisticsMath.isFinished(bookmark: Bookmark(chapterIndex: 9, progress: 0.99, characterCount: 9995), info: info, isManga: false))
        XCTAssertFalse(StatisticsMath.isFinished(bookmark: Bookmark(chapterIndex: 0, progress: 1, characterCount: 1000), info: nil, isManga: false))
    }
    func testDeviceSummariesIncludeOCROnlyHistoryAndNewestNames() {
        var original = row(count: 5); original.deviceName = "Old phone"
        let text = [MangaTextStatistic(dateKey: original.dateKey, charactersRead: 100, lastModified: 2, deviceId: "phone", deviceName: "New phone"),
                    MangaTextStatistic(dateKey: original.dateKey, charactersRead: 50, lastModified: 3, deviceId: "tablet", deviceName: "Tablet")]
        let manga = StatisticsMath.devices(reading: [original], text: text, isManga: true)
        XCTAssertEqual(manga.count, 2)
        XCTAssertEqual(manga.first { $0.deviceId == "phone" }?.name, "New phone")
        XCTAssertEqual(manga.first { $0.deviceId == "phone" }?.pages, 5)
        XCTAssertEqual(manga.first { $0.deviceId == "tablet" }?.characters, 50)
        let all = StatisticsMath.combineDevices(manga + StatisticsMath.devices(reading: [original], text: [], isManga: false))
        XCTAssertEqual(all.first { $0.deviceId == "phone" }?.books, 2)
        XCTAssertEqual(all.first { $0.deviceId == "phone" }?.characters, 105)
        XCTAssertEqual(all.first { $0.deviceId == "phone" }?.name, "New phone")
    }
    @MainActor func testCollapsedDriveRowsRetainSpeedHistory() {
        var first = row(); first.minReadingSpeed = 15; first.altMinReadingSpeed = 20; first.maxReadingSpeed = 60
        var second = row(device: "tablet"); second.minReadingSpeed = 10; second.altMinReadingSpeed = 30; second.maxReadingSpeed = 80
        let collapsed = ReadingStatisticsStore.collapsed([first, second])[0]
        XCTAssertEqual(collapsed.minReadingSpeed, 10)
        XCTAssertEqual(collapsed.altMinReadingSpeed, 20)
        XCTAssertEqual(collapsed.maxReadingSpeed, 80)
        XCTAssertNil(collapsed.deviceId)
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
    @MainActor func testMixedDeviceMigrationKeepsSharedUnknownBucketAcrossSync() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var legacy = row(); legacy.deviceId = nil; legacy.deviceName = nil
        let known = row(device: "tablet", seconds: 120)
        try BookStorage.save([legacy, known], inside: root, as: FileNames.statistics)
        let transport = StatisticsMemoryKV()
        _ = try await transport.put(key: "books/fixture/statistics", contentType: "application/json", body: JSONEncoder().encode(ReadingStatisticsBlob(syncId: "fixture", entries: [legacy, known])))
        try await HttpReadingStatisticsSync().exchange(root: root, syncId: "fixture", transport: transport)
        let result = ReadingStatisticsStore.reading(root: root)
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.contains { $0.deviceId == nil })
        XCTAssertEqual(Statistics.total(result).readingTime, 180)
    }
    @MainActor func testPreviouslyExchangedUnknownHistoryIsNotAttributedOnMigration() throws {
        for stateName in [HttpReadingStatisticsSync.stateFile, ".http_sync_statistics.json"] {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            var legacy = row(); legacy.deviceId = nil; legacy.deviceName = nil
            try BookStorage.save([legacy], inside: root, as: FileNames.statistics)
            try Data("{}".utf8).write(to: root.appendingPathComponent(stateName))
            XCTAssertNil(ReadingStatisticsStore.reading(root: root).first?.deviceId)
        }
    }
    @MainActor func testBoundedGETRejectsLengthAndChunkedOversizeThroughTrackingWrapper() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StatisticsURLProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let client = HttpSyncKvClient(baseURL: "https://statistics.invalid", bearerToken: "fixture", session: session)
        let wrapped = HttpSyncWriteTrackingTransport(base: client)
        for key in ["length", "chunked"] {
            do { _ = try await wrapped.getBounded(key: key, maxBytes: 1024); XCTFail("Expected size rejection") }
            catch { XCTAssertTrue(error.localizedDescription.contains("size limit")) }
        }
        let accepted = try await wrapped.getBounded(key: "small", maxBytes: 1024)
        XCTAssertEqual(accepted?.body, Data("{}".utf8))
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
    @MainActor func testExchangeKeepsReaderSaveThatLandsDuringGET() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        try ReadingStatisticsStore.save([row()], root: root, scheduleSync: false)
        let remote = try JSONEncoder().encode(ReadingStatisticsBlob(syncId: "fixture", entries: [row(device: "tablet", seconds: 120)]))
        let transport = StatisticsMemoryKV()
        _ = try await transport.put(key: "books/fixture/statistics", contentType: "application/json", body: remote)
        await transport.pauseNextGET()
        let exchange = Task { try await HttpReadingStatisticsSync().exchange(root: root, syncId: "fixture", transport: transport) }
        await transport.waitForPausedGET()
        try ReadingStatisticsStore.save([row(seconds: 90, stamp: 2)], root: root, scheduleSync: false)
        await transport.resumeGET()
        try await exchange.value
        XCTAssertEqual(Statistics.total(ReadingStatisticsStore.reading(root: root)).readingTime, 210)
        let uploaded = try await transport.get(key: "books/fixture/statistics")!
        XCTAssertEqual(Statistics.total(try JSONDecoder().decode(ReadingStatisticsBlob.self, from: uploaded.body).entries).readingTime, 210)
    }
    @MainActor func testSameLengthRemoteEditIsFetchedWhenListingStampChanges() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        try ReadingStatisticsStore.save([row()], root: root, scheduleSync: false)
        let transport = StatisticsMemoryKV(), sync = HttpReadingStatisticsSync(), key = "books/fixture/statistics"
        try await sync.exchange(root: root, syncId: "fixture", transport: transport)
        let first = try await transport.get(key: key)!
        let edited = try JSONEncoder().encode(ReadingStatisticsBlob(syncId: "fixture", entries: [row(seconds: 90, stamp: 2)]))
        // The first serialization is sorted; JSON object order does not change the byte length.
        XCTAssertEqual(first.body.count, edited.count)
        _ = try await transport.put(key: key, contentType: "application/json", body: edited)
        let meta = HttpSyncKvKeyMeta(key: key, lastModified: "2026-09-24T10:01:00Z", size: edited.count)
        try await sync.exchange(root: root, syncId: "fixture", transport: transport, listing: [key: meta])
        XCTAssertEqual(Statistics.total(ReadingStatisticsStore.reading(root: root)).readingTime, 90)
    }
    @MainActor func testWrongStatisticsIdentityDoesNotOverwriteHistory() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        try ReadingStatisticsStore.save([row()], root: root, scheduleSync: false)
        let transport = StatisticsMemoryKV()
        _ = try await transport.put(key: "books/fixture/statistics", contentType: "application/json", body: JSONEncoder().encode(ReadingStatisticsBlob(syncId: "wrong", entries: [])))
        do { try await HttpReadingStatisticsSync().exchange(root: root, syncId: "fixture", transport: transport); XCTFail("Expected rejection") } catch {}
        XCTAssertEqual(Statistics.total(ReadingStatisticsStore.reading(root: root)).readingTime, 60)
    }
    @MainActor func testBatchStatisticsFailureDoesNotBlockNextBook() async throws {
        let bad = try directory(), good = try directory()
        defer { try? FileManager.default.removeItem(at: bad); try? FileManager.default.removeItem(at: good) }
        try ReadingStatisticsStore.save([row()], root: bad, scheduleSync: false)
        try ReadingStatisticsStore.save([row()], root: good, scheduleSync: false)
        let transport = StatisticsMemoryKV()
        _ = try await transport.put(key: "books/bad/statistics", contentType: "application/json", body: Data("{".utf8))
        let errors = await HttpReadingStatisticsSync().pushLocalChanges(roots: [(bad, "bad"), (good, "good")], transport: transport)
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors[0].contains("bad"))
        let uploaded = try await transport.get(key: "books/good/statistics")
        XCTAssertNotNil(uploaded)
        XCTAssertEqual(Statistics.total(ReadingStatisticsStore.reading(root: bad)).readingTime, 60)
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

private nonisolated final class StatisticsURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let key = request.url!.lastPathComponent
        let headers = key == "length" ? ["Content-Length": "1000000000"] : [:]
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: key == "chunked" ? Data(repeating: 32, count: 8192) : Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor StatisticsMemoryKV: HttpSyncKvTransport {
    var data: [String: Data] = [:]
    var requests = 0
    private var shouldPause = false
    private var paused: CheckedContinuation<Void, Never>?
    private var waiting: CheckedContinuation<Void, Never>?
    func pauseNextGET() { shouldPause = true }
    func waitForPausedGET() async {
        if paused != nil { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func resumeGET() { paused?.resume(); paused = nil }
    func put(key: String, contentType: String, body: Data) async throws -> HttpSyncKvWriteResponse {
        requests += 1; data[key] = body
        return HttpSyncKvKeyMeta(key: key, lastModified: "2026-09-24T10:00:00Z", size: body.count)
    }
    func get(key: String) async throws -> HttpSyncKvFetched? {
        requests += 1
        let result = data[key].map { HttpSyncKvFetched(body: $0, contentType: "application/json", lastModified: "2026-09-24T10:00:00Z", etag: "") }
        if shouldPause {
            shouldPause = false
            await withCheckedContinuation { paused = $0; waiting?.resume(); waiting = nil }
        }
        return result
    }
    func putFile(key: String, contentType: String, fileURL: URL) async throws -> HttpSyncKvWriteResponse { try await put(key: key, contentType: contentType, body: Data(contentsOf: fileURL)) }
    func downloadToFile(key: String, targetURL: URL) async throws -> HttpSyncKvFileFetched? { nil }
    func list(prefix: String?, since: String?, cursor: String?, limit: Int?) async throws -> HttpSyncKvList { HttpSyncKvList(keys: []) }
    func delete(key: String) async throws { data[key] = nil }
}
