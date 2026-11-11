//
//  StatisticsView.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import Combine
import EPUBKit

struct StatisticsView: View {
    @State private var now = Date.now
    @AppStorage(ReadingDay.resetKey) private var resetHour = 3
    let viewModel: ReaderViewModel
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("Characters Read:")
                        Spacer()
                        Text("**\(viewModel.sessionStatistics.charactersRead.formatted(.number.grouping(.never)))**")
                    }
                    HStack {
                        Text("Reading Speed:")
                        Spacer()
                        Text("**\(viewModel.sessionStatistics.lastReadingSpeed.formatted(.number.grouping(.never))) / h**")
                    }
                    HStack {
                        Text("Reading Time:")
                        Spacer()
                        Text("**\(StatisticsNumbers.formattedDuration(viewModel.sessionStatistics.readingTime))**")
                    }
                    HStack {
                        Text("Time to finish Book:")
                        Spacer()
                        Text("**\(StatisticsNumbers.formattedDuration(viewModel.sessionStatistics.lastReadingSpeed > 0 ? Double(viewModel.bookInfo.characterCount - viewModel.currentCharacter) / (Double(viewModel.sessionStatistics.lastReadingSpeed) / 3600.0) : 0))**")
                    }
                    HStack {
                        Text("Time to finish Chapter:")
                        Spacer()
                        Text("**\(StatisticsNumbers.formattedDuration(viewModel.sessionStatistics.lastReadingSpeed > 0 ? Double(viewModel.currentChapterCount - viewModel.currentCharacter) / (Double(viewModel.sessionStatistics.lastReadingSpeed) / 3600.0) : 0))**")
                    }
                } header: {
                    HStack {
                        Text("Session")
                        if !viewModel.isTracking {
                            Button {
                                viewModel.startTracking()
                            } label: {
                                Image(systemName: "play.fill")
                            }
                            .foregroundStyle(.primary)
                        } else {
                            Button {
                                viewModel.stopTracking()
                            } label: {
                                Image(systemName: "pause.fill")
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }
                
                Section {
                    HStack {
                        Text("Characters Read:")
                        Spacer()
                        Text("**\(viewModel.todaysStatistics.charactersRead.formatted(.number.grouping(.never)))**")
                    }
                    HStack {
                        Text("Reading Speed:")
                        Spacer()
                        Text("**\(viewModel.todaysStatistics.lastReadingSpeed.formatted(.number.grouping(.never))) / h**")
                    }
                    HStack {
                        Text("Reading Time:")
                        Spacer()
                        Text("**\(StatisticsNumbers.formattedDuration(viewModel.todaysStatistics.readingTime))**")
                    }
                } header: {
                    Text("Today")
                }
                
                Section {
                    HStack {
                        Text("Characters Read:")
                        Spacer()
                        Text("**\(viewModel.allTimeStatistics.charactersRead.formatted(.number.grouping(.never)))**")
                    }
                    HStack {
                        Text("Reading Speed:")
                        Spacer()
                        Text("**\(viewModel.allTimeStatistics.lastReadingSpeed.formatted(.number.grouping(.never))) / h**")
                    }
                    HStack {
                        Text("Reading Time:")
                        Spacer()
                        Text("**\(StatisticsNumbers.formattedDuration(viewModel.allTimeStatistics.readingTime))**")
                    }
                } header: {
                    Text("All Time")
                }
            }
            .id(ReadingDay.key(ReadingDay.date(at: now, resetHour: resetHour)) + StatisticsZone.calendar.timeZone.identifier)
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in now = .now }
            .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now = $0 }
            .monospacedDigit()
            .navigationTitle("Statistics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        viewModel.activeSheet = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
        }
    }
}
