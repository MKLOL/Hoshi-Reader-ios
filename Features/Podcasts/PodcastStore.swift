import Foundation

@Observable @MainActor final class PodcastStore {
    static let shared = PodcastStore()
    let files = PodcastFiles()
    private let api = PodcastAPI()
    private(set) var account: String?
    private(set) var catalogue = PodcastCatalogue()
    private(set) var error: String?
    private(set) var loading = false
    private(set) var preparing: Set<String> = []
    private(set) var downloads: [String: Double] = [:]
    private(set) var downloadErrors: [String: String] = [:]
    private(set) var receivedUptime: TimeInterval?
    private var selectedConfigID: String?
    private var refreshTask: Task<Void, Never>?
    private var generation = 0
    var revision = 0
    var configID: String {
        let config = HttpSyncSettingsStore.shared.currentConfig()
        return config.isConfigured ? PodcastRules.account(baseURL: config.baseURL, token: config.token) : ""
    }
    var enabled: Bool { account != nil && account == configID }

    /// Owned by the shell's task, so editing credentials cancels the old validation loop.
    func monitorAccess() async {
        let config = HttpSyncSettingsStore.shared.currentConfig(), id = configID
        if selectedConfigID != id {
            generation += 1
            refreshTask?.cancel(); refreshTask = nil; loading = false
            if selectedConfigID != nil { PodcastPlayback.shared.stop(); PodcastDownloads.shared.cancelAll() }
            selectedConfigID = id; account = nil; catalogue = PodcastCatalogue(); preparing = []; downloads = [:]; error = nil
            if !id.isEmpty, files.validatedAccount == id { account = id; catalogue = files.load(id) }
            PodcastDownloads.shared.restore()
        }
        guard !id.isEmpty else { invalidate(); return }
        while !Task.isCancelled {
            do {
                let accepted = try await api.access(config: config)
                guard !Task.isCancelled, id == configID else { return }
                if accepted {
                    files.validatedAccount = id
                    files.prune(except: id)
                    if account != id { account = id; catalogue = files.load(id) }
                    PodcastDownloads.shared.restore()
                } else { invalidate() }
            } catch {
                guard !Task.isCancelled, id == configID else { return }
                handle(error)
            }
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
        }
    }
    func invalidate() {
        account = nil; files.validatedAccount = nil; clearLiveStatus()
        PodcastPlayback.shared.stop(); PodcastDownloads.shared.cancelAll()
    }
    func clearLiveStatus() { catalogue.worker = nil; catalogue.generating = nil; receivedUptime = nil }
    func refresh() async {
        if let task = refreshTask { await task.value; return }
        guard let account, enabled else { return }
        let config = HttpSyncSettingsStore.shared.currentConfig(), version = generation
        loading = true
        let task = Task { [self] in
            do {
                let fresh = try await api.get(PodcastCatalogue.self, config: config)
                guard !Task.isCancelled, self.account == account, configID == account, generation == version else { return }
                // Save only a successful listing; a failed refresh never replaces the offline cache.
                catalogue = try files.save(fresh, account: account)
                receivedUptime = ProcessInfo.processInfo.systemUptime
                error = nil; revision += 1
            } catch {
                guard !Task.isCancelled, self.account == account, generation == version else { return }
                clearLiveStatus(); handle(error)
            }
        }
        refreshTask = task
        await task.value
        if generation == version { refreshTask = nil; loading = false }
    }
    func prepare(_ episode: PodcastEpisode) async {
        guard let account, enabled, PodcastRules.validID(episode.id), !preparing.contains(episode.id), !episode.needsAdministrator(maxFailures: catalogue.maxFailures) else { return }
        preparing.insert(episode.id)
        defer { preparing.remove(episode.id) }
        do {
            let config = HttpSyncSettingsStore.shared.currentConfig()
            let updated = try await api.get(PodcastEpisode.self, config: config, suffix: "/\(episode.id)/prepare", post: true)
            guard self.account == account, configID == account else { return }
            if let index = catalogue.episodes.firstIndex(where: { $0.id == updated.id }) { catalogue.episodes[index] = updated }
            await refresh()
        } catch { if self.account == account, configID == account { handle(error) } }
    }
    func download(_ episode: PodcastEpisode) {
        guard let account, enabled, PodcastRules.validID(episode.id) else { return }
        do {
            try files.remember(episode, account: account, shows: catalogue.shows)
            downloadErrors[episode.id] = nil
            downloads[episode.id] = 0
            try PodcastDownloads.shared.start(episode: episode.id, account: account, config: HttpSyncSettingsStore.shared.currentConfig())
        } catch { downloadErrors[episode.id] = PodcastRules.display(error.localizedDescription) }
    }
    func isDownloaded(_ id: String) -> Bool {
        _ = revision
        return account.map { files.isDownloaded(account: $0, id: id) } ?? false
    }
    func downloadProgress(account: String, id: String, fraction: Double) {
        guard self.account == account, configID == account else { return }
        downloads[id] = fraction
    }
    func downloadFinished(account: String, id: String, failure: String?) {
        guard self.account == account, configID == account else { return }
        downloads[id] = nil; downloadErrors[id] = failure; revision += 1
        // Includes lessons whose show was archived while the transfer ran.
        let cached = files.load(account)
        catalogue = catalogue.retaining(cached, downloaded: Set(cached.episodes.filter { files.isDownloaded(account: account, id: $0.id) }.map(\.id)))
    }
    private func handle(_ failure: Error) {
        if let http = failure as? PodcastHTTPError, [401, 403].contains(http.status) { invalidate() }
        error = PodcastRules.display(failure.localizedDescription) ?? "Could not reach the podcast server."
    }
}
