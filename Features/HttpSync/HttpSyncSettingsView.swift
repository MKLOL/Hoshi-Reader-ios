//
//  HttpSyncSettingsView.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Settings screen for the v2 KV HTTP sync: base URL, bearer token (→ Keychain), an enable
//  toggle for the reader auto-push hooks, and a "Sync now" button with last-status / error
//  display. Mirrors the Android HttpSyncSettingsView.
//

import SwiftUI

struct HttpSyncSettingsView: View {
    @State private var store = HttpSyncSettingsStore.shared
    @State private var manager = HttpSyncManager.shared
    @State private var tokenField: String = ""
    @State private var showErrorDetails = false
    @State private var interrupted = HttpSyncDownloadCache.Summary()
    @State private var cleaning = false
    @State private var starting = false

    var body: some View {
        Form {
            Section {
                TextField("Base URL", text: $store.baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                SecureField("Bearer token", text: $tokenField)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: tokenField) { _, newValue in
                        store.token = newValue
                    }
            } header: {
                Text("Server")
            } footer: {
                Text("The server is a generic key/value store. The token is stored in the Keychain and never synced.")
            }

            Section {
                Label("Reading progress syncs automatically", systemImage: "arrow.triangle.2.circlepath")
            } footer: {
                Text("Page turns, reading statistics and translation replies sync whenever a server and token are configured.")
            }

            Section {
                Button {
                    starting = true
                    Task { await manager.syncNow(); starting = false }
                } label: {
                    HStack {
                        Text("Sync now")
                        Spacer()
                        if manager.isSyncing || starting { ProgressView() }
                    }
                }
                .disabled(manager.isSyncing || starting || !store.isConfigured)

                if manager.isSyncing, let progress = manager.progress {
                    HttpSyncProgressView(progress: progress, transfer: manager.transferProgress)
                }
                if manager.isSyncing || starting {
                    Button("Cancel sync", role: .cancel) { manager.cancelSync() }
                }
            } footer: {
                statusFooter
            }

            Section {
                LabeledContent("Unused transfers", value: "\(interrupted.count)")
                LabeledContent("Storage", value: ByteCountFormatter.string(fromByteCount: interrupted.bytes, countStyle: .file))
                Button("Remove unused transfers", role: .destructive) {
                    cleaning = true
                    Task {
                        _ = await manager.cleanInterruptedDownloads()
                        interrupted = await manager.interruptedDownloadSummary()
                        cleaning = false
                    }
                }
                .disabled(cleaning || interrupted.count == 0)
            } header: { Text("Interrupted downloads") }
              footer: { Text("Interrupted books resume on the next sync. Active transfers are kept; unused transfers older than a week are removed automatically.") }

            if !manager.lastErrors.isEmpty {
                Section {
                    DisclosureGroup("Sync errors (\(manager.lastErrors.count))", isExpanded: $showErrorDetails) {
                        ForEach(Array(manager.lastErrors.enumerated()), id: \.offset) { _, error in
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("HTTP Sync")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { tokenField = store.token }
        .onDisappear {
            manager.syncInBackground()
            HttpStatisticsLane.shared.schedule(flush: true)
        }
        .task { interrupted = await manager.interruptedDownloadSummary() }
        .onChange(of: manager.isSyncing) { _, _ in
            Task { interrupted = await manager.interruptedDownloadSummary() }
        }
    }

    @ViewBuilder
    private var statusFooter: some View {
        if let error = manager.lastError {
            Text(error).foregroundStyle(.red)
        } else if let status = manager.lastStatus {
            Text("Last sync: \(status)")
        } else if !store.isConfigured {
            Text("Add a base URL and token to enable sync.")
        }
    }

}

struct HttpSyncProgressView: View {
    let progress: HttpSyncProgress
    var transfer: HttpSyncTransferProgress? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            if let transfer {
                if let fraction = transfer.fraction { ProgressView(value: fraction) }
                Text(transfer.label).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(progress.message)
                .font(.subheadline)
                .foregroundStyle(.primary)
            if let detail = progress.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
