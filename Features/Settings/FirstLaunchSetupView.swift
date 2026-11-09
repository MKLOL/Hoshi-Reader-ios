import SwiftUI

struct FirstLaunchSetupView: View {
    let setup: FirstLaunchSetup
    @State private var token = ""
    @State private var manager = HttpSyncManager.shared
    @State private var dictionaries = DictionaryManager.shared

    var body: some View {
        NavigationStack {
            Form {
                switch setup.step {
                case .token:
                    Section {
                        Text("Paste a token shared with you to sync your books and reading data. No account is needed.")
                        SecureField("Bearer token", text: $token)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Sync now") { setup.useToken(token) }
                            .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("I don’t have a token") { setup.withoutToken() }
                    }
                case .later:
                    Section {
                        Text("When you have a token, open Settings → Advanced → HTTP Sync, paste it into Bearer token, then tap Sync now.")
                        Button("Continue") { setup.finishLater(clearRefusedToken: manager.tokenRejected) }
                    }
                case .dictionaries:
                    Section {
                        Text("Download JMdict for Japanese–English definitions and Jiten for word frequency, so you can look up words while reading. You can also add dictionaries later in Settings → Dictionaries → Download Recommended Dictionaries.")
                        if setup.installing {
                            ProgressView()
                            Text(dictionaries.currentImport).font(.subheadline)
                        }
                        if setup.installFailed {
                            Text(dictionaries.errorMessage.isEmpty
                                 ? "Could not finish installing the dictionaries. Check your connection and tap Download dictionaries to retry."
                                 : dictionaries.errorMessage)
                                .foregroundStyle(.red)
                        }
                        Button("Download dictionaries") { setup.downloadDictionaries() }
                            .disabled(setup.installing)
                        Button("Skip for now") { setup.skipDictionaries() }
                            .disabled(setup.installing)
                    }
                    if manager.isSyncing, let progress = manager.progress {
                        Section("Sync") { HttpSyncProgressView(progress: progress, transfer: manager.transferProgress) }
                    }
                case .status:
                    Section {
                        if manager.isSyncing, let progress = manager.progress {
                            HttpSyncProgressView(progress: progress, transfer: manager.transferProgress)
                        } else if manager.isSyncing { ProgressView() }
                        if let error = manager.lastError { Text(error).foregroundStyle(.red) }
                        if let status = manager.lastStatus { Text(status) }
                        if manager.tokenRejected {
                            Button("Edit token") { token = ""; setup.editRefusedToken() }
                        }
                        Button(manager.isSyncing ? "Continue in background" : "Done") { setup.dismissStatus() }
                        if manager.isSyncing {
                            Button("Cancel sync", role: .cancel) { manager.cancelSync(); setup.dismissStatus() }
                        }
                    }
                case .hidden: EmptyView()
                }
                if setup.saveFailed {
                    Section {
                        Text("Could not save your setup. Please try again.").foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled()
    }

    private var title: String {
        switch setup.step {
        case .token: "Do you have a sync token?"
        case .later: "Set up sync later"
        case .dictionaries: "Add the default dictionaries?"
        case .status: "Sync"
        case .hidden: "Welcome"
        }
    }
}
