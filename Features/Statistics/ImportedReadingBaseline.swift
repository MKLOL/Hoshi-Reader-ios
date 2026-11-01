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

    func withImportedResidual() -> Self {
        guard let baseline = importedBaseline else { return self }
        var row = self
        let included = baseline.includedDevices.values
        row.readingTime = max(0, baseline.readingTime - included.reduce(0) { StatisticsNumbers.adding($0, $1.readingTime) })
        row.charactersRead = max(0, baseline.charactersRead - included.reduce(0) { StatisticsNumbers.adding($0, $1.charactersRead) })
        row.lastReadingSpeed = StatisticsNumbers.speed(count: row.charactersRead, seconds: row.readingTime)
        var hours: [String: Double] = [:]
        if !baseline.readingTimeByHour.isEmpty, included.allSatisfy({
            abs($0.readingTime - $0.readingTimeByHour.values.reduce(0, +)) < 0.001 &&
            ($0.timeZone == nil || baseline.timeZone == nil || $0.timeZone == baseline.timeZone)
        }) {
            let includedHours = ReadingDay.sumHours(included.map(\.readingTimeByHour))
            hours = baseline.readingTimeByHour.mapValues { $0 }
            for key in hours.keys { hours[key] = max(0, hours[key]! - (includedHours[key] ?? 0)) }
            hours = hours.filter { $0.value > 0 }
            if hours.values.reduce(0, +) > row.readingTime + 0.001 { hours = [:] }
        }
        row.readingTimeByHour = hours
        row.timeZone = hours.isEmpty ? nil : baseline.timeZone
        return row
    }

    func mergingImportedBaseline(_ other: Self) -> Self? {
        guard var left = importedBaseline, var right = other.importedBaseline else { return nil }
        let a = left.includedDevices, b = right.includedDevices
        left.includedDevices = [:]; right.includedDevices = [:]
        guard left.charactersRead == right.charactersRead, left.readingTime == right.readingTime,
              left.sourceModified == right.sourceModified else { return nil }
        if left != right {
            let a = left.readingTimeByHour.values.reduce(0, +), b = right.readingTimeByHour.values.reduce(0, +)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let leftBytes = (try? encoder.encode(left)) ?? Data(), rightBytes = (try? encoder.encode(right)) ?? Data()
            if b > a || (b == a && left.timeZone == nil && right.timeZone != nil) ||
                (b == a && (left.timeZone == nil) == (right.timeZone == nil) && leftBytes.lexicographicallyPrecedes(rightBytes)) {
                left = right
            }
        }
        var included = a
        for (device, candidate) in b {
            if let old = included[device] {
                if old.lastStatisticModified > candidate.lastStatisticModified { continue }
                if old.lastStatisticModified == candidate.lastStatisticModified {
                    if old.readingTime > candidate.readingTime { continue }
                    if old.readingTime == candidate.readingTime {
                        if old.charactersRead > candidate.charactersRead { continue }
                        if old.charactersRead == candidate.charactersRead {
                            let oldHours = old.readingTimeByHour.values.reduce(0, +)
                            let newHours = candidate.readingTimeByHour.values.reduce(0, +)
                            if oldHours > newHours { continue }
                            if oldHours == newHours {
                                if old.readingTimeByHour == candidate.readingTimeByHour, old.timeZone != nil, candidate.timeZone == nil { continue }
                                if old.readingTimeByHour == candidate.readingTimeByHour, old.timeZone == nil, candidate.timeZone != nil {
                                    included[device] = candidate
                                    continue
                                }
                                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                                let a = (try? encoder.encode(old)) ?? Data()
                                let b = (try? encoder.encode(candidate)) ?? Data()
                                if !a.lexicographicallyPrecedes(b) { continue }
                            }
                        }
                    }
                }
            }
            included[device] = candidate
        }
        left.includedDevices = included
        var merged = self
        merged.importedBaseline = left
        merged.lastStatisticModified = max(lastStatisticModified, other.lastStatisticModified)
        return merged.withImportedResidual()
    }
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
