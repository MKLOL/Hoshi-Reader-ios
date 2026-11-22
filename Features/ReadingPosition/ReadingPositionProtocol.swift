import Foundation

/// Android-compatible position coordinates. Times in this protocol use the Apple reference
/// epoch, like the released bookmark sidecar, rather than Unix seconds.
nonisolated struct ReadingPosition: Codable, Equatable, Sendable {
    var chapterIndex: Int
    var progress: Double
    var characterCount: Int
    var isValid: Bool { chapterIndex >= 0 && progress.isFinite && (0...1).contains(progress) && characterCount >= 0 }
    func samePlace(as other: Self) -> Bool { chapterIndex == other.chapterIndex && abs(progress - other.progress) < 0.00000001 }
}

nonisolated struct ReadingPositionEvent: Codable, Equatable, Sendable {
    var id: String
    var deviceId: String
    var deviceName: String
    var originId: String
    var sequence: Int64
    var sessionId: String
    var action: String
    var from: ReadingPosition?
    var position: ReadingPosition
    var occurredAt: Double
    var compatibilityAt: Double
    var basedOn: String?
    var seen: [String: Int64]
    var missingTimestamp: Bool
    var bookId: String

    var isValid: Bool {
        !id.isEmpty && id.count <= 128 && !deviceId.isEmpty && !originId.isEmpty && originId.count <= 128 && sequence > 0 &&
        position.isValid && (from?.isValid ?? true) && occurredAt.isFinite && compatibilityAt.isFinite &&
        abs(occurredAt) <= 1e12 && compatibilityAt <= 1e12 && compatibilityAt >= occurredAt && seen.count <= 256 &&
        seen.allSatisfy { !$0.key.isEmpty && $0.key.count <= 128 && $0.value >= 0 }
    }
    static func ordered(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.compatibilityAt != rhs.compatibilityAt { return lhs.compatibilityAt < rhs.compatibilityAt }
        if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
        return lhs.id.utf16.lexicographicallyPrecedes(rhs.id.utf16)
    }

    fileprivate func headSummary(key: String, includeSeen: Bool = true) -> [String: Any] {
        var summary: [String: Any] = [
            "key": key, "id": id, "originId": originId, "sequence": sequence,
            "compatibilityAt": compatibilityAt, "occurredAt": occurredAt,
        ]
        if includeSeen {
            summary["seen"] = seen.map { entry -> [String: Any] in ["origin": entry.key, "sequence": entry.value] }
        }
        return summary
    }

    fileprivate func historySummary(includeOrigin: Bool = false) -> [String: Any] {
        var summary: [String: Any] = ["id": id, "deviceId": deviceId, "compatibilityAt": compatibilityAt]
        if includeOrigin {
            summary["originId"] = originId
            summary["sequence"] = sequence
        }
        return summary
    }
}

nonisolated struct ReadingPositionJournal: Codable, Sendable {
    var version = 1
    var bookId: String
    var deviceId: String
    var events: [ReadingPositionEvent]
    var heads: [ReadingPositionEvent]
}

nonisolated struct ReadingPositionState: Codable, Equatable, Sendable {
    var bookId: String
    var heads: [String: ReadingPositionEvent] = [:]
    var events: [ReadingPositionEvent] = []
    var pending: Set<String> = []

    var frontier: [String: Int64] {
        guard let entries = graph(heads.map { $0 })?["frontier"] as? [[String: Any]] else { return [:] }
        var frontier: [String: Int64] = [:]
        for entry in entries {
            if let origin = entry["origin"] as? String, let sequence = entry["sequence"] as? Int64 {
                frontier[origin] = sequence
            }
        }
        return frontier
    }

    var winner: ReadingPositionEvent? {
        if heads.count <= 1 { return heads.values.first }
        let orderedHeads = heads.map { $0 }
        guard let index = graph(orderedHeads, winnerOnly: true)?["winner"] as? Int, orderedHeads.indices.contains(index) else { return nil }
        return orderedHeads[index].value
    }

    private func graph(_ orderedHeads: [(key: String, value: ReadingPositionEvent)],
                       winnerOnly: Bool = false) -> [String: Any]? {
        try? HoshiCore.call("conflicts.position-graph", payload: [
            "heads": orderedHeads.map { $0.value.headSummary(key: $0.key) },
            "winnerOnly": winnerOnly,
        ]) as? [String: Any]
    }

    func merging(_ incoming: [ReadingPositionEvent], ownPending: Set<String> = []) throws -> Self {
        guard incoming.allSatisfy(\.isValid) else { throw ReadingPositionProtocolError.invalidEvent }
        let all = events + incoming
        let reply = try HoshiCore.call("conflicts.position-merge", payload: [
            "heads": heads.map { $0.value.headSummary(key: $0.key, includeSeen: false) },
            "history": events.map { $0.historySummary() },
            "incoming": incoming.map { $0.historySummary(includeOrigin: true) },
            "pending": Array(pending.union(ownPending)),
        ]) as? [String: Any]
        guard let headIndices = reply?["updatedHeads"] as? [Int],
              let retained = reply?["events"] as? [Int],
              let pending = reply?["pending"] as? [String],
              headIndices.allSatisfy(incoming.indices.contains),
              retained.allSatisfy(all.indices.contains) else { throw ReadingPositionProtocolError.invalidJournal }
        var result = self
        for index in headIndices {
            let event = incoming[index]
            result.heads[event.originId] = event
        }
        result.events = retained.map { all[$0] }
        result.pending = Set(pending)
        return result
    }
}

nonisolated enum ReadingPositionProtocolError: Error { case invalidEvent, invalidJournal }

nonisolated enum ReadingPositionProtocol {
    static let prefix = "sync/maps/positions/v1/"
    /// The wire permits 256 origins per event. Reserve the local origin and the displayed
    /// winner, then retain the most recent known heads with a stable origin tie-break.
    static func boundedFrontier(_ source: [String: Int64], ownOrigin: String, winnerOrigin: String?,
                                heads: [String: ReadingPositionEvent]) -> [String: Int64] {
        guard source.count >= 256 else { return source }
        let bounded = try? HoshiCore.call("conflicts.bounded-frontier", payload: [
            "frontier": source, "ownOrigin": ownOrigin, "winnerOrigin": winnerOrigin as Any? ?? NSNull(),
            "heads": heads.map { $0.value.headSummary(key: $0.key, includeSeen: false) },
        ]) as? [String: Int64]
        return bounded ?? source
    }
    static func wireMillis(_ seconds: Double) -> Int64 { Int64(((seconds + 978_307_200) * 1000).rounded(.towardZero)) }
    static func nextTimestamp(action: Double, previous: Double) -> Double {
        let previousMillis = wireMillis(previous)
        var next = max(action, Double(previousMillis + 1) / 1000 - 978_307_200)
        while wireMillis(next) <= previousMillis { next = next.nextUp }
        return next
    }
    static func parseKey(_ key: String) -> (book: String, device: String)? {
        guard key.hasPrefix(prefix) else { return nil }
        let parts = key.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1].hasSuffix(".json") else { return nil }
        let book = String(parts[0]), device = String(parts[1].dropLast(5))
        guard validID(book), validID(device) else { return nil }
        return (book, device)
    }
    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 45 || byte == 95
        }
    }
}
