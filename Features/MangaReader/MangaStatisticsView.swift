//
//  MangaStatisticsView.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Manga reading statistics sheet, presented from the reader's overflow menu. Mirrors Android's
//  `features/mangareader/MangaStatisticsSheet.kt`: saved All Time totals and the estimated-pace
//  estimate first, then Session and Today, with a start/pause control and a progress bar.
//  "Pages" are stored in the shared `Statistics.charactersRead` field by `MangaStatisticsTracker`.
//

import SwiftUI
import Combine

struct MangaStatisticsView: View {
    @State private var now = Date.now
    @AppStorage(ReadingDay.resetKey) private var resetHour = 3
    let model: MangaReaderViewModel
    let userConfig: UserConfig
    @Environment(\.dismiss) private var dismiss

    private var statistics: MangaStatisticsTracker? { model.statistics }

    private var progress: Double {
        guard model.pageCount > 0 else { return 0 }
        return min(1, max(0, Double(model.pageIndex + 1) / Double(model.pageCount)))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Page \(min(model.pageIndex + 1, max(model.pageCount, 1))) of \(model.pageCount)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            ProgressView(value: progress)
                        }
                    }
                }

                if let statistics {
                    let allTime = statistics.allTime
                    let estimatedSeconds = Self.estimatedPageSeconds(allTime)
                    statisticsSection(
                        title: "All Time",
                        stat: allTime,
                        characters: model.allTimeCharacters,
                        pace: ("Estimated Pace", estimatedSeconds),
                        extraRows: [
                            ("Pages Remaining", remainingPages.formatted()),
                            ("Time to Finish", Self.secondsRemaining(remainingPages: remainingPages, averagePageSeconds: estimatedSeconds)
                                .map { StatisticsNumbers.formattedDuration($0) } ?? Self.pacePending),
                        ]
                    )
                    statisticsSection(
                        title: "Session",
                        stat: statistics.session,
                        characters: model.sessionCharacters,
                        isTracking: statistics.isTracking,
                        showToggle: true
                    )
                    statisticsSection(title: "Today", stat: statistics.today, characters: model.todayCharacters)
                }
            }
            .id(ReadingDay.key(ReadingDay.today(at: now, resetHour: resetHour)) + StatisticsZone.calendar.timeZone.identifier)
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in now = .now }
            .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now = $0 }
            .monospacedDigit()
            .onAppear {
                // Refresh the snapshot so the displayed reading time reflects elapsed session time.
                model.persistStatistics()
            }
            .navigationTitle("Manga Statistics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
        }
    }

    @ViewBuilder
    private func statisticsSection(
        title: String,
        stat: Statistics,
        characters: Int,
        pace: (label: String, secondsPerPage: Double?)? = nil,
        extraRows: [(String, String)] = [],
        isTracking: Bool = false,
        showToggle: Bool = false
    ) -> some View {
        Section {
            statRow("Characters Read", characters.formatted())
            statRow("Pages Read", "\(stat.charactersRead.formatted())")
            let readingPace = pace ?? (label: "Average Pace", secondsPerPage: Self.averagePageSeconds(stat))
            let formattedPace = readingPace.secondsPerPage.map { seconds in
                "\((3600 / seconds).formatted(.number.precision(.fractionLength(1)))) pages / h"
            }
            statRow(readingPace.label, formattedPace ?? Self.pacePending)
            statRow("Reading Time", StatisticsNumbers.formattedDuration(stat.readingTime))
            ForEach(extraRows, id: \.0) { statRow($0.0, $0.1) }
        } header: {
            HStack {
                Text(title)
                if showToggle {
                    Button {
                        model.toggleStatisticsTracking()
                    } label: {
                        Image(systemName: isTracking ? "pause.fill" : "play.fill")
                    }
                    .foregroundStyle(.primary)
                }
            }
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("**\(value)**")
        }
    }

    /// Pages left to the end of the volume after the last page on screen (never negative).
    private var remainingPages: Int {
        let lastShown = model.twoPageActive
            ? min(MangaReaderViewModel.spreadStart(model.pageIndex) + 1, model.pageCount - 1) : model.pageIndex
        return max(model.pageCount - (lastShown + 1), 0)
    }

    nonisolated static let pacePending = "Read a page to estimate"

    /// Manga's shared statistics row stores the number of pages in charactersRead.
    nonisolated static func averagePageSeconds(_ statistics: Statistics) -> Double? {
        pageSeconds(statistics, estimate: false)
    }

    nonisolated static func estimatedPageSeconds(_ statistics: Statistics) -> Double? {
        pageSeconds(statistics, estimate: true)
    }

    nonisolated private static func pageSeconds(_ statistics: Statistics, estimate: Bool) -> Double? {
        guard statistics.readingTime.isFinite else { return nil }
        var payload: [String: Any] = ["pages": statistics.charactersRead, "readingSeconds": statistics.readingTime]
        if estimate {
            payload["samples"] = statistics.mangaPageSeconds.map { [$0.key, $0.value] }
        }
        return ((try? HoshiCore.call("manga.pace", payload: payload)) as? String).flatMap(Double.init)
    }

    nonisolated static func secondsRemaining(remainingPages: Int, averagePageSeconds: Double?) -> Double? {
        var payload: [String: Any] = ["remainingPages": remainingPages]
        if let averagePageSeconds, averagePageSeconds.isFinite {
            payload["secondsPerPage"] = averagePageSeconds
        }
        return ((try? HoshiCore.call("manga.remaining-seconds", payload: payload)) as? String).flatMap(Double.init)
    }
}
