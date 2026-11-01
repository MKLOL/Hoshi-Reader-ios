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
