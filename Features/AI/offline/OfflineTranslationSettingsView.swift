//
//  OfflineTranslationSettingsView.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Settings UI for offline, on-device translation. Ported from Android
//  `features/ai/offline/OfflineTranslationSection.kt`: a "Use on-device translation" toggle (only
//  enabled once a model is downloaded), the model catalog with per-model select (radio) + download
//  / progress / delete, the active model, and total storage used.
//

import SwiftUI

struct OfflineTranslationSettingsView: View {
    @State private var settings = OfflineTranslationSettingsStore.shared
    @State private var downloads = ModelDownloadManager.shared

    /// At least one model is downloaded → on-device translation can be enabled.
    private var anyDownloaded: Bool { !downloads.downloadedModelIds().isEmpty }

    var body: some View {
        @Bindable var settings = settings
        List {
            Section {
                Toggle("Use on-device translation", isOn: $settings.useOnDeviceTranslation)
                    .disabled(!anyDownloaded)
            } footer: {
                if anyDownloaded {
                    Text("Translate speech bubbles fully on-device using a downloaded model. No API "
                        + "key or connection needed. Quality is lower than ChatGPT. Screenshot "
                        + "(vision) translation still uses ChatGPT.")
                } else {
                    Text("Download a model below first, then enable this to translate speech bubbles "
                        + "fully on-device — no API key or connection needed.")
                }
            }

            Section {
                ForEach(LlmModelCatalog.all) { model in
                    ModelRow(
                        model: model,
                        isSelected: settings.selectedModel.id == model.id,
                        state: downloads.downloadState(for: model),
                        isDownloaded: downloads.isDownloaded(model),
                        isAnyDownloading: downloads.isAnyDownloading,
                        onSelect: { settings.selectedModelId = model.id },
                        onDownload: { downloads.download(model) },
                        onCancel: { downloads.cancel(model) },
                        onDelete: {
                            downloads.delete(model)
                            // If we deleted the last model, on-device must be turned back off.
                            if downloads.downloadedModelIds().isEmpty {
                                settings.useOnDeviceTranslation = false
                            }
                        }
                    )
                }
            } header: {
                Text("Model")
            } footer: {
                Text("Downloads once over the network and resumes if interrupted, then works "
                    + "offline. Selecting a model that isn't downloaded shows a Download button.")
            }

            if downloads.totalStorageBytes() > 0 {
                Section {
                    HStack {
                        Text("Storage used")
                        Spacer()
                        Text(Self.formatBytes(downloads.totalStorageBytes()))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("On-device Translation")
        .navigationBarTitleDisplayMode(.inline)
    }

    static func formatBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 MB" }
        let mb = Double(bytes) / (1024 * 1024)
        return mb >= 1024
            ? String(format: "%.1f GB", mb / 1024)
            : String(format: "%.0f MB", mb)
    }
}

private struct ModelRow: View {
    let model: LlmModel
    let isSelected: Bool
    let state: ModelDownloadState
    let isDownloaded: Bool
    let isAnyDownloading: Bool
    let onSelect: () -> Void
    let onDownload: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onSelect) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .imageScale(.large)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(model.displayName)
                                .font(.body)
                                .foregroundStyle(.primary)
                            Spacer()
                            if isDownloaded {
                                Text("Downloaded")
                                    .font(.caption)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        Text(model.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(OfflineTranslationSettingsView.formatBytes(model.approxSizeBytes))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)

            control
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var control: some View {
        switch state {
        case let .downloading(downloaded, total):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: state.fraction ?? 0)
                Text("\(OfflineTranslationSettingsView.formatBytes(downloaded)) / "
                    + OfflineTranslationSettingsView.formatBytes(total))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Cancel", role: .cancel, action: onCancel)
                    .font(.callout)
            }
        case let .failed(message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("Retry", action: onDownload)
                    .font(.callout)
            }
        default:
            if isDownloaded {
                Button("Delete", role: .destructive, action: onDelete)
                    .font(.callout)
            } else if isAnyDownloading {
                Text("Another model is downloading…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Download", action: onDownload)
                    .font(.callout)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
