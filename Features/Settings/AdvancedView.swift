//
//  AdvancedView.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

struct AdvancedView: View {
    @State private var anonymousStats = AnonymousStatsReporter.shared
    var body: some View {
        List {
            Section {
                NavigationLink {
                    AudioView()
                } label: {
                    Label("Audio", systemImage: "speaker.wave.2")
                }
                .foregroundStyle(.primary)
                
                NavigationLink {
                    StatisticsSettingsView()
                } label: {
                    Label("Statistics", systemImage: "chart.xyaxis.line")
                }
                .foregroundStyle(.primary)
                
                NavigationLink {
                    SasayakiSettingsView()
                } label: {
                    Label("Sasayaki (Audiobooks)", systemImage: "waveform")
                }
                .foregroundStyle(.primary)
            }
            
            Section {
                NavigationLink {
                    AiSettingsView()
                } label: {
                    Label("Translation model", systemImage: "sparkles")
                }
                .foregroundStyle(.primary)

                NavigationLink {
                    OfflineTranslationSettingsView()
                } label: {
                    Label("On-device Translation", systemImage: "cpu")
                }
                .foregroundStyle(.primary)
            }

            Section {
                NavigationLink {
                    SyncView()
                } label: {
                    Label("ッツ Sync", systemImage: "cloud")
                }
                .foregroundStyle(.primary)

                NavigationLink {
                    HttpSyncSettingsView()
                } label: {
                    Label("Sync (HTTP)", systemImage: "arrow.triangle.2.circlepath")
                }
                .foregroundStyle(.primary)

                NavigationLink {
                    AnkiConnectView()
                } label: {
                    Label("AnkiConnect", systemImage: "app.connected.to.app.below.fill")
                }
                .foregroundStyle(.primary)
            }

            Section {
                Toggle("Share anonymous usage statistics", isOn: Binding(
                    get: { anonymousStats.enabled }, set: { anonymousStats.setEnabled($0) }
                ))
            } footer: {
                Text("A random install ID, app and iOS version, device model, screen size, language, library counts, sync on/off and reader layout, about once a day. No book titles, reading text, account or sync token. The first report waits 20 hours; turning this off deletes the ID.")
            }
            
            Section {
                NavigationLink {
                    BackupView()
                } label: {
                    Label("Backup", systemImage: "externaldrive")
                }
                .foregroundStyle(.primary)

                NavigationLink {
                    StorageCleanupView()
                } label: {
                    Label("Storage Cleanup", systemImage: "trash")
                }
                .foregroundStyle(.primary)
            }
            
        }
        .navigationTitle("Advanced")
    }
}
