import Foundation
import CryptoKit

/// Foundation owns byte transfer, validation of Range/If-Range, and opaque resume data. The
/// application owns only its destination and checkpoint lifetime, including process relaunch.
@MainActor final class HttpSyncBackgroundDownloads {
    static let shared = HttpSyncBackgroundDownloads()
    static let identifier = "com.dragosristache.hoshi.books.downloads"
    private let delegate = HttpSyncDownloadDelegate()
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: .main)
    }()
    private struct Pending {
        let task: URLSessionDownloadTask
        let continuation: CheckedContinuation<HttpSyncKvFileFetched?, Error>
        let progress: @Sendable (Int64, Int64) -> Void
        var cancelling = false
    }
    private var pending: [Int: Pending] = [:]
    var backgroundCompletion: (() -> Void)?

    func restore() { _ = session }

    func interruptedSummary(books: URL) async -> HttpSyncDownloadCache.Summary {
        let tasks = await session.allTasks
        let active = Set(tasks.compactMap { HttpSyncDownloadRecord(description: $0.taskDescription)?.destination.deletingLastPathComponent() })
        return HttpSyncDownloadCache.shared.summary(books: books, excluding: active)
    }

    func cleanDownloads(books: URL, olderThan cutoff: Date) async -> Int {
        let tasks = await session.allTasks
        let active = Set(tasks.compactMap { HttpSyncDownloadRecord(description: $0.taskDescription)?.destination.deletingLastPathComponent() })
        return HttpSyncDownloadCache.shared.clean(books: books, olderThan: cutoff, excluding: active)
    }

    func download(_ request: URLRequest, to destination: URL,
                  progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> HttpSyncKvFileFetched? {
        let record = HttpSyncDownloadRecord(request: request, destination: destination)
        let existing = await session.allTasks
        try Task.checkCancellation()
        let task: URLSessionDownloadTask
        if let running = existing.first(where: { record.matches(description: $0.taskDescription) && $0.state != .completed && $0.state != .canceling }) as? URLSessionDownloadTask {
            guard pending[running.taskIdentifier] == nil else { throw HttpSyncError("This book is already downloading.") }
            task = running
        } else {
            try record.prepare()
            if let data = record.resumeData {
                task = session.downloadTask(withResumeData: data)
            } else {
                task = session.downloadTask(with: request)
            }
            task.taskDescription = record.description
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[task.taskIdentifier] = Pending(task: task, continuation: continuation, progress: progress)
                if Task.isCancelled { cancel(taskID: task.taskIdentifier) }
                else { task.resume() }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(taskID: task.taskIdentifier) }
        }
    }

    private func cancel(taskID: Int) {
        guard var entry = pending[taskID], !entry.cancelling else { return }
        entry.cancelling = true
        pending[taskID] = entry
        entry.task.cancel { data in
            Task { @MainActor in
                guard let current = self.pending[taskID], current.cancelling else { return }
                if let record = HttpSyncDownloadRecord(description: current.task.taskDescription) {
                    try? record.saveResumeData(data)
                }
                self.finish(taskID: taskID, result: .failure(CancellationError()))
            }
        }
    }

    func received(_ task: URLSessionDownloadTask, written: Int64, total: Int64) {
        pending[task.taskIdentifier]?.progress(written, total)
    }

    func completed(_ task: URLSessionDownloadTask, staged: URL) {
        guard let record = HttpSyncDownloadRecord(description: task.taskDescription) else { return }
        guard pending[task.taskIdentifier]?.cancelling != true else { return }
        do {
            guard let response = task.response as? HTTPURLResponse else { throw HttpSyncError("Sync server returned a non-HTTP response.") }
            if response.statusCode == 404 {
                record.discard()
                finish(taskID: task.taskIdentifier, result: .success(nil)); return
            }
            guard response.url?.absoluteString == record.url else {
                throw HttpSyncError("The sync server redirected the book download to a different URL.")
            }
            guard (200...299).contains(response.statusCode) else {
                throw HttpSyncDownloadHTTPError(response: response)
            }
            let fetched = HttpSyncKvFileFetched(contentType: response.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream",
                lastModified: response.value(forHTTPHeaderField: "Last-Modified") ?? "", etag: response.value(forHTTPHeaderField: "ETag") ?? "")
            try record.install(staged: staged, fetched: fetched)
            finish(taskID: task.taskIdentifier, result: .success(fetched))
        } catch { finish(taskID: task.taskIdentifier, result: .failure(error)) }
    }

    func failed(_ task: URLSessionTask, error: Error) {
        guard pending[task.taskIdentifier]?.cancelling != true else { return }
        if let record = HttpSyncDownloadRecord(description: task.taskDescription) {
            try? record.saveResumeData((error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data)
        }
        finish(taskID: task.taskIdentifier, result: .failure(error))
    }

    private func finish(taskID: Int, result: Result<HttpSyncKvFileFetched?, Error>) {
        pending.removeValue(forKey: taskID)?.continuation.resume(with: result)
    }

    func finishedEvents() {
        let completion = backgroundCompletion
        backgroundCompletion = nil
        completion?()
        // If the process was relaunched, no old Swift continuation exists. The verified archive
        // stays in the cache and the next reconcile installs it without fetching it again.
        HttpSyncManager.shared.syncInBackground()
    }
}

/// Persisted descriptions contain an account fingerprint, never the bearer token. Foundation's
/// opaque resume data remains inside protected, backup-excluded app storage.
nonisolated struct HttpSyncDownloadRecord: Codable, Equatable {
    let url: String
    let identity: String
    let destination: URL
    init(request: URLRequest, destination: URL) {
        url = request.url!.absoluteString
        identity = SHA256.hash(data: Data((url + "\n" + (request.value(forHTTPHeaderField: "Authorization") ?? "")).utf8))
            .map { String(format: "%02x", $0) }.joined()
        self.destination = destination
    }
    init?(description: String?) {
        guard let data = description?.data(using: .utf8), let decoded = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = decoded
    }
    func matches(description: String?) -> Bool { Self(description: description) == self }
    var description: String { String(decoding: try! JSONEncoder().encode(self), as: UTF8.self) }
    var resumeURL: URL { destination.appendingPathExtension("resume") }
    var identityURL: URL { destination.appendingPathExtension("request") }
    var responseURL: URL { destination.appendingPathExtension("response") }
    private var ownsDestination: Bool { (try? String(contentsOf: identityURL, encoding: .utf8)) == identity }
    var resumeData: Data? {
        guard ownsDestination else { return nil }
        return try? Data(contentsOf: resumeURL)
    }
    func prepare() throws {
        let fm = FileManager.default
        var directory = destination.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        if !ownsDestination { removeFiles() }
        try identity.write(to: identityURL, atomically: true, encoding: .utf8)
    }
    func saveResumeData(_ data: Data?) throws {
        guard ownsDestination else { return }
        if let data { try data.write(to: resumeURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
        else { try? FileManager.default.removeItem(at: resumeURL) }
    }
    func install(staged: URL, fetched: HttpSyncKvFileFetched) throws {
        guard ownsDestination else { throw CancellationError() }
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { _ = try fm.replaceItemAt(destination, withItemAt: staged) }
        else { try fm.moveItem(at: staged, to: destination) }
        try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
        try JSONEncoder().encode(fetched).write(to: responseURL, options: .atomic)
        try? fm.removeItem(at: resumeURL)
    }
    func discard() {
        guard ownsDestination else { return }
        removeFiles()
    }
    private func removeFiles() {
        for file in [destination, resumeURL, identityURL, responseURL] { try? FileManager.default.removeItem(at: file) }
    }
}

nonisolated private final class HttpSyncDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The location is valid only until this delegate callback returns.
        MainActor.assumeIsolated { HttpSyncBackgroundDownloads.shared.completed(downloadTask, staged: location) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        MainActor.assumeIsolated { HttpSyncBackgroundDownloads.shared.received(downloadTask, written: totalBytesWritten, total: totalBytesExpectedToWrite) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { MainActor.assumeIsolated { HttpSyncBackgroundDownloads.shared.failed(task, error: error) } }
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated { HttpSyncBackgroundDownloads.shared.finishedEvents() }
    }
}


nonisolated struct HttpSyncDownloadHTTPError: Error {
    let response: HTTPURLResponse
}
