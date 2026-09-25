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
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()
    private var tasks: [String: URLSessionTask] = [:]
    private var forcedErrors: [Int: String] = [:]
    var backgroundCompletion: (() -> Void)?

    func restore() {
        _ = session
        Task {
            for task in await session.allTasks {
                guard let description = task.taskDescription, let pair = Self.pair(description) else { task.cancel(); continue }
                guard PodcastStore.shared.enabled, PodcastStore.shared.account == pair.account else {
                    // A cold start may still be restoring its validated account marker.
                    if PodcastStore.shared.configID != pair.account || PodcastStore.shared.files.validatedAccount != pair.account { task.cancel() }
                    continue
                }
                tasks[description] = task
                PodcastStore.shared.downloadProgress(account: pair.account, id: pair.id, fraction: 0)
            }
        }
    }
    func start(episode: String, account: String, config: HttpSyncConfig) throws {
        let key = account + "|" + episode
        guard tasks[key] == nil else { return }
        let task = session.downloadTask(with: try PodcastAPI.request(config: config, suffix: "/\(episode)/audio"))
        task.taskDescription = key
        tasks[key] = task; task.resume()
    }
    func cancelAll() {
        for task in tasks.values { task.cancel() }; tasks = [:]
        Task { for task in await session.allTasks { task.cancel() } }
    }
    static func pair(_ description: String?) -> (account: String, id: String)? {
        let parts = (description ?? "").split(separator: "|").map(String.init)
        guard parts.count == 2, PodcastRules.validID(parts[0]), PodcastRules.validID(parts[1]) else { return nil }
        return (parts[0], parts[1])
    }
    func progress(task: URLSessionTask, written: Int64, total: Int64) {
        guard let pair = Self.pair(task.taskDescription) else { return }
        if written > 512 * 1024 * 1024 || total > 512 * 1024 * 1024 {
            forcedErrors[task.taskIdentifier] = "The lesson exceeds the 512 MB download limit."
            task.cancel(); return
        }
        PodcastStore.shared.downloadProgress(account: pair.account, id: pair.id, fraction: total > 0 ? min(1, Double(written) / Double(total)) : 0)
    }
    func completed(task: URLSessionTask, staged: URL) {
        defer { try? FileManager.default.removeItem(at: staged) }
        guard let pair = Self.pair(task.taskDescription) else { return }
        tasks[task.taskDescription ?? ""] = nil
        let store = PodcastStore.shared
        guard store.enabled, store.account == pair.account else { return }
        do {
            guard let response = task.response as? HTTPURLResponse else { throw PodcastHTTPError(status: 0, message: "The download returned no response.") }
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
        } catch { store.downloadFinished(account: pair.account, id: pair.id, failure: PodcastRules.display(error.localizedDescription)) }
    }
    func failed(task: URLSessionTask, error: Error) {
        guard let pair = Self.pair(task.taskDescription) else { return }
        tasks[task.taskDescription ?? ""] = nil
        let reason = forcedErrors.removeValue(forKey: task.taskIdentifier) ?? PodcastRules.display(error.localizedDescription) ?? "Download failed."
        PodcastStore.shared.downloadFinished(account: pair.account, id: pair.id, failure: reason)
    }
}

nonisolated private final class PodcastDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("podcast-\(UUID().uuidString).mp3")
        do {
            try FileManager.default.moveItem(at: location, to: staged)
            Task { @MainActor in PodcastDownloads.shared.completed(task: downloadTask, staged: staged) }
        } catch { Task { @MainActor in PodcastDownloads.shared.failed(task: downloadTask, error: error) } }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in PodcastDownloads.shared.progress(task: downloadTask, written: totalBytesWritten, total: totalBytesExpectedToWrite) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { Task { @MainActor in PodcastDownloads.shared.failed(task: task, error: error) } }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in let completion = PodcastDownloads.shared.backgroundCompletion; PodcastDownloads.shared.backgroundCompletion = nil; completion?() }
    }
}
