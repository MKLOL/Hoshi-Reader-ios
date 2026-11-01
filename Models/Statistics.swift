//
//  Statistics.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  Copyright © 2026 ッツ Reader Authors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

enum StatisticsAutostartMode: String, CaseIterable, Codable {
    case off = "Off"
    case pageturn = "Page Turn"
    case on = "On"
}

enum StatisticsSyncMode: String, CaseIterable, Codable {
    case merge = "Merge"
    case replace = "Replace"
}

// https://github.com/ttu-ttu/ebook-reader/blob/2703b50ec52b2e4f70afcab725c0f47dd8a66bf4/apps/web/src/lib/data/database/books-db/versions/v6/books-db-v6.ts#L68
nonisolated struct Statistics: Codable, Equatable, Sendable {
    let title: String
    let dateKey: String
    var charactersRead: Int
    var readingTime: Double
    var minReadingSpeed: Int
    var altMinReadingSpeed: Int
    var lastReadingSpeed: Int
    var maxReadingSpeed: Int
    var lastStatisticModified: Int
    var deviceId: String? = nil
    var deviceName: String? = nil
    /// Counted seconds by local ISO date/hour, shared with Android; missing hours are legacy evidence.
    var readingTimeByHour: [String: Double] = [:]
    var timeZone: String? = nil
    var importedBaseline: ImportedReadingBaseline? = nil
}

nonisolated extension Statistics {
    private enum CodingKeys: String, CodingKey {
        case title, dateKey, charactersRead, readingTime, minReadingSpeed, altMinReadingSpeed
        case lastReadingSpeed, maxReadingSpeed, lastStatisticModified, deviceId, deviceName, readingTimeByHour, timeZone, importedBaseline
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        title = try values.decode(String.self, forKey: .title)
        dateKey = try values.decode(String.self, forKey: .dateKey)
        charactersRead = try values.decodeIfPresent(Int.self, forKey: .charactersRead) ?? 0
        readingTime = try values.decodeIfPresent(Double.self, forKey: .readingTime) ?? 0
        minReadingSpeed = try values.decodeIfPresent(Int.self, forKey: .minReadingSpeed) ?? 0
        altMinReadingSpeed = try values.decodeIfPresent(Int.self, forKey: .altMinReadingSpeed) ?? 0
        lastReadingSpeed = try values.decodeIfPresent(Int.self, forKey: .lastReadingSpeed) ?? 0
        maxReadingSpeed = try values.decodeIfPresent(Int.self, forKey: .maxReadingSpeed) ?? 0
        lastStatisticModified = try values.decodeIfPresent(Int.self, forKey: .lastStatisticModified) ?? 0
        guard (0...253_402_300_799_999).contains(lastStatisticModified) else {
            throw DecodingError.dataCorruptedError(forKey: .lastStatisticModified, in: values, debugDescription: "Invalid statistics clock")
        }
        deviceId = try values.decodeIfPresent(String.self, forKey: .deviceId)
        deviceName = try values.decodeIfPresent(String.self, forKey: .deviceName)
        importedBaseline = try values.decodeIfPresent(ImportedReadingBaseline.self, forKey: .importedBaseline)
        timeZone = try values.decodeIfPresent(String.self, forKey: .timeZone)
        readingTimeByHour = try values.decodeIfPresent([String: Double].self, forKey: .readingTimeByHour) ?? [:]
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(title, forKey: .title)
        try values.encode(dateKey, forKey: .dateKey)
        try values.encode(charactersRead, forKey: .charactersRead)
        try values.encode(readingTime, forKey: .readingTime)
        try values.encode(minReadingSpeed, forKey: .minReadingSpeed)
        try values.encode(altMinReadingSpeed, forKey: .altMinReadingSpeed)
        try values.encode(lastReadingSpeed, forKey: .lastReadingSpeed)
        try values.encode(maxReadingSpeed, forKey: .maxReadingSpeed)
        try values.encode(lastStatisticModified, forKey: .lastStatisticModified)
        try values.encodeIfPresent(deviceId, forKey: .deviceId)
        try values.encodeIfPresent(deviceName, forKey: .deviceName)
        try values.encodeIfPresent(timeZone, forKey: .timeZone)
        try values.encodeIfPresent(importedBaseline, forKey: .importedBaseline)
        if !readingTimeByHour.isEmpty { try values.encode(readingTimeByHour, forKey: .readingTimeByHour) }
    }
}
