//
//  MangaStatisticsView.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Manga reading statistics sheet, presented from the reader's overflow menu. Mirrors Android's
//  `features/mangareader/MangaStatisticsSheet.kt`: a Session / Today / All Time breakdown of
//  pages read, pace and reading time, with a start/pause control and a progress bar. "Pages"
//  are stored in the shared `Statistics.charactersRead` field by `MangaStatisticsTracker`.
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
                    statisticsSection(
                        title: "Session",
                        stat: statistics.session,
                        characters: model.sessionCharacters,
                        isTracking: statistics.isTracking,
                        showToggle: true
                    )
                    statisticsSection(title: "Today", stat: statistics.today, characters: model.todayCharacters)
                    statisticsSection(title: "All Time", stat: statistics.allTime, characters: model.allTimeCharacters)
                }
            }
            .id(ReadingDay.date(at: now, resetHour: resetHour))
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
        isTracking: Bool = false,
        showToggle: Bool = false
    ) -> some View {
        Section {
            statRow("Characters Read", characters.formatted())
            statRow("Pages Read", "\(stat.charactersRead.formatted())")
            statRow("Pace", "\(stat.lastReadingSpeed.formatted()) pages / h")
            statRow("Reading Time", Duration.seconds(stat.readingTime).formatted())
            if showToggle {
                statRow("Pages Remaining", "\(remainingPages.formatted())")
                statRow(
                    "Time to Finish",
                    Duration.seconds(secondsRemaining(speed: stat.lastReadingSpeed)).formatted()
                )
            }
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

    /// Pages left to the end of the volume from the current page (never negative).
    private var remainingPages: Int {
        max(model.pageCount - (model.pageIndex + 1), 0)
    }

    private func secondsRemaining(speed: Int) -> Double {
        guard speed > 0 else { return 0 }
        return Double(remainingPages) / (Double(speed) / 3600.0)
    }
}
