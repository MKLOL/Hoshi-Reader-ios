import Foundation

/// A collapsed ッツ day is shared history, rather than new reading by every importing device.
nonisolated struct ImportedReadingCheckpoint: Codable, Equatable, Sendable {
    var charactersRead: Int
    var readingTime: Double
    var lastStatisticModified: Int
    var readingTimeByHour: [String: Double] = [:]
    var timeZone: String? = nil
}

nonisolated struct ImportedReadingBaseline: Codable, Equatable, Sendable {
    var charactersRead: Int
    var readingTime: Double
    var sourceModified: Int
    var readingTimeByHour: [String: Double] = [:]
    var timeZone: String? = nil
    var includedDevices: [String: ImportedReadingCheckpoint] = [:]
}

nonisolated extension ImportedReadingCheckpoint {
    private enum CodingKeys: String, CodingKey { case charactersRead, readingTime, lastStatisticModified, readingTimeByHour, timeZone }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        charactersRead = try c.decode(Int.self, forKey: .charactersRead)
        readingTime = try c.decode(Double.self, forKey: .readingTime)
        lastStatisticModified = try c.decode(Int.self, forKey: .lastStatisticModified)
        readingTimeByHour = try c.decodeIfPresent([String: Double].self, forKey: .readingTimeByHour) ?? [:]
        timeZone = try c.decodeIfPresent(String.self, forKey: .timeZone)
        guard charactersRead >= 0, readingTime.isFinite, readingTime >= 0,
              (0...253_402_300_799_999).contains(lastStatisticModified),
              readingTimeByHour.values.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw DecodingError.dataCorruptedError(forKey: .readingTime, in: c, debugDescription: "Invalid imported reading checkpoint")
        }
    }
}

nonisolated extension ImportedReadingBaseline {
    private enum CodingKeys: String, CodingKey { case charactersRead, readingTime, sourceModified, readingTimeByHour, timeZone, includedDevices }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        charactersRead = try c.decode(Int.self, forKey: .charactersRead)
        readingTime = try c.decode(Double.self, forKey: .readingTime)
        sourceModified = try c.decode(Int.self, forKey: .sourceModified)
        readingTimeByHour = try c.decodeIfPresent([String: Double].self, forKey: .readingTimeByHour) ?? [:]
        timeZone = try c.decodeIfPresent(String.self, forKey: .timeZone)
        includedDevices = try c.decodeIfPresent([String: ImportedReadingCheckpoint].self, forKey: .includedDevices) ?? [:]
        guard charactersRead >= 0, readingTime.isFinite, readingTime >= 0,
              (0...253_402_300_799_999).contains(sourceModified),
              readingTimeByHour.values.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw DecodingError.dataCorruptedError(forKey: .readingTime, in: c, debugDescription: "Invalid imported reading baseline")
        }
    }
}

nonisolated extension Statistics {
    static let ttuDeviceId = "hoshi:ttu"

    func withImportedResidual() -> Self { StatisticsMerge.importedResidual(self) }
}

nonisolated enum ImportedReadingTotals {
    static func applying(_ totals: [Statistics], to original: [Statistics], replace: Bool) -> [Statistics] {
        var next = Statistics.merged(original)
        let collapsed = Dictionary(grouping: Statistics.merged(totals), by: \.dateKey).map { day, entries in
            Statistics.total(entries, title: entries.first?.title ?? "", day: day)
        }
        for total in collapsed {
            let sameDay = next.filter { $0.dateKey == total.dateKey }
            let previous = sameDay.first { $0.deviceId == Statistics.ttuDeviceId }
            let current = Statistics.total(sameDay)
            let sameTotal = current.readingTime == total.readingTime && current.charactersRead == total.charactersRead
            let included = Dictionary(uniqueKeysWithValues: sameDay.filter { $0.deviceId != Statistics.ttuDeviceId }.map {
                ($0.deviceId ?? "", ImportedReadingCheckpoint(charactersRead: $0.charactersRead, readingTime: $0.readingTime,
                    lastStatisticModified: $0.lastStatisticModified, readingTimeByHour: $0.readingTimeByHour, timeZone: $0.timeZone))
            })
            let prior = previous?.importedBaseline
            let hours = !total.readingTimeByHour.isEmpty ? total.readingTimeByHour : (prior?.readingTime == total.readingTime ? prior?.readingTimeByHour ?? [:] : [:])
            let baseline = ImportedReadingBaseline(charactersRead: total.charactersRead, readingTime: total.readingTime,
                sourceModified: total.lastStatisticModified, readingTimeByHour: hours,
                timeZone: total.timeZone ?? prior?.timeZone, includedDevices: included)
            if baseline == prior { continue }
            var row = total
            row.deviceId = Statistics.ttuDeviceId; row.deviceName = nil
            row.lastStatisticModified = sameTotal ? max(total.lastStatisticModified, previous?.lastStatisticModified ?? 0)
                : max(total.lastStatisticModified, StatisticsNumbers.nextStamp(previous?.lastStatisticModified ?? -1))
            row.importedBaseline = baseline
            next.removeAll { $0.key == row.key }; next.append(row.withImportedResidual())
        }
        if replace {
            let keep = Set(totals.map(\.dateKey))
            for index in next.indices where next[index].deviceId == Statistics.ttuDeviceId && !keep.contains(next[index].dateKey) {
                let cleared = ImportedReadingBaseline(charactersRead: 0, readingTime: 0, sourceModified: 0)
                guard next[index].importedBaseline != cleared else { continue }
                next[index].importedBaseline = cleared
                next[index].lastStatisticModified = StatisticsNumbers.nextStamp(next[index].lastStatisticModified)
                next[index].minReadingSpeed = 0; next[index].altMinReadingSpeed = 0; next[index].maxReadingSpeed = 0
                next[index] = next[index].withImportedResidual()
            }
        }
        return Statistics.merged(next)
    }
}
