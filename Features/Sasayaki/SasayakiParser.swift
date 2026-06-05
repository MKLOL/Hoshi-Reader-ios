//
//  SasayakiParser.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

struct SasayakiParser {
    static func parseCues(from data: Data) -> [SasayakiCue] {
        /*
         1
         00:00:19,124 --> 00:00:22,016
         ＊シックスイヤーザー号、
         
         2
         00:00:24,148 --> 00:00:28,468
         渚　それはある日の、あたし達にとっては日常の光景だった。
         */
        String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .enumerated()
            .compactMap { index, block in
                let lines = block.components(separatedBy: "\n")
                guard lines.count >= 3, lines[1].contains("-->") else {
                    return nil
                }
                
                let times = lines[1].components(separatedBy: "-->")
                // A malformed/non-standard subtitle (bad or missing timestamps) must be skipped,
                // not crash the import. parseTimestamp returns nil on anything unparseable.
                guard times.count >= 2,
                      let startTime = parseTimestamp(times[0]),
                      let endTime = parseTimestamp(times[1]) else {
                    return nil
                }
                let text = lines[2].trimmingCharacters(in: .whitespaces)
                return SasayakiCue(
                    id: String(index),
                    startTime: startTime,
                    endTime: endTime,
                    text: text
                )
            }
    }
    
    private static func parseTimestamp(_ timestamp: String) -> Double? {
        let parts = timestamp
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
            .components(separatedBy: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2]) else {
            return nil
        }
        return hours * 3600 + minutes * 60 + seconds
    }
}
