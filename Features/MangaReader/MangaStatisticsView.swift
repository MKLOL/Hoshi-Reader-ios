//
//  MangaStatisticsView.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Manga reading statistics sheet, presented from the reader's overflow menu. Mirrors Android's
//  `features/mangareader/MangaStatisticsSheet.kt`: saved All Time totals and the median-pace
//  estimate first, then Session and Today, with a start/pause control and a progress bar.
//  "Pages" are stored in the shared `Statistics.charactersRead` field by `MangaStatisticsTracker`.
//

import SwiftUI
import Combine

struct MangaStatisticsView: View {
    @State private var now = Date.now
    @AppStorage(ReadingDay.resetKey) private var resetHour = 3
    @AppStorage(StatisticsZone.key) private var zoneID = StatisticsZone.defaultID
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
                    let median = allTime.medianPageSeconds
                    statisticsSection(
                        title: "All Time",
                        stat: allTime,
                        characters: model.allTimeCharacters,
                        pace: ("Median Pace", median.map { "\((3600 / $0).formatted(.number.precision(.fractionLength(1)))) pages / h" } ?? Self.pacePending),
                        extraRows: [
                            ("Pages Remaining", remainingPages.formatted()),
                            ("Time to Finish", Self.secondsRemaining(remainingPages: remainingPages, medianPageSeconds: median)
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
            .id(ReadingDay.key(ReadingDay.date(at: now, resetHour: resetHour)) + zoneID)
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
        pace: (label: String, value: String)? = nil,
        extraRows: [(String, String)] = [],
        isTracking: Bool = false,
        showToggle: Bool = false
    ) -> some View {
        Section {
            statRow("Characters Read", characters.formatted())
            statRow("Pages Read", "\(stat.charactersRead.formatted())")
            let pace = pace ?? ("Average Pace", "\(stat.lastReadingSpeed.formatted()) pages / h")
            statRow(pace.label, pace.value)
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

    /// Remaining pages at the book's median completed-page time; unknown until a page completes.
    nonisolated static func secondsRemaining(remainingPages: Int, medianPageSeconds: Double?) -> Double? {
        if remainingPages <= 0 { return 0 }
        guard let medianPageSeconds, medianPageSeconds.isFinite, medianPageSeconds > 0 else { return nil }
        return Double(remainingPages) * medianPageSeconds
    }
}
