// Foundation-only transport and storage doubles let the production exchange run on macOS
// when an iOS Simulator runtime is unavailable. Native store/UI coverage stays in XCTest.
import Foundation

nonisolated struct HttpSyncError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
nonisolated struct HttpSyncKvKeyMeta: Equatable, Sendable {
    let key: String
    var etag: String = ""
}
nonisolated struct HttpSyncKvFetched: Sendable { let body: Data }
nonisolated struct HttpSyncKvList: Sendable {
    let keys: [HttpSyncKvKeyMeta]
    var truncated: Bool? = false
    var nextCursor: String? = nil
}
nonisolated protocol HttpSyncKvTransport: Sendable {
    func list(prefix: String?, since: String?, cursor: String?, limit: Int?) async throws -> HttpSyncKvList
    func getBounded(key: String, maxBytes: Int) async throws -> HttpSyncKvFetched?
    func put(key: String, contentType: String, body: Data) async throws -> HttpSyncKvKeyMeta
}
@MainActor protocol ReaderPreferencesSyncing: AnyObject {
    var deviceId: String { get }
    func snapshot() throws -> [String: ReaderPreferenceRecord]
    func merge(_ records: [String: ReaderPreferenceRecord]) throws -> Bool
}
@MainActor final class ReaderPreferencesStore: ReaderPreferencesSyncing {
    static let shared = ReaderPreferencesStore()
    let deviceId = "ios-a"
    var records: [String: ReaderPreferenceRecord] = [:]
    func snapshot() throws -> [String: ReaderPreferenceRecord] { records }
    func merge(_ incoming: [String: ReaderPreferenceRecord]) throws -> Bool {
        let old = records
        for (name, record) in incoming where record.isNewer(than: records[name]) { records[name] = record }
        return old != records
    }
}
actor MemoryKV: HttpSyncKvTransport {
    var data: [String: Data] = [:]
    var writes = 0
    var gets = 0
    func seed(_ blob: ReaderPreferencesBlob) throws { data[ReaderPreferencesProtocol.prefix + blob.deviceId] = try JSONEncoder().encode(blob) }
    func corrupt() { data[ReaderPreferencesProtocol.prefix + "bad"] = Data("broken".utf8) }
    func list(prefix: String?, since: String?, cursor: String?, limit: Int?) async throws -> HttpSyncKvList {
        .init(keys: data.keys.map { .init(key: $0, etag: data[$0]!.base64EncodedString()) })
    }
    func getBounded(key: String, maxBytes: Int) async throws -> HttpSyncKvFetched? {
        gets += 1
        guard let body = data[key] else { return nil }
        precondition(body.count <= maxBytes)
        return .init(body: body)
    }
    func put(key: String, contentType: String, body: Data) async throws -> HttpSyncKvKeyMeta {
        writes += 1; data[key] = body; return .init(key: key)
    }
}
@main struct ReaderPreferencesHarness {
    @MainActor static func main() async throws {
        let record: (ReaderPreferenceValue, Int64, String) -> ReaderPreferenceRecord = { .init(value: $0, editedAt: $1, deviceId: $2) }
        let store = ReaderPreferencesStore(), kv = MemoryKV()
        store.records = ["fontSize": record(.number(26), 100, "ios-a")]
        let structured = ReaderPreferenceValue.object(["nested": .array([.bool(true), .null, .number(42)])])
        try await kv.seed(.init(deviceId: "android-a", records: [
            "mangaShowFurigana": record(.bool(false), 101, "android-a"),
            "dictionaryCard.width": record(.null, 102, "android-a"),
            "future.structure": record(structured, 103, "android-a")]))
        let lane = HttpReaderPreferencesLane(store: store)
        let result = await lane.run(transport: kv)
        precondition(result.errors.isEmpty && result.uploaded && result.downloaded)
        precondition(store.records["fontSize"]?.value == .number(26))
        precondition(store.records["dictionaryCard.width"]?.value == .null)
        precondition(store.records["future.structure"]?.value == structured)
        let second = await lane.run(transport: kv)
        precondition(second.errors.isEmpty && !second.uploaded && !second.downloaded)
        let writes = await kv.writes; precondition(writes == 1)
        let listing = try await kv.list(prefix: nil, since: nil, cursor: nil, limit: nil)
        let metadata = Dictionary(uniqueKeysWithValues: listing.keys.map { ($0.key, $0) })
        _ = await lane.run(transport: kv, listing: metadata, scope: "account-a")
        let before = await kv.gets
        _ = await lane.run(transport: kv, listing: metadata, scope: "account-a")
        let after = await kv.gets; precondition(before == after)
        let restored = ReaderPreferencesStore()
        let own = await HttpReaderPreferencesLane(store: restored).run(transport: kv, listing: [:])
        precondition(own.downloaded && !own.uploaded)
        precondition(restored.records == store.records)
        await kv.corrupt()
        store.records["fontSize"] = record(.number(30), 200, "ios-a")
        let malformed = await lane.run(transport: kv)
        precondition(!malformed.errors.isEmpty && !malformed.uploaded)
        let switchedStore = ReaderPreferencesStore()
        _ = await HttpReaderPreferencesLane(store: switchedStore).run(transport: kv, stillCurrent: { false })
        precondition(switchedStore.records.isEmpty)
        let emptyStore = ReaderPreferencesStore(), emptyKV = MemoryKV()
        let empty = await HttpReaderPreferencesLane(store: emptyStore).run(transport: emptyKV)
        precondition(!empty.uploaded)
        for (name, value) in [("fontSize", ReaderPreferenceValue.number(15)), ("mangaShowFurigana", .number(0)),
            ("selectedFont", .string("../private")), ("theme", .string("sepia")), ("dictionaryCard.width", .number(99))] {
            do { try ReaderPreferencesProtocol.validate([name: record(value, 1, "android-a")]); preconditionFailure("Accepted invalid value") }
            catch { }
        }
        let encoded = try JSONEncoder().encode(ReaderPreferencesBlob(deviceId: "android-a", records: ["future.structure": record(structured, 1, "android-a")]))
        let decoded = try JSONDecoder().decode(ReaderPreferencesBlob.self, from: encoded)
        precondition(decoded.records["future.structure"]?.value == structured)
        print("Reader preferences exchange: convergence, explicit reset, future fields, own-shard recovery, cache, malformed input and account isolation passed")
    }
}
