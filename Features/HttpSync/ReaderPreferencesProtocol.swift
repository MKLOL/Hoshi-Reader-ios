import Foundation

/// Android's typed JSON values. Keeping booleans distinct from numbers prevents a malformed
/// shard from quietly turning a toggle into a numeric preference (or the reverse).
nonisolated indirect enum ReaderPreferenceValue: Codable, Equatable, Sendable {
    case bool(Bool), number(Double), string(String), null
    case array([ReaderPreferenceValue]), object([String: ReaderPreferenceValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Double.self), value.isFinite { self = .number(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([ReaderPreferenceValue].self) { self = .array(value) }
        else { self = .object(try c.decode([String: ReaderPreferenceValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        case .null: try c.encodeNil()
        case .array(let value): try c.encode(value)
        case .object(let value): try c.encode(value)
        }
    }
}

nonisolated struct ReaderPreferenceRecord: Codable, Equatable, Sendable {
    var value: ReaderPreferenceValue
    var editedAt: Int64
    var deviceId: String

    func isNewer(than old: Self?) -> Bool {
        (try? ReaderPreferencesProtocol.winningFields(["value": self], current: old.map { ["value": $0] } ?? [:])) == ["value"]
    }
}

nonisolated struct ReaderPreferencesBlob: Codable, Equatable, Sendable {
    var version: Int = 1
    var deviceId: String
    var records: [String: ReaderPreferenceRecord]
    enum CodingKeys: String, CodingKey { case version, deviceId, records }
    init(deviceId: String, records: [String: ReaderPreferenceRecord], version: Int = 1) {
        self.version = version; self.deviceId = deviceId; self.records = records
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        deviceId = try c.decode(String.self, forKey: .deviceId)
        records = try c.decodeIfPresent([String: ReaderPreferenceRecord].self, forKey: .records) ?? [:]
    }
}

nonisolated enum ReaderPreferencesProtocol {
    static let prefix = "app/reader_settings/"
    static let maxTimestamp: Int64 = 253402300799999
    static let maxBody = 64 * 1024

    static func validDevice(_ value: String) -> Bool {
        (try? HoshiCore.call("conflicts.settings-device", payload: ["id": value]) as? Bool) == true
    }

    static func validate(_ records: [String: ReaderPreferenceRecord], now: Date = Date()) throws {
        if records.isEmpty { return }
        guard records.count <= 256 else { throw HttpSyncError("Too many reader preferences.") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let fields = try records.map { name, record -> [String: Any] in
            let encoded = try encoder.encode(record.value)
            return [
                "name": name, "editedAt": record.editedAt, "deviceId": record.deviceId,
                "encodedLength": String(decoding: encoded, as: UTF8.self).utf16.count,
                "value": validationValue(record.value, name: name),
            ]
        }
        let nowMillis = Int64(clamping: now.timeIntervalSince1970 * 1000)
        let status = try HoshiCore.call("conflicts.settings-records", payload: [
            "records": fields, "now": nowMillis, "sasayaki": true,
        ]) as? String
        guard status == "valid" else { throw HttpSyncError("Invalid reader preference record.") }
    }

    static func validValue(_ value: ReaderPreferenceValue, name: String) -> Bool {
        (try? HoshiCore.call("conflicts.settings-value", payload: [
            "name": name, "value": validationValue(value, name: name), "sasayaki": true,
        ]) as? Bool) == true
    }

    static func winningFields(_ candidates: [String: ReaderPreferenceRecord],
                              current: [String: ReaderPreferenceRecord]) throws -> [String] {
        if candidates.isEmpty { return [] }
        let response = try HoshiCore.call("conflicts.settings-winners", payload: [
            "candidates": candidates.map { name, record in
                ["name": name, "editedAt": record.editedAt, "deviceId": record.deviceId] as [String: Any]
            },
            "current": current.filter { candidates[$0.key] != nil }.mapValues { record in
                ["editedAt": record.editedAt, "deviceId": record.deviceId] as [String: Any]
            },
        ])
        guard let names = response as? [String] else { throw HttpSyncError("Invalid reader preference merge.") }
        return names
    }

    static func nextTimestamp(now: Date, previous: Int64) -> Int64? {
        try? HoshiCore.call("conflicts.settings-next-clock", payload: [
            "now": Int64(clamping: now.timeIntervalSince1970 * 1000), "previous": previous,
        ]) as? Int64
    }

    private static func validationValue(_ value: ReaderPreferenceValue, name: String) -> Any {
        if (name == "mangaTextEnlargement.ios" || name == "mangaTextEnlargement.android"),
           case .object(let fields) = value {
            return fields.filter { ["enabled", "amount", "threshold"].contains($0.key) }.mapValues(validationPrimitive)
        }
        return validationPrimitive(value)
    }

    private static func validationPrimitive(_ value: ReaderPreferenceValue) -> Any {
        switch value {
        case .bool(let value): return value
        case .number(let value): return value.isFinite ? value as Any : [Int]()
        case .string(let value): return value
        case .null: return NSNull()
        case .array, .object: return [Int]()
        }
    }
}

private extension Int64 {
    nonisolated init(clamping value: Double) {
        if value.isNaN { self = 0 }
        else if value >= Double(Int64.max) { self = .max }
        else if value <= Double(Int64.min) { self = .min }
        else { self = Int64(value) }
    }
}
