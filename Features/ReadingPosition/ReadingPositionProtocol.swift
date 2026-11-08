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
    func observes(_ other: Self) -> Bool {
        (originId == other.originId && sequence > other.sequence) || (seen[other.originId] ?? 0) >= other.sequence
    }
    static func ordered(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.compatibilityAt != rhs.compatibilityAt { return lhs.compatibilityAt < rhs.compatibilityAt }
        if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
        return lhs.id < rhs.id
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
        var result: [String: Int64] = [:]
        for head in heads.values {
            for (origin, number) in head.seen where !origin.hasPrefix("legacy-") || heads[origin] != nil {
                result[origin] = max(result[origin] ?? 0, number)
            }
            result[head.originId] = max(result[head.originId] ?? 0, head.sequence)
        }
        return result
    }
    var winner: ReadingPositionEvent? {
        // Small histories need only a few dictionary lookups. Large, well-formed histories
        // index which origin sequences other heads observed instead of comparing every pair.
        guard heads.count > 8, heads.allSatisfy({ $0.key == $0.value.originId }),
              Set(heads.values.map(\.id)).count == heads.count else {
            return heads.values.filter { candidate in
                !heads.values.contains { $0.id != candidate.id && $0.observes(candidate) }
            }.max(by: ReadingPositionEvent.ordered)
        }
        var observed: [String: Int64] = [:]
        for head in heads.values {
            // A head's own frontier must not make it observe itself.
            for (origin, sequence) in head.seen where origin != head.originId {
                observed[origin] = max(observed[origin] ?? 0, sequence)
            }
        }
        return heads.values.filter { (observed[$0.originId] ?? 0) < $0.sequence }
            .max(by: ReadingPositionEvent.ordered)
    }
    func merging(_ incoming: [ReadingPositionEvent], ownPending: Set<String> = []) throws -> Self {
        guard incoming.allSatisfy(\.isValid) else { throw ReadingPositionProtocolError.invalidEvent }
        var result = self
        for event in incoming {
            if let old = result.heads[event.originId],
               old.sequence > event.sequence || (old.sequence == event.sequence && old.id >= event.id) { continue }
            result.heads[event.originId] = event
        }
        var byId = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for event in incoming { byId[event.id] = event }
        func historyOrder(_ lhs: ReadingPositionEvent, _ rhs: ReadingPositionEvent) -> Bool {
            lhs.compatibilityAt == rhs.compatibilityAt ? lhs.id < rhs.id : lhs.compatibilityAt < rhs.compatibilityAt
        }
        let devices = Dictionary(grouping: Array(byId.values), by: { $0.deviceId })
        var retainedEvents: [ReadingPositionEvent] = []
        for events in devices.values { retainedEvents.append(contentsOf: events.sorted(by: historyOrder).suffix(50)) }
        result.events = retainedEvents.sorted(by: historyOrder)
        let retained = Set(result.events.map(\.id) + result.heads.values.map(\.id))
        result.pending = pending.union(ownPending).intersection(retained)
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
        // Preserve existing wire values when the next own-origin update already has space.
        if source.count < 256 { return source }
        var frontier = source
        frontier[ownOrigin] = frontier[ownOrigin] ?? 0
        guard frontier.count > 256 else { return frontier }
        let origins = frontier.keys.sorted { lhs, rhs in
            if lhs == rhs { return false }
            if lhs == ownOrigin || rhs == ownOrigin { return lhs == ownOrigin }
            if lhs == winnerOrigin || rhs == winnerOrigin { return lhs == winnerOrigin }
            switch (heads[lhs], heads[rhs]) {
            case let (left?, right?):
                if ReadingPositionEvent.ordered(left, right) { return false }
                if ReadingPositionEvent.ordered(right, left) { return true }
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): break
            }
            return lhs < rhs
        }
        return Dictionary(uniqueKeysWithValues: origins.prefix(256).map { ($0, frontier[$0]!) })
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
