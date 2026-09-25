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
                let key = pair.account + "|" + pair.id
                if let current = tasks[key], current.taskIdentifier != task.taskIdentifier { task.cancel(); continue }
                tasks[key] = task
                epochs.record(task.taskIdentifier)
                let fraction = task.countOfBytesExpectedToReceive > 0 ? Double(task.countOfBytesReceived) / Double(task.countOfBytesExpectedToReceive) : 0
                PodcastStore.shared.downloadProgress(account: pair.account, id: pair.id, fraction: min(1, max(0, fraction)))
            }
        }
    }
    func start(episode: String, account: String, config: HttpSyncConfig) throws {
        let key = account + "|" + episode
        guard tasks[key] == nil else { return }
        let task = session.downloadTask(with: try PodcastAPI.request(config: config, suffix: "/\(episode)/audio"))
        task.taskDescription = key
        tasks[key] = task; epochs.record(task.taskIdentifier); task.resume()
    }
    func cancelAll() {
        // Fence both registered and still-restoring tasks before yielding. A→B→A must not
        // let a delayed cancellation erase or cancel the newly started A transfer.
        var accounts = Set(tasks.values.compactMap { Self.pair($0.taskDescription)?.account })
        if let account = PodcastStore.shared.account { accounts.insert(account) }
        epochs.retire(accounts: accounts)
        for task in tasks.values { task.cancel() }; tasks = [:]
        Task {
            for task in await session.allTasks {
                if let pair = Self.pair(task.taskDescription), isRetired(task, account: pair.account) { task.cancel() }
            }
        }
    }
    private func isRetired(_ task: URLSessionTask, account: String) -> Bool {
        epochs.isRetired(task.taskIdentifier, account: account)
    }
    private func accepts(_ task: URLSessionTask, pair: (account: String, id: String)) -> Bool {
        epochs.accepts(task.taskIdentifier, account: pair.account, currentTaskID: tasks[pair.account + "|" + pair.id]?.taskIdentifier)
    }
    private func finishTracking(_ task: URLSessionTask, pair: (account: String, id: String)) {
        tasks[pair.account + "|" + pair.id] = nil
        epochs.record(task.taskIdentifier)
    }
    static func pair(_ description: String?) -> (account: String, id: String)? {
        let parts = (description ?? "").split(separator: "|").map(String.init)
        guard (2...3).contains(parts.count), PodcastRules.validID(parts[0]), PodcastRules.validID(parts[1]) else { return nil }
        if parts.count == 3, !(Int(parts[2]).map { (1...2).contains($0) } ?? false) { return nil }
        return (parts[0], parts[1])
    }
    func progress(task: URLSessionTask, written: Int64, total: Int64) {
        guard let pair = Self.pair(task.taskDescription), accepts(task, pair: pair) else { return }
        if written > 512 * 1024 * 1024 || total > 512 * 1024 * 1024 {
            forcedErrors[task.taskIdentifier] = "The lesson exceeds the 512 MB download limit."
            task.cancel(); return
        }
        PodcastStore.shared.downloadProgress(account: pair.account, id: pair.id, fraction: total > 0 ? min(1, Double(written) / Double(total)) : 0)
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
            guard response.mimeType?.lowercased() == "audio/mpeg" else { throw PodcastHTTPError(status: 0, message: "The server did not return an MP3 lesson.") }
            let size = try staged.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= 512 * 1024 * 1024 else { throw PodcastHTTPError(status: 0, message: "The downloaded lesson is empty or too large.") }
            guard response.expectedContentLength < 0 || response.expectedContentLength == size else { throw PodcastHTTPError(status: 0, message: "The lesson download is incomplete.") }
            guard let destination = store.files.audio(account: pair.account, id: pair.id) else { return }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged) }
            else { try FileManager.default.moveItem(at: staged, to: destination) }
            store.downloadFinished(account: pair.account, id: pair.id, failure: nil)
        } catch { store.downloadFinished(account: pair.account, id: pair.id, failure: PodcastRules.failureMessage(error)) }
    }
    func failed(task: URLSessionTask, error: Error) {
        let forced = forcedErrors.removeValue(forKey: task.taskIdentifier)
        guard let pair = Self.pair(task.taskDescription), accepts(task, pair: pair) else { return }
        finishTracking(task, pair: pair)
        if forced == nil, (error as? URLError)?.code != .cancelled, retry(task, pair: pair) { return }
        let reason = forced ?? PodcastRules.failureMessage(error)
        PodcastStore.shared.downloadFinished(account: pair.account, id: pair.id, failure: reason)
    }
    private func retry(_ task: URLSessionTask, pair: (account: String, id: String)) -> Bool {
        let parts = (task.taskDescription ?? "").split(separator: "|")
        let attempt = parts.count == 3 ? (Int(parts[2]) ?? 0) : 0
        guard attempt < 2, let request = task.originalRequest, PodcastStore.shared.enabled,
              PodcastStore.shared.account == pair.account else { return false }
        let retry = session.downloadTask(with: request)
        retry.taskDescription = pair.account + "|" + pair.id + "|" + String(attempt + 1)
        retry.earliestBeginDate = Date().addingTimeInterval(Double((attempt + 1) * 30))
        tasks[pair.account + "|" + pair.id] = retry
        epochs.record(retry.taskIdentifier)
        retry.resume()
        PodcastStore.shared.downloadProgress(account: pair.account, id: pair.id, fraction: 0)
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
