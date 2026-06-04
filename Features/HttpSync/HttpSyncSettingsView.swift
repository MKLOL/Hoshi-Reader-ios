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
                Toggle("Auto-sync while reading", isOn: $store.enabled)
            } footer: {
                Text("When on, page turns and new ChatGPT replies are pushed to the server automatically. \"Sync now\" works either way.")
            }

            Section {
                Button {
                    Task { await manager.syncNow() }
                } label: {
                    HStack {
                        Text("Sync now")
                        Spacer()
                        if manager.isSyncing { ProgressView() }
                    }
                }
                .disabled(manager.isSyncing || !store.isConfigured)

                if manager.isSyncing, let progress = manager.progress {
                    syncProgressView(progress)
                }
            } footer: {
                statusFooter
            }

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

    /// Live phased progress shown while a "Sync now" reconcile runs: a linear bar (determinate when
    /// the current phase has a counter, indeterminate otherwise) plus the phase label and an
    /// optional finer-grained detail line. Mirrors Android's `SyncProgressView`.
    @ViewBuilder
    private func syncProgressView(_ progress: HttpSyncProgress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
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
