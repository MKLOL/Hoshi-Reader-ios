import Foundation

@Observable @MainActor final class PodcastStore {
    static let shared = PodcastStore()
    let files: PodcastFiles
    private let api: any PodcastServing
    private let configuration: @MainActor () -> HttpSyncConfig
    private(set) var account: String?
    private(set) var catalogue = PodcastCatalogue()
    private(set) var error: String?
    private(set) var loading = false
    private(set) var preparing: Set<String> = []
    private(set) var downloads: [String: Double] = [:]
    private(set) var downloadErrors: [String: String] = [:]
    private(set) var transcriptDownloads: [String: Double] = [:]
    private(set) var transcriptDownloadErrors: [String: String] = [:]
    private(set) var receivedUptime: TimeInterval?
    private var selectedConfigID: String?
    private var refreshTask: Task<Void, Never>?
    private var generation = 0
    private var screenGeneration = 0
    /// The listing last merged with the saved files. An identical poll skips that merge, which
    /// decodes and rewrites both listing files; any local change clears it.
    private var savedListing: (account: String, listing: PodcastCatalogue)?
    private(set) var screenVisible = false
    var revision = 0
    var configID: String {
        let config = configuration()
        return config.isConfigured ? PodcastRules.account(baseURL: config.baseURL, token: config.token) : ""
    }
    var enabled: Bool { account != nil && account == configID }

    init(files: PodcastFiles = PodcastFiles(), api: any PodcastServing = PodcastAPI(),
         configuration: @escaping @MainActor () -> HttpSyncConfig = { HttpSyncSettingsStore.shared.currentConfig() }) {
        self.files = files; self.api = api; self.configuration = configuration
        // A background URLSession relaunch need not create a SwiftUI scene. Restore the
        // previously validated account before the first queued download callback arrives.
        if !configID.isEmpty, files.validatedAccount == configID {
            account = configID; catalogue = files.load(configID)
        }
    }

    func setVisible(_ visible: Bool) {
        guard screenVisible != visible else { return }
        screenVisible = visible; screenGeneration += 1
        if !visible { cancelRefresh(); clearLiveStatus() }
    }

    private func cancelRefresh() {
        refreshTask?.cancel(); refreshTask = nil; loading = false
    }

    /// Owned by the shell's task, so editing credentials cancels the old validation loop.
    func monitorAccess() async {
        let config = configuration(), id = configID
        if selectedConfigID != id {
            generation += 1
            cancelRefresh()
            if selectedConfigID != nil { PodcastPlayback.shared.stop(); PodcastDownloads.shared.cancelAll() }
            selectedConfigID = id; account = nil; catalogue = PodcastCatalogue(); preparing = []; downloads = [:]; downloadErrors = [:]; transcriptDownloads = [:]; transcriptDownloadErrors = [:]; error = nil; savedListing = nil
            if !id.isEmpty, files.validatedAccount == id { account = id; catalogue = files.load(id) }
            PodcastDownloads.shared.restore()
        }
        guard !id.isEmpty else { invalidate(); return }
        var validatedInSession = false
        while !Task.isCancelled {
            do {
                let accepted = try await api.access(config: config)
                guard !Task.isCancelled, id == configID else { return }
                if accepted {
                    if !validatedInSession || account != id {
                        files.validatedAccount = id
                        files.prune(except: id)
                        PodcastDownloads.shared.restore()
                        validatedInSession = true
                    }
                    if account != id { account = id; catalogue = files.load(id); savedListing = nil }
                } else { validatedInSession = false; invalidate() }
            } catch {
                guard !Task.isCancelled, id == configID else { return }
                handle(error)
            }
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
        }
    }
    func invalidate() {
        PodcastPlayback.shared.stop(); PodcastDownloads.shared.cancelAll()
        generation += 1; cancelRefresh()
        account = nil; files.validatedAccount = nil; preparing = []; downloads = [:]; transcriptDownloads = [:]; downloadErrors = [:]; transcriptDownloadErrors = [:]; savedListing = nil; clearLiveStatus()
    }
    func clearLiveStatus() { catalogue.worker = nil; catalogue.generating = nil; receivedUptime = nil }
    func refresh() async {
        if let task = refreshTask { await task.value; return }
        guard let account, enabled, screenVisible else { return }
        let config = configuration(), version = generation, screenVersion = screenGeneration
        loading = true
        let task = Task { [self] in
            do {
                let fresh = try await api.catalogue(config: config)
                guard !Task.isCancelled, self.account == account, configID == account, generation == version,
                      screenVisible, screenGeneration == screenVersion else { return }
                // Save only a successful listing; a failed refresh never replaces the offline cache.
                if let savedListing, savedListing.account == account, savedListing.listing.sameListing(as: fresh) {
                    catalogue.worker = fresh.worker; catalogue.generating = fresh.generating
                } else {
                    catalogue = try files.save(fresh, account: account)
                    savedListing = (account, fresh.withoutTelemetry)
                }
                receivedUptime = ProcessInfo.processInfo.systemUptime
                error = nil; revision += 1
            } catch {
                guard !Task.isCancelled, self.account == account, generation == version,
                      screenVisible, screenGeneration == screenVersion else { return }
                clearLiveStatus(); handle(error)
            }
        }
        refreshTask = task
        await task.value
        if generation == version, screenGeneration == screenVersion { refreshTask = nil; loading = false }
    }
    func prepare(_ episode: PodcastEpisode) async {
        guard let account, enabled, PodcastRules.validID(episode.id), !preparing.contains(episode.id), !episode.needsAdministrator(maxFailures: catalogue.maxFailures) else { return }
        let version = generation
        preparing.insert(episode.id)
        defer { if generation == version { preparing.remove(episode.id) } }
        do {
            let config = configuration()
            let updated = try await api.prepare(config: config, id: episode.id)
            guard self.account == account, configID == account, generation == version else { return }
            if let index = catalogue.episodes.firstIndex(where: { $0.id == updated.id }) { catalogue.episodes[index] = updated }
            savedListing = nil
            await refresh()
        } catch { if self.account == account, configID == account, generation == version { handle(error) } }
    }
    func download(_ episode: PodcastEpisode) {
        guard let account, enabled, PodcastRules.validID(episode.id), downloads[episode.id] == nil, !isDownloaded(episode.id) else { return }
        do {
            try files.remember(episode, account: account, shows: catalogue.shows)
            downloadErrors[episode.id] = nil
            downloads[episode.id] = 0
            try PodcastDownloads.shared.start(episode: episode.id, account: account, config: configuration())
        } catch { downloads[episode.id] = nil; downloadErrors[episode.id] = PodcastRules.failureMessage(error) }
    }
    func downloadTranscript(_ episode: PodcastEpisode) {
        guard let account, enabled, PodcastRules.validID(episode.id), episode.transcript,
              transcriptDownloads[episode.id] == nil, !isTranscriptDownloaded(episode.id) else { return }
        do {
            try files.remember(episode, account: account, shows: catalogue.shows)
            transcriptDownloadErrors[episode.id] = nil
            transcriptDownloads[episode.id] = 0
            try PodcastDownloads.shared.start(episode: episode.id, account: account, config: configuration(), transcript: true)
        } catch { transcriptDownloads[episode.id] = nil; transcriptDownloadErrors[episode.id] = PodcastRules.failureMessage(error) }
    }
    func isDownloaded(_ id: String) -> Bool {
        _ = revision
        return account.map { files.isDownloaded(account: $0, id: id) } ?? false
    }
    func isTranscriptDownloaded(_ id: String) -> Bool {
        _ = revision
        return account.map { files.isTranscriptDownloaded(account: $0, id: id) } ?? false
    }
    func transcript(_ id: String) -> PodcastTranscript? {
        guard let account, enabled else { return nil }
        return files.loadTranscript(account: account, id: id)
    }
    func downloadProgress(account: String, id: String, fraction: Double, transcript: Bool = false) {
        guard self.account == account, configID == account, PodcastRules.validID(id) else { return }
        let progress = fraction.isFinite ? min(1, max(0, fraction)) : 0
        if transcript { transcriptDownloads[id] = progress } else { downloads[id] = progress }
    }
    func downloadFinished(account: String, id: String, failure: String?, transcript: Bool = false) {
        guard self.account == account, configID == account, PodcastRules.validID(id) else { return }
        if transcript { transcriptDownloads[id] = nil; transcriptDownloadErrors[id] = failure }
        else { downloads[id] = nil; downloadErrors[id] = failure }
        revision += 1
        savedListing = nil
        // Includes episodes whose show was archived while either media transfer ran.
        let cached = files.load(account)
        catalogue = catalogue.retaining(cached, downloaded: Set(cached.episodes.filter { files.hasSavedMedia(account: account, id: $0.id) }.map(\.id)))
    }
    private func handle(_ failure: Error) {
        if let http = failure as? PodcastHTTPError, [401, 403].contains(http.status) { invalidate() }
        error = PodcastRules.failureMessage(failure)
    }
}
