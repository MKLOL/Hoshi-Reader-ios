import Foundation
import OSLog

nonisolated enum StatisticsMerge {
    private static let log = Logger(subsystem: "com.dragosristache.hoshireader", category: "StatisticsMerge")

    static func reading(_ source: [Statistics], legacyOrder: Bool = false) -> [Statistics] {
        let rows = source.filter { $0.readingTime.isFinite && $0.readingTime >= 0 && $0.charactersRead >= 0 }
        return mergeReading(rows, recordText: legacyOrder ? { _, row in row.tieBreak } : nil)
    }

    static func legacyReading(
        _ local: [Statistics], _ received: [Statistics],
        localDocument: () -> Data?, receivedDocument: Data?
    ) -> [Statistics] {
        let combined = local + received
        let localRows = Dictionary(local.map { (readingKey($0), $0) }, uniquingKeysWith: { first, _ in first })
        let differentHoursAtSameStamp = received.contains { row in
            localRows[readingKey(row)].map {
                $0.lastStatisticModified == row.lastStatisticModified && $0.readingTimeByHour != row.readingTimeByHour
            } ?? false
        }
        guard differentHoursAtSameStamp else { return reading(combined, legacyOrder: true) }

        let ownedOrder = legacyHourOrder(in: localDocument())
        let receivedOrder = legacyHourOrder(in: receivedDocument)
        func recordText(_ row: Statistics, order: [String: LegacyHours]) -> String {
            let matched = order[readingKey(row)].flatMap { $0.order(for: row) }
            return row.legacyRecordText(hourOrder: matched)
        }
        return mergeReading(combined) { index, row in
            recordText(row, order: index < local.count ? ownedOrder : receivedOrder)
        }
    }

    private static func mergeReading(
        _ rows: [Statistics], recordText: ((Int, Statistics) -> String)?
    ) -> [Statistics] {
        let batch = split(rows, key: readingKey, legacy: recordText != nil, needsCore: { $0.importedBaseline != nil })
        guard !batch.indices.isEmpty else { return batch.unchanged.sorted { $0.key < $1.key } }
        let resolved = resolvedReading(
            batch.indices.map { rows[$0] },
            recordText: recordText.map { format in batch.indices.map { format($0, rows[$0]) } }
        )
        return (batch.unchanged + resolved).sorted { $0.key < $1.key }
    }

    static func importedResidual(_ row: Statistics) -> Statistics {
        guard row.importedBaseline != nil else { return row }
        return resolvedReading([row], recordText: nil).first ?? row
    }

    static func mangaText<T: Encodable & Equatable>(
        _ rows: [T], key: (T) -> String, legacyOrder: ((T) -> String)? = nil
    ) -> [T] {
        let batch = split(rows, key: key, legacy: legacyOrder != nil, needsCore: { _ in false })
        guard !batch.indices.isEmpty else { return batch.unchanged }
        let candidates = batch.indices.map { rows[$0] }
        do {
            let value = try merge("manga-text", rows: candidates, legacyOrder: legacyOrder.map { candidates.map($0) })
            guard let indexes = value as? [Int] else { throw invalidResponse }
            return batch.unchanged + indexes.map { candidates[$0] }
        } catch {
            log.error("Manga text merge failed: \(error.localizedDescription, privacy: .public)")
            return rows
        }
    }

    private static var invalidResponse: HoshiCore.Failure {
        HoshiCore.Failure(reason: "Invalid shared statistics merge response")
    }

    private static func resolvedReading(_ rows: [Statistics], recordText: [String]?) -> [Statistics] {
        do {
            let value = try merge("reading", rows: rows, legacyOrder: recordText)
            guard let encoded = value as? String else { throw invalidResponse }
            let decoder = JSONDecoder()
            decoder.nonConformingFloatDecodingStrategy = .convertFromString(
                positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
            )
            return try decoder.decode([Patch].self, from: Data(encoded.utf8)).map { patch in
                var row = rows[patch.index]
                if let residual = patch.residual {
                    row.readingTime = residual.readingTime
                    row.charactersRead = residual.charactersRead
                    row.lastReadingSpeed = residual.lastReadingSpeed
                    row.readingTimeByHour = residual.readingTimeByHour
                    row.timeZone = residual.timeZone
                    row.readingTimeByZone = [:]
                }
                if let baseline = patch.importedBaseline { row.importedBaseline = baseline }
                if let stamp = patch.lastStatisticModified { row.lastStatisticModified = stamp }
                if let histogram = patch.mangaPageSeconds {
                    row.mangaPageSeconds = Dictionary(uniqueKeysWithValues: histogram.compactMap { key, count in
                        Int(key).map { ($0, count) }
                    })
                }
                return row
            }
        } catch {
            log.error("Reading history merge failed: \(error.localizedDescription, privacy: .public)")
            return rows
        }
    }

    private static func merge<T: Encodable>(_ kind: String, rows: [T], legacyOrder: [String]?) throws -> Any {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
        )
        var payload: [String: Any] = ["rows": String(decoding: try encoder.encode(rows), as: UTF8.self)]
        if let legacyOrder { payload["recordText"] = legacyOrder }
        return try HoshiCore.call("statistics-merge.\(kind)", payload: payload)
    }

    private static func legacyHourOrder(in data: Data?) -> [String: LegacyHours] {
        guard let data, let document = String(data: data, encoding: .utf8) else { return [:] }
        do {
            let result = try HoshiCore.call("statistics-merge.legacy-hour-order", payload: ["document": document])
            let encoded = try JSONSerialization.data(withJSONObject: result)
            let rows = try JSONDecoder().decode([LegacyHours].self, from: encoded)
            return Dictionary(rows.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        } catch {
            log.error("Legacy hourly order unavailable: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }

    private struct LegacyHours: Decodable {
        let key: String
        let stamp: Int
        let hours: [Hour]

        func order(for row: Statistics) -> [String]? {
            guard stamp == row.lastStatisticModified, hours.count == row.readingTimeByHour.count,
                  hours.allSatisfy({ row.readingTimeByHour[$0.key] == $0.seconds }) else { return nil }
            let order = hours.map(\.key)
            return Set(order).count == order.count ? order : nil
        }
    }

    private struct Hour: Decodable {
        let key: String
        let seconds: Double

        init(from decoder: Decoder) throws {
            var pair = try decoder.unkeyedContainer()
            key = try pair.decode(String.self)
            seconds = try pair.decode(Double.self)
        }
    }

    private static func readingKey(_ row: Statistics) -> String { row.dateKey + "\u{0}" + (row.deviceId ?? "") }

    // A page save includes history it just loaded. Keep a single copy of identical rows
    // locally and send every candidate for a conflicting day/device to the shared merge.
    // Legacy candidates use record text, which can distinguish otherwise equal Swift values.
    private static func split<T: Equatable>(
        _ rows: [T], key: (T) -> String, legacy: Bool, needsCore: (T) -> Bool
    ) -> (unchanged: [T], indices: [Int]) {
        let keys = rows.map(key)
        var first = [String: Int](minimumCapacity: rows.count)
        var conflicts = Set<String>()
        for (index, id) in keys.enumerated() {
            if let earlier = first[id] {
                if legacy || rows[earlier] != rows[index] || !keys[earlier].utf8.elementsEqual(id.utf8) {
                    conflicts.insert(id)
                }
            } else {
                first[id] = index
            }
            if needsCore(rows[index]) { conflicts.insert(id) }
        }
        if conflicts.isEmpty && first.count == rows.count { return (rows, []) }

        var unchanged: [T] = []
        unchanged.reserveCapacity(first.count - conflicts.count)
        var indices: [Int] = []
        for (index, id) in keys.enumerated() {
            if conflicts.contains(id) {
                indices.append(index)
            } else if first[id] == index {
                unchanged.append(rows[index])
            }
        }
        return (unchanged, indices)
    }

    private struct Patch: Decodable {
        let index: Int
        let residual: Residual?
        let importedBaseline: ImportedReadingBaseline?
        let lastStatisticModified: Int?
        let mangaPageSeconds: [String: Int]?
    }

    private struct Residual: Decodable {
        let readingTime: Double
        let charactersRead: Int
        let lastReadingSpeed: Int
        let readingTimeByHour: [String: Double]
        let timeZone: String?
    }
}
