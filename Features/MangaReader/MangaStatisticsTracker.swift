//
//  MangaStatisticsTracker.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Tracks manga reading time + pages while the reader is open, mirroring Android's
//  `features/reader/ReaderStatisticsTracker.kt`. "Characters" in the shared `Statistics` model
//  are interpreted as pages for manga: each page turn advances the page counter by one. The
//  tracker keeps session / today / all-time aggregates and persists today's bucket to a manga
//  sidecar JSON in the book directory (`FileNames.mangaStatistics`), kept separate from the
//  character-based EPUB `statistics.json` so the two never collide.
//

import Foundation

/// A pure, `nonisolated` value type that accumulates manga reading statistics. Pages drive the
/// "charactersRead" field of the shared `Statistics` model.
nonisolated struct MangaStatisticsTracker {
    let title: String
    let enabled: Bool

    private(set) var allStats: [Statistics]
    private(set) var isTracking = false
    private(set) var session: Statistics
    private(set) var today: Statistics
    private(set) var allTime: Statistics

    private var lastTimestamp: Date
    private var lastPageCount = 0
    private var hasUpdated = false

    init(title: String, initialStatistics: [Statistics], enabled: Bool, now: Date = .now) {
        self.title = title
        self.enabled = enabled
        self.allStats = Self.deduplicate(initialStatistics)
        self.lastTimestamp = now
        let dateKey = Self.dateKey(for: now)
        self.session = Self.defaultStatistic(title: title, dateKey: dateKey)
        self.today = allStats.first(where: { $0.dateKey == dateKey })
            ?? Self.defaultStatistic(title: title, dateKey: dateKey)
        self.allTime = Self.allTimeStatistic(title: title, dateKey: dateKey, stats: allStats)
    }

    mutating func start(currentPage: Int, now: Date = .now) {
        guard enabled else { return }
        isTracking = true
        resetBaseline(currentPage: currentPage, now: now)
    }

    mutating func startForPageTurnIfNeeded(currentPage: Int, now: Date = .now) {
        if !isTracking { start(currentPage: currentPage, now: now) }
    }

    /// Pauses tracking, flushing any accumulated time/pages. Returns true if it was tracking.
    @discardableResult
    mutating func pause(currentPage: Int, now: Date = .now) -> Bool {
        guard isTracking else { return false }
        update(currentPage: currentPage, now: now)
        isTracking = false
        return true
    }

    mutating func update(currentPage: Int, now: Date = .now) {
        guard enabled, isTracking else { return }
        rollTodayIfNeeded(now: now)
        let timeDiff = now.timeIntervalSince(lastTimestamp)
        if timeDiff <= 0 { return }

        let pageDiff = currentPage - lastPageCount
        let finalPageDiff = (pageDiff < 0 && abs(pageDiff) > session.charactersRead)
            ? -session.charactersRead
            : pageDiff
        let modified = Int(now.timeIntervalSince1970 * 1000)
        Self.apply(to: &session, timeDiff: timeDiff, pageDiff: finalPageDiff, modified: modified)
        Self.apply(to: &today, timeDiff: timeDiff, pageDiff: finalPageDiff, modified: modified)
        Self.apply(to: &allTime, timeDiff: timeDiff, pageDiff: finalPageDiff, modified: modified)
        hasUpdated = true
        lastTimestamp = now
        lastPageCount = currentPage
    }

    mutating func resetBaseline(currentPage: Int, now: Date = .now) {
        lastPageCount = currentPage
        lastTimestamp = now
    }

    /// The full list of per-day statistics to persist, with today's bucket folded in. Returns
    /// `nil` when there is nothing worth persisting (disabled, or never touched + empty history).
    mutating func statisticsForPersistence() -> [Statistics]? {
        guard enabled, hasUpdated || !allStats.isEmpty else { return nil }
        var next = allStats
        if let index = next.firstIndex(where: { $0.dateKey == today.dateKey }) {
            next[index] = today
        } else {
            next.append(today)
        }
        allStats = Self.deduplicate(next)
        return allStats
    }

    private mutating func rollTodayIfNeeded(now: Date) {
        let currentKey = Self.dateKey(for: now)
        if today.dateKey == currentKey { return }
        // Fold the finished day into the persisted list, then start a fresh today bucket.
        _ = statisticsForPersistence()
        today = allStats.first(where: { $0.dateKey == currentKey })
            ?? Self.defaultStatistic(title: title, dateKey: currentKey)
    }

    // MARK: Static helpers

    private static func apply(to stat: inout Statistics, timeDiff: Double, pageDiff: Int, modified: Int) {
        stat.readingTime += timeDiff
        stat.charactersRead = max(stat.charactersRead + pageDiff, 0)
        stat.lastReadingSpeed = stat.readingTime > 0
            ? Int((Double(stat.charactersRead) / stat.readingTime) * 3600.0)
            : 0
        stat.maxReadingSpeed = max(stat.maxReadingSpeed, stat.lastReadingSpeed)
        stat.minReadingSpeed = stat.minReadingSpeed != 0
            ? min(stat.minReadingSpeed, stat.lastReadingSpeed)
            : stat.lastReadingSpeed
        if pageDiff != 0 {
            stat.altMinReadingSpeed = stat.altMinReadingSpeed != 0
                ? min(stat.altMinReadingSpeed, stat.lastReadingSpeed)
                : stat.lastReadingSpeed
        }
        stat.lastStatisticModified = modified
    }

    private static func defaultStatistic(title: String, dateKey: String) -> Statistics {
        Statistics(
            title: title, dateKey: dateKey, charactersRead: 0, readingTime: 0,
            minReadingSpeed: 0, altMinReadingSpeed: 0, lastReadingSpeed: 0,
            maxReadingSpeed: 0, lastStatisticModified: 0
        )
    }

    private static func allTimeStatistic(title: String, dateKey: String, stats: [Statistics]) -> Statistics {
        var total = defaultStatistic(title: title, dateKey: dateKey)
        for stat in stats {
            total.readingTime += stat.readingTime
            total.charactersRead += stat.charactersRead
        }
        total.lastReadingSpeed = total.readingTime > 0
            ? Int((Double(total.charactersRead) / total.readingTime) * 3600.0)
            : 0
        return total
    }

    static func deduplicate(_ statistics: [Statistics]) -> [Statistics] {
        var grouped: [String: Statistics] = [:]
        for statistic in statistics {
            if let existing = grouped[statistic.dateKey] {
                if statistic.lastStatisticModified > existing.lastStatisticModified {
                    grouped[statistic.dateKey] = statistic
                }
            } else {
                grouped[statistic.dateKey] = statistic
            }
        }
        return Array(grouped.values)
    }

    static func dateKey(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withFullDate]
        return formatter.string(from: date)
    }
}
