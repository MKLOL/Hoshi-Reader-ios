import XCTest
@testable import Hoshi_Reader

nonisolated final class ReaderPreferencesParityTests: XCTestCase {
    func testAndroidWireTypesAndBounds() throws {
        let bytes = Data(#"{"version":1,"deviceId":"android-a","records":{"mangaShowFurigana":{"value":false,"editedAt":1793433600000,"deviceId":"android-a"},"dictionaryCard.width":{"value":null,"editedAt":1793433600001,"deviceId":"android-a"}}}"#.utf8)
        let blob = try JSONDecoder().decode(ReaderPreferencesBlob.self, from: bytes)
        try ReaderPreferencesProtocol.validate(blob.records)
        XCTAssertEqual(blob.records["mangaShowFurigana"]?.value, .bool(false))
        XCTAssertEqual(blob.records["dictionaryCard.width"]?.value, .null)
        for (name, value) in [("mangaShowFurigana", ReaderPreferenceValue.number(0)),
            ("fontSize", .number(15)), ("fontSize", .number(22.5)), ("theme", .string("sepia")),
            ("selectedFont", .string("../private/font")), ("dictionaryCard.width", .number(99)),
            ("statisticsTimeZone", .string("UTC")), ("sasayaki.syncEnabled", .bool(true))] {
            XCTAssertThrowsError(try ReaderPreferencesProtocol.validate([name: .init(value: value, editedAt: 1, deviceId: "android-a")]), name)
        }
        XCTAssertThrowsError(try ReaderPreferencesProtocol.validate(["fontSize": .init(value: .number(22), editedAt: ReaderPreferencesProtocol.maxTimestamp, deviceId: "a")]))
    }

    @MainActor func testIndependentOfflineEditsAndNullableResetConvergeWithoutRepeatedWrites() async throws {
        let store = PreferencesMemoryStore()
        store.records["fontSize"] = .init(value: .number(26), editedAt: 100, deviceId: "ios-a")
        let kv = PreferencesMemoryKV()
        try await kv.seed(.init(deviceId: "android-a", records: [
            "mangaShowFurigana": .init(value: .bool(false), editedAt: 101, deviceId: "android-a"),
            "dictionaryCard.width": .init(value: .null, editedAt: 102, deviceId: "android-a"),
            "future.option": .init(value: .string("preserved"), editedAt: 103, deviceId: "android-a")]))
        let lane = HttpReaderPreferencesLane(store: store)
        let first = await lane.run(transport: kv)
        XCTAssertTrue(first.uploaded); XCTAssertTrue(first.downloaded); XCTAssertTrue(first.errors.isEmpty)
        XCTAssertEqual(store.records["fontSize"]?.value, .number(26))
        XCTAssertEqual(store.records["dictionaryCard.width"]?.value, .null)
        XCTAssertEqual(store.records["future.option"]?.editedAt, 103)
        let second = await lane.run(transport: kv)
        XCTAssertFalse(second.uploaded); XCTAssertFalse(second.downloaded)
        let writes = await kv.writes
        XCTAssertEqual(writes, ["app/reader_settings/ios-a"])
    }

    @MainActor func testOwnShardIsReadEvenWhenListingOmitsIt() async throws {
        let store = PreferencesMemoryStore(), kv = PreferencesMemoryKV()
        store.records["fontSize"] = .init(value: .number(22), editedAt: 10, deviceId: "ios-a")
        try await kv.seed(.init(deviceId: "ios-a", records: ["fontSize": .init(value: .number(30), editedAt: 20, deviceId: "ios-a")]))
        let result = await HttpReaderPreferencesLane(store: store).run(transport: kv, listing: [:])
        XCTAssertTrue(result.downloaded); XCTAssertFalse(result.uploaded)
        XCTAssertEqual(store.records["fontSize"]?.value, .number(30))
    }

    @MainActor func testMalformedShardBlocksPublicationAndChangedAccountBlocksApplication() async throws {
        let store = PreferencesMemoryStore(), kv = PreferencesMemoryKV()
        store.records["fontSize"] = .init(value: .number(22), editedAt: 10, deviceId: "ios-a")
        await kv.seedRaw(key: "app/reader_settings/android-a", data: Data("broken".utf8))
        let result = await HttpReaderPreferencesLane(store: store).run(transport: kv)
        XCTAssertFalse(result.errors.isEmpty); XCTAssertFalse(result.uploaded)
        let writes = await kv.writes
        XCTAssertTrue(writes.isEmpty)
        let switched = await HttpReaderPreferencesLane(store: store).run(transport: kv, stillCurrent: { false })
        XCTAssertFalse(switched.downloaded); XCTAssertFalse(switched.uploaded)
        XCTAssertEqual(store.records.count, 1)
    }

    /// "Keep Screen On" chosen on Android arrives as a synced record. It holds the screen only
    /// while a book or manga is open, and an audiobook pausing does not dim it under the reader.
    @MainActor func testKeepScreenOnSyncsFromAndroidAndHoldsTheScreenOnlyWhileAReaderIsOpen() throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: ScreenAwake.settingKey)
        defer {
            ReaderPreferencesStore.shared.reset(); ScreenAwake.reset()
            if let previous { defaults.set(previous, forKey: ScreenAwake.settingKey) } else { defaults.removeObject(forKey: ScreenAwake.settingKey) }
        }
        defaults.removeObject(forKey: ScreenAwake.settingKey)
        ReaderPreferencesStore.shared.reset(); ScreenAwake.reset()
        let config = UserConfig()
        XCTAssertFalse(config.keepScreenOnWhileReading)
        ScreenAwake.readerOpened()
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)
        XCTAssertTrue(try ReaderPreferencesStore.shared.merge(["keepScreenOnWhileReading": .init(value: .bool(true), editedAt: 10, deviceId: "android-a")]))
        XCTAssertTrue(config.keepScreenOnWhileReading)
        XCTAssertTrue(defaults.bool(forKey: ScreenAwake.settingKey))
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
        ScreenAwake.set(.audiobook, true); ScreenAwake.set(.audiobook, false)
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
        ScreenAwake.readerClosed()
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)
        ScreenAwake.set(.audiobook, true)
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
        ScreenAwake.set(.audiobook, false)
        ScreenAwake.readerOpened()
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
        config.keepScreenOnWhileReading = false
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)
        XCTAssertEqual(try ReaderPreferencesStore.shared.snapshot()["keepScreenOnWhileReading"]?.value, .bool(false))
    }

    /// These reader settings were carried unused until iOS gained them. A choice made on Android
    /// before then is applied the first time the setting is known, and a local edit is published.
    @MainActor func testReaderSettingsFirstChosenOnAndroidAreAppliedOnceIOSHasThem() throws {
        let defaults = UserDefaults.standard
        let keys = ["blurImages", "paragraphSpacing", "readerAlwaysShowProgress"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            ReaderPreferencesStore.shared.reset()
            for (key, value) in zip(keys, previous) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        keys.forEach { defaults.removeObject(forKey: $0) }
        ReaderPreferencesStore.shared.reset()
        let config = UserConfig()
        XCTAssertFalse(config.blurImages); XCTAssertEqual(config.paragraphSpacing, 0); XCTAssertFalse(config.readerAlwaysShowProgress)
        XCTAssertNil(try ReaderPreferencesStore.shared.snapshot()["blurImages"], "an untouched default is not published")
        XCTAssertTrue(try ReaderPreferencesStore.shared.merge([
            "blurImages": .init(value: .bool(true), editedAt: 10, deviceId: "android-a"),
            "paragraphSpacing": .init(value: .number(1.2), editedAt: 11, deviceId: "android-a"),
            "alwaysShowProgress": .init(value: .bool(true), editedAt: 12, deviceId: "android-a")]))
        XCTAssertTrue(config.blurImages); XCTAssertEqual(config.paragraphSpacing, 1.2); XCTAssertTrue(config.readerAlwaysShowProgress)
        XCTAssertTrue(defaults.bool(forKey: "blurImages")); XCTAssertTrue(defaults.bool(forKey: "readerAlwaysShowProgress"))
        config.paragraphSpacing = 0.5
        let edited = try XCTUnwrap(try ReaderPreferencesStore.shared.snapshot()["paragraphSpacing"])
        XCTAssertEqual(edited.value, .number(0.5)); XCTAssertEqual(edited.deviceId, ReaderPreferencesStore.shared.deviceId)
        XCTAssertGreaterThan(edited.editedAt, 11)
    }

    @MainActor func testEmptyInstallationPublishesNoDefaultsAndClocksHaveStableTieBreak() async {
        let store = PreferencesMemoryStore(), kv = PreferencesMemoryKV()
        let outcome = await HttpReaderPreferencesLane(store: store).run(transport: kv)
        XCTAssertFalse(outcome.uploaded)
        let a = ReaderPreferenceRecord(value: .bool(true), editedAt: 10, deviceId: "a")
        let b = ReaderPreferenceRecord(value: .bool(false), editedAt: 10, deviceId: "b")
        XCTAssertTrue(b.isNewer(than: a)); XCTAssertFalse(a.isNewer(than: b))
    }
}

@MainActor private final class PreferencesMemoryStore: ReaderPreferencesSyncing {
    let deviceId = "ios-a"
    var records: [String: ReaderPreferenceRecord] = [:]
    func snapshot() throws -> [String: ReaderPreferenceRecord] { records }
    func merge(_ remote: [String: ReaderPreferenceRecord]) throws -> Bool {
        let old = records
        for (name, record) in remote where record.isNewer(than: records[name]) { records[name] = record }
        return old != records
    }
}

private actor PreferencesMemoryKV: HttpSyncKvTransport {
    var bodies: [String: Data] = [:]
    var writes: [String] = []
    func seed(_ blob: ReaderPreferencesBlob) throws { bodies[ReaderPreferencesProtocol.prefix + blob.deviceId] = try JSONEncoder().encode(blob) }
    func seedRaw(key: String, data: Data) { bodies[key] = data }
    func put(key: String, contentType: String, body: Data) async throws -> HttpSyncKvWriteResponse {
        bodies[key] = body; writes.append(key)
        return .init(key: key, lastModified: "2026-10-31T00:00:00Z", etag: "write-\(writes.count)", size: body.count)
    }
    func get(key: String) async throws -> HttpSyncKvFetched? {
        bodies[key].map { .init(body: $0, contentType: "application/json", lastModified: "", etag: "") }
    }
    func putFile(key: String, contentType: String, fileURL: URL) async throws -> HttpSyncKvWriteResponse {
        try await put(key: key, contentType: contentType, body: Data(contentsOf: fileURL))
    }
    func downloadToFile(key: String, targetURL: URL) async throws -> HttpSyncKvFileFetched? { nil }
    func list(prefix: String?, since: String?, cursor: String?, limit: Int?) async throws -> HttpSyncKvList {
        .init(keys: bodies.keys.filter { $0.hasPrefix(prefix ?? "") }.map { .init(key: $0, lastModified: "") })
    }
    func delete(key: String) async throws { bodies.removeValue(forKey: key) }
}
