import Foundation
import Observation

/// Kept outside the backup so a restored installation can offer credentials and dictionaries
/// that did not arrive with the user's library. Returning installations skip the new setup.
nonisolated struct FirstLaunchState: Codable, Equatable, Sendable {
    var tokenCompleted: Bool
    var dictionariesCompleted: Bool

    static func seed(fresh: Bool, restored: Bool, hasToken: Bool, hasTermDictionary: Bool) -> Self {
        if restored { return .init(tokenCompleted: hasToken, dictionariesCompleted: hasTermDictionary) }
        return .init(tokenCompleted: !fresh, dictionariesCompleted: !fresh)
    }
}

@Observable @MainActor
final class FirstLaunchSetup {
    enum Step: Equatable { case token, later, dictionaries, status, hidden }
    private(set) var step: Step = .hidden
    private(set) var installing = false
    private(set) var installFailed = false
    private(set) var saveFailed = false
    private var state: FirstLaunchState
    private let stateURL: URL
    private let defaults: UserDefaults
    private var startedSync = false
    private let hasToken: () -> Bool
    private let saveToken: (String) -> Bool
    private let startSync: () -> Void
    private let install: (@escaping @MainActor (Bool) -> Void) -> Void
    private static let launchedKey = "firstLaunchSetup.hasLaunched"

    init(defaults: UserDefaults = .standard, directory: URL? = nil, priorUse: Bool? = nil,
         hasToken: @escaping () -> Bool = { HttpSyncSettingsStore.shared.isConfigured },
         hasTermDictionary: @escaping () -> Bool = { !DictionaryManager.shared.termDictionaries.isEmpty },
         saveToken: @escaping (String) -> Bool = { token in
             let store = HttpSyncSettingsStore.shared
             if store.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                 store.baseURL = HttpSyncSettingsStore.defaultBaseURL
             }
             store.token = token
             return store.token == token
         },
         startSync: @escaping () -> Void = { Task { await HttpSyncManager.shared.syncNow() } },
         install: @escaping (@escaping @MainActor (Bool) -> Void) -> Void = {
             DictionaryManager.shared.importRecommendedDictionaries(completion: $0)
         }) {
        self.defaults = defaults
        self.hasToken = hasToken
        self.saveToken = saveToken
        self.startSync = startSync
        self.install = install
        let prior = priorUse ?? Self.hasPriorUse(defaults: defaults)
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FirstLaunchSetup", isDirectory: true)
        self.stateURL = directory.appendingPathComponent("state.json")
        let stored = (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(FirstLaunchState.self, from: $0) }
        self.state = stored ?? .seed(fresh: !prior, restored: defaults.bool(forKey: Self.launchedKey),
                                    hasToken: hasToken(), hasTermDictionary: hasTermDictionary())
        // A configured install never needs to paste its token again.
        if hasToken() { state.tokenCompleted = true }
        defaults.set(true, forKey: Self.launchedKey)
        _ = persist()
        show(state.tokenCompleted ? .dictionaries : .token)
    }

    func useToken(_ raw: String) {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard step == .token, !token.isEmpty else { return }
        guard saveToken(token) else { saveFailed = true; return }
        state.tokenCompleted = true
        guard persist() else { return }
        startedSync = true
        startSync()
        show(.dictionaries)
    }

    func withoutToken() { if step == .token { show(.later) } }

    /// A refused token is cleared only when the person explicitly chooses to continue without it.
    func finishLater(clearRefusedToken: Bool = false) {
        guard step == .later else { return }
        if startedSync && clearRefusedToken && !saveToken("") { saveFailed = true; return }
        state.tokenCompleted = true
        guard persist() else { return }
        startedSync = false
        show(.dictionaries)
    }

    func downloadDictionaries() {
        guard step == .dictionaries, !installing else { return }
        installing = true
        installFailed = false
        install { [weak self] success in
            guard let self else { return }
            installing = false
            if success {
                state.dictionariesCompleted = true
                if persist(), step == .dictionaries { show(.dictionaries) }
            } else { installFailed = true }
        }
    }

    func skipDictionaries() {
        guard step == .dictionaries, !installing else { return }
        state.dictionariesCompleted = true
        if persist() { show(.dictionaries) }
    }

    func dismissStatus() { if step == .status { show(.hidden) } }
    func editRefusedToken() { if step == .status { show(.token) } }

    private func show(_ requested: Step) {
        saveFailed = false
        step = requested == .dictionaries && state.dictionariesCompleted ? (startedSync ? .status : .hidden) : requested
    }

    @discardableResult private func persist() -> Bool {
        do {
            var directory = stateURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
            return true
        } catch { saveFailed = true; return false }
    }

    private static func hasPriorUse(defaults: UserDefaults) -> Bool {
        if defaults.object(forKey: "migratedToAppSupport") != nil { return true }
        if ["fontSize", "theme", "httpSync.baseURL", "bookshelfSortOption"].contains(where: { defaults.object(forKey: $0) != nil }) { return true }
        let roots = [FileManager.SearchPathDirectory.applicationSupportDirectory, .documentDirectory]
        return roots.flatMap { FileManager.default.urls(for: $0, in: .userDomainMask) }
            .contains { root in ["Books", "Dictionaries", "anki_config.json"].contains { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) } }
    }
}
