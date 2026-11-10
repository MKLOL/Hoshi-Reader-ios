//
//  StorageCleanupView.swift
//  Hoshi Reader
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

struct StorageCleanupView: View {
    @State private var categories: [StorageCleanup.Category]?
    @State private var isCleaning = false
    @State private var showConfirmation = false

    private var total: Int64 { (categories ?? []).reduce(0) { $0 + $1.size } }

    var body: some View {
        List {
            if let categories, !isCleaning {
                if categories.isEmpty {
                    Text("No leftover files were found.")
                        .foregroundStyle(.secondary)
                } else {
                    Section {
                        ForEach(categories) { category in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(category.title)
                                    Spacer()
                                    Text(Self.size(category.size))
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                                Text(category.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("^[\(category.count) item](inflect: true)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    } footer: {
                        Text("Books, dictionaries, reading history and settings are never touched. Files written in the last ten minutes are left for the work that may still be using them.")
                    }
                    Section {
                        Button("Clean Up \(Self.size(total))", role: .destructive) { showConfirmation = true }
                    }
                }
            } else {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(isCleaning ? "Cleaning…" : "Scanning app storage…")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Storage Cleanup")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete \(Self.size(total)) of leftover files? This cannot be undone.",
                            isPresented: $showConfirmation, titleVisibility: .visible) {
            Button("Clean Up", role: .destructive) { clean() }
        }
        .task { await scan() }
    }

    private func scan() async {
        let cleanup = StorageCleanup.installed
        categories = await Task.detached(priority: .utility) { cleanup.scan() }.value
    }

    private func clean() {
        guard let shown = categories else { return }
        isCleaning = true
        Task {
            let cleanup = StorageCleanup.installed
            categories = await Task.detached(priority: .utility) { cleanup.clean(shown) }.value
            isCleaning = false
        }
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
