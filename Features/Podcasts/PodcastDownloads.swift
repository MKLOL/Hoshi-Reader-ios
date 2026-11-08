import Foundation

@MainActor final class PodcastDownloads {
    static let shared = PodcastDownloads()
    static let identifier = "com.dragosristache.hoshi.podcasts.downloads"
    private let delegate = PodcastDownloadDelegate()
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.timeoutIntervalForResource = 24 * 60 * 60
        return URLSession(configuration: config, delegate: delegate, delegateQueue: .main)
    }()
    private var tasks: [String: URLSessionTask] = [:]
    private var forcedErrors: [Int: String] = [:]
    private var epochs = PodcastDownloadEpochs()
    private var progressThrottles: [Int: HttpSyncProgressThrottle] = [:]
    var backgroundCompletion: (() -> Void)?

    func restore() {
        _ = session
        Task {
            for task in await session.allTasks {
                guard let description = task.taskDescription, let pair = Self.pair(description) else { task.cancel(); continue }
                guard task.state == .running || task.state == .suspended else { continue }
                guard !isRetired(task, account: pair.account) else { task.cancel(); continue }
                guard PodcastStore.shared.enabled, PodcastStore.shared.account == pair.account else {
                    // A cold start may still be restoring its validated account marker.
                    if PodcastStore.shared.configID != pair.account || PodcastStore.shared.files.validatedAccount != pair.account { task.cancel() }
                    continue
                }
                let key = pair.key
                if let current = tasks[key], current.taskIdentifier != task.taskIdentifier { task.cancel(); continue }
                tasks[key] = task
                epochs.record(task.taskIdentifier)
                let fraction = task.countOfBytesExpectedToReceive > 0 ? Double(task.countOfBytesReceived) / Double(task.countOfBytesExpectedToReceive) : 0
                PodcastStore.shared.downloadProgress(account: pair.account, id: pair.id, fraction: pair.part == .transcript ? 0 : min(1, max(0, fraction)), transcript: pair.part.isTranscript)
            }
        }
    }
    func start(episode: String, account: String, config: HttpSyncConfig, transcript: Bool = false) throws {
        guard PodcastRules.validID(account), PodcastRules.validID(episode) else { throw CocoaError(.fileReadInvalidFileName) }
        let pair = PodcastDownloadReference(account: account, id: episode, part: transcript ? .transcript : .lesson)
        guard tasks[pair.key] == nil else { return }
        enqueue(try PodcastAPI.request(config: config, suffix: "/\(episode)/\(pair.part.suffix)"), pair: pair)
    }
    private func enqueue(_ request: URLRequest, pair: PodcastDownloadReference, delay: TimeInterval = 0) {
        var request = request
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let task = session.downloadTask(with: request)
        task.taskDescription = pair.description
        if delay > 0 { task.earliestBeginDate = Date().addingTimeInterval(delay) }
        tasks[pair.key] = task; epochs.record(task.taskIdentifier); task.resume()
    }
    func cancelAll() {
        // Fence both registered and still-restoring tasks before yielding. A→B→A must not
        // let a delayed cancellation erase or cancel the newly started A transfer.
        var accounts = Set(tasks.values.compactMap { Self.pair($0.taskDescription)?.account })
        if let account = PodcastStore.shared.account { accounts.insert(account) }
        epochs.retire(accounts: accounts)
        for task in tasks.values { task.cancel() }; tasks = [:]; progressThrottles = [:]
        Task {
            for task in await session.allTasks {
                if let pair = Self.pair(task.taskDescription), isRetired(task, account: pair.account) { task.cancel() }
            }
        }
    }
    private func isRetired(_ task: URLSessionTask, account: String) -> Bool {
        epochs.isRetired(task.taskIdentifier, account: account)
    }
    private func accepts(_ task: URLSessionTask, pair: PodcastDownloadReference) -> Bool {
        epochs.accepts(task.taskIdentifier, account: pair.account, currentTaskID: tasks[pair.key]?.taskIdentifier)
    }
    private func finishTracking(_ task: URLSessionTask, pair: PodcastDownloadReference) {
        tasks[pair.key] = nil
        progressThrottles[task.taskIdentifier] = nil
        epochs.record(task.taskIdentifier)
    }
    static func pair(_ description: String?) -> PodcastDownloadReference? { PodcastDownloadReference(description) }
    func progress(task: URLSessionTask, written: Int64, total: Int64) {
        guard let pair = Self.pair(task.taskDescription), accepts(task, pair: pair) else { return }
        if written > pair.part.maximumBytes || total > pair.part.maximumBytes {
            forcedErrors[task.taskIdentifier] = pair.part == .transcript ? "The podcast transcript exceeds the 2 MB download limit." : "The recording exceeds the 512 MB download limit."
            task.cancel(); return
        }
        let throttle = progressThrottles[task.taskIdentifier] ?? HttpSyncProgressThrottle()
        progressThrottles[task.taskIdentifier] = throttle
        guard throttle.shouldPublish(.init(key: pair.description, uploading: false, completed: written, total: total)) else { return }
        PodcastStore.shared.downloadProgress(account: pair.account, id: pair.id, fraction: pair.part == .transcript ? 0 : (total > 0 ? min(1, Double(written) / Double(total)) : 0), transcript: pair.part.isTranscript)
    }
    func completed(task: URLSessionTask, staged: URL) {
        defer { try? FileManager.default.removeItem(at: staged) }
        guard let pair = Self.pair(task.taskDescription), accepts(task, pair: pair) else { return }
        finishTracking(task, pair: pair)
        let store = PodcastStore.shared
        guard store.enabled, store.account == pair.account else { return }
        do {
            guard let response = task.response as? HTTPURLResponse else { throw PodcastHTTPError(status: 0, message: "The download returned no response.") }
            // Background URLSession follows redirects without invoking the redirect delegate.
            // Never publish audio received from a different endpoint as this lesson.
            guard let receivedURL = response.url, let requestedURL = task.originalRequest?.url,
                  receivedURL.absoluteString == requestedURL.absoluteString else { throw PodcastHTTPError(status: 0, message: "The lesson download was redirected. Ask the administrator to check the podcast server.") }
            if [429, 503].contains(response.statusCode), retry(task, pair: pair) { return }
            guard (200..<300).contains(response.statusCode) else {
                if [401, 403].contains(response.statusCode) { store.invalidate() }
                throw PodcastHTTPError(status: response.statusCode, message: "Download failed: HTTP \(response.statusCode).")
            }
            let size = try staged.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            try pair.part.validate(response: response, fileSize: Int64(size))
            if pair.part == .transcript {
                // This persists a validated checkpoint across URLSession's background relaunch.
                // Invalid or oversized text can never trigger the much larger audio request.
                try store.files.stageTranscript(staged, account: pair.account, id: pair.id)
                guard var request = task.originalRequest, let url = request.url else { throw URLError(.badURL) }
                request.url = url.deletingLastPathComponent().appendingPathComponent("original")
                enqueue(request, pair: PodcastDownloadReference(account: pair.account, id: pair.id, part: .original))
                return
            }
            try store.files.installAudio(staged, account: pair.account, id: pair.id, original: pair.part == .original)
            store.downloadFinished(account: pair.account, id: pair.id, failure: nil, transcript: pair.part.isTranscript)
        } catch { store.downloadFinished(account: pair.account, id: pair.id, failure: PodcastRules.failureMessage(error), transcript: pair.part.isTranscript) }
    }
    func failed(task: URLSessionTask, error: Error) {
        let forced = forcedErrors.removeValue(forKey: task.taskIdentifier)
        guard let pair = Self.pair(task.taskDescription), accepts(task, pair: pair) else { return }
        finishTracking(task, pair: pair)
        if forced == nil, (error as? URLError)?.code != .cancelled, retry(task, pair: pair) { return }
        let reason = forced ?? PodcastRules.failureMessage(error)
        PodcastStore.shared.downloadFinished(account: pair.account, id: pair.id, failure: reason, transcript: pair.part.isTranscript)
    }
    private func retry(_ task: URLSessionTask, pair: PodcastDownloadReference) -> Bool {
        guard pair.attempt < 2, let request = task.originalRequest, PodcastStore.shared.enabled,
              PodcastStore.shared.account == pair.account else { return false }
        var retried = pair; retried.attempt += 1
        enqueue(request, pair: retried, delay: Double(retried.attempt * 30))
        PodcastStore.shared.downloadProgress(account: pair.account, id: pair.id, fraction: 0, transcript: pair.part.isTranscript)
        return true
    }

}

nonisolated private final class PodcastDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("podcast-\(UUID().uuidString).mp3")
        do {
            try FileManager.default.moveItem(at: location, to: staged)
            MainActor.assumeIsolated { PodcastDownloads.shared.completed(task: downloadTask, staged: staged) }
        } catch { MainActor.assumeIsolated { PodcastDownloads.shared.failed(task: downloadTask, error: error) } }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        MainActor.assumeIsolated { PodcastDownloads.shared.progress(task: downloadTask, written: totalBytesWritten, total: totalBytesExpectedToWrite) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { MainActor.assumeIsolated { PodcastDownloads.shared.failed(task: task, error: error) } }
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated { let completion = PodcastDownloads.shared.backgroundCompletion; PodcastDownloads.shared.backgroundCompletion = nil; completion?() }
    }
}
