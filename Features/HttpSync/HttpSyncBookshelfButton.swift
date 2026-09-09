import SwiftUI

/// The shelf shortcut shares the same sync operation and diagnostics as HTTP Sync settings.
struct HttpSyncBookshelfButton: View {
    @State private var settings = HttpSyncSettingsStore.shared
    @State private var manager = HttpSyncManager.shared
    @State private var showStatus = false
    @State private var starting = false

    private var running: Bool { starting || manager.isSyncing }

    var body: some View {
        if !settings.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Button {
                showStatus = true
                guard !running else { return }
                starting = true
                // Dismissing progress does not cancel a library sync partway through.
                Task {
                    await manager.syncNow()
                    starting = false
                }
            } label: {
                if running {
                    ProgressView()
                } else {
                    Image(systemName: "cloud")
                }
            }
            .accessibilityLabel(running ? "Sync progress" : "Sync now")
            .accessibilityIdentifier("bookshelf-http-sync")
            .sheet(isPresented: $showStatus) {
                NavigationStack {
                    List {
                        if running {
                            if let progress = manager.progress {
                                HttpSyncProgressView(progress: progress)
                            } else {
                                ProgressView("Starting sync")
                            }
                        } else {
                            if let error = manager.lastError {
                                Text(error).foregroundStyle(.red)
                            } else if let status = manager.lastStatus {
                                Label("Sync complete", systemImage: "checkmark.circle")
                                Text(status)
                            }
                            if !manager.lastErrors.isEmpty {
                                Section("Sync errors (\(manager.lastErrors.count))") {
                                    ForEach(Array(manager.lastErrors.enumerated()), id: \.offset) { _, error in
                                        Text(error).font(.caption)
                                    }
                                }
                            }
                        }
                    }
                    .navigationTitle("HTTP Sync")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showStatus = false }
                        }
                    }
                }
                .presentationDetents([.medium, .large])
            }
        }
    }
}
