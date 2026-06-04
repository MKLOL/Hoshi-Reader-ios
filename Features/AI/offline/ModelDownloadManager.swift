//
//  ModelDownloadManager.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Downloads on-device translation GGUF models with HTTP Range RESUME + live progress + cancel,
//  using a BACKGROUND `URLSession` so a multi-GB transfer keeps running while the app is backgrounded
//  or suspended (the iOS equivalent of Android's `ModelDownloadService` foreground service). The
//  system performs the transfer out of process and reports back via a `URLSessionDownloadDelegate`;
//  on completion-while-suspended it relaunches the app and calls
//  `application(_:handleEventsForBackgroundURLSession:completionHandler:)` (wired in
//  `App/HoshiReader.swift` → `setBackgroundCompletionHandler`).
//
//  Files land in Application Support/Models/<fileName>; an in-progress download accumulates in a
//  `<fileName>.part` companion that is KEPT across interruptions so a later `download(_:)` resumes
//  from where it left off (HTTP `Range`: the delegate appends a 206 body to it, or replaces it on a
//  200), and only a fully-downloaded file is given the real name. Both the `.part` companion and the
//  finished file are excluded from iCloud/iTunes backup (multi-GB, re-downloadable).
//
//  Because a background session is process-global and persistent, there is exactly ONE session for
//  the whole app (a fixed identifier); the system reattaches outstanding tasks to it after a relaunch.
//  Each download task is tagged with its model id via `taskDescription`, so the delegate can map a
//  reattached task back to a model even with no in-memory bookkeeping.
//

import Foundation

/// Progress / outcome of a model download, keyed per model id in `ModelDownloadManager`.
nonisolated enum ModelDownloadState: Equatable {
    case idle
    case downloading(downloadedBytes: Int64, totalBytes: Int64)
    case completed
    case failed(message: String)

    /// Download fraction 0...1, or `nil` when not actively downloading.
    var fraction: Double? {
        guard case let .downloading(downloaded, total) = self, total > 0 else { return nil }
        return min(1, max(0, Double(downloaded) / Double(total)))
    }
}

@Observable
@MainActor
final class ModelDownloadManager {
    static let shared = ModelDownloadManager()

    /// A downloaded file must be at least this fraction of its advertised size to count as complete
    /// (guards against a truncated/partial file being mistaken for done). Matches Android.
    private static let minCompleteFraction = 0.90
    // `fileprivate` (not `private`) so the file-local `DownloadDelegate` can resolve the same
    // `.part` path when reattaching a task the system kept across a relaunch.
    fileprivate nonisolated static let modelsDirName = "Models"
    fileprivate nonisolated static let partSuffix = ".part"

    /// Identifier of the single, process-global background session. Stable so the system can
    /// reattach outstanding tasks to a freshly-created session after the app is relaunched.
    private static let sessionIdentifier = "de.manhhao.hoshi.modeldownload.background"

    /// Per-model-id download state. Models not present are implicitly `.idle`.
    private(set) var states: [String: ModelDownloadState] = [:]

    /// Bumped whenever the set of on-disk models changes (completed download / delete), so SwiftUI
    /// views that compute `isDownloaded` re-render even when `states` lands back on `.idle`.
    private(set) var downloadedRevision = 0

    /// Model ids with a live background task, so `cancel(_:)`/`isAnyDownloading` know what's running.
    /// Survives only in-memory; on relaunch it is rebuilt from the session's outstanding tasks.
    private var activeModelIds: Set<String> = []

    /// The system's stored completion handler from
    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`, called once all
    /// background events for the session have been delivered (see `urlSessionDidFinishEvents`).
    private var backgroundCompletionHandler: (() -> Void)?

    /// The single delegate driving the background session. It owns per-task append/replace state and
    /// calls back here (main actor) with throttled progress + terminal completion.
    private let delegate = DownloadDelegate()

    /// The single background `URLSession`. Created lazily so the delegate's callbacks are wired first.
    @ObservationIgnored
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.timeoutIntervalForRequest = 60
        // Multi-GB transfer: never give up on the whole resource (only per-request timeouts apply).
        config.timeoutIntervalForResource = .infinity
        config.waitsForConnectivity = true
        // Don't let iOS defer the transfer for "discretionary" power/network reasons — the user
        // explicitly tapped Download and is watching the progress bar.
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()

    private init() {
        delegate.manager = self
        // Adopt any tasks the system reattached after a relaunch (e.g. a download that finished while
        // the app was suspended, or one still in flight). Touching `session` recreates it under the
        // shared identifier, which is what binds those outstanding tasks back to our delegate.
        reattachOutstandingTasks()
    }

    // MARK: - Paths

    /// The directory holding downloaded `.gguf` files (created on demand).
    private func modelsDirectory() throws -> URL {
        let base = try BookStorage.getAppDirectory().appendingPathComponent(Self.modelsDirName)
        if !FileManager.default.fileExists(atPath: base.path(percentEncoded: false)) {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        }
        return base
    }

    /// Final on-disk URL for `model` (whether or not it exists yet), or `nil` if the app dir is
    /// unavailable.
    func fileURL(for model: LlmModel) -> URL? {
        try? modelsDirectory().appendingPathComponent(model.fileName)
    }

    private func partURL(for model: LlmModel) -> URL? {
        try? modelsDirectory().appendingPathComponent(model.fileName + Self.partSuffix)
    }

    // MARK: - Disk state

    /// Whether `model` is fully downloaded: the final file exists and is at least
    /// `minCompleteFraction` of its advertised size.
    func isDownloaded(_ model: LlmModel) -> Bool {
        guard let url = fileURL(for: model),
              let size = fileSize(url) else { return false }
        return size >= Int64(Double(model.approxSizeBytes) * Self.minCompleteFraction)
    }

    /// All catalog model ids currently downloaded on this device.
    func downloadedModelIds() -> [String] {
        LlmModelCatalog.all.filter { isDownloaded($0) }.map(\.id)
    }

    /// Total bytes used by all downloaded models (final files only; not `.part` companions).
    func totalStorageBytes() -> Int64 {
        LlmModelCatalog.all.reduce(into: Int64(0)) { sum, model in
            if isDownloaded(model), let url = fileURL(for: model), let size = fileSize(url) {
                sum += size
            }
        }
    }

    func downloadState(for model: LlmModel) -> ModelDownloadState {
        states[model.id] ?? .idle
    }

    /// True if any model is currently downloading (only one is allowed at a time on-device).
    var isAnyDownloading: Bool {
        states.values.contains { if case .downloading = $0 { return true } else { return false } }
    }

    private func fileSize(_ url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)),
              let size = attrs[.size] as? Int64 else { return nil }
        return size > 0 ? size : nil
    }

    // MARK: - Download

    /// Starts (or resumes) downloading `model` on the background session. No-op if it is already
    /// complete or already in flight, or if another model is downloading (one at a time).
    ///
    /// HTTP `Range` resume is preserved by sending `bytes=<existing>-` for any `.part` already on
    /// disk; the system performs the transfer out of process and hands the body to the delegate's
    /// `didFinishDownloadingTo`, which appends the 206 body to `.part` (or replaces it on a 200),
    /// then this manager atomically finalizes `.part` → final.
    func download(_ model: LlmModel) {
        guard !isDownloaded(model) else { return }
        if case .downloading = downloadState(for: model) { return }
        if isAnyDownloading { return }

        guard let partURL = partURL(for: model) else {
            states[model.id] = .failed(message: "On-device storage is unavailable.")
            return
        }

        let existing = fileSize(partURL) ?? 0
        states[model.id] = .downloading(downloadedBytes: existing, totalBytes: model.approxSizeBytes)
        activeModelIds.insert(model.id)

        var request = URLRequest(url: model.downloadURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 60
        if existing > 0 {
            request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
        }

        // Register the per-task append/replace context the delegate needs, then start the task. The
        // task is tagged with the model id so the delegate (and a post-relaunch reattach) can map it
        // back even with no other in-memory bookkeeping.
        delegate.beginTask(modelId: model.id, partURL: partURL, existingBytes: existing,
                           fallbackTotal: model.approxSizeBytes)
        let task = session.downloadTask(with: request)
        task.taskDescription = model.id
        task.resume()
    }

    /// Stops the in-flight download of `model`. The `.part` file is intentionally KEPT so the next
    /// `download(_:)` resumes rather than restarting.
    func cancel(_ model: LlmModel) {
        let modelId = model.id
        activeModelIds.remove(modelId)
        delegate.dropTask(modelId: modelId)
        session.getTasksWithCompletionHandler { _, _, downloadTasks in
            for task in downloadTasks where task.taskDescription == modelId {
                task.cancel()
            }
        }
        states[modelId] = .idle
    }

    /// Deletes `model` from disk (both the final file and any leftover `.part`). If the model is the
    /// one currently loaded for inference it is unloaded first so the file handle is released.
    func delete(_ model: LlmModel) {
        cancel(model)
        if OfflineLlmManager.shared.loadedModelId == model.id {
            OfflineLlmManager.shared.unload()
        }
        if let url = fileURL(for: model) {
            try? FileManager.default.removeItem(at: url)
        }
        if let part = partURL(for: model) {
            try? FileManager.default.removeItem(at: part)
        }
        states[model.id] = .idle
        downloadedRevision += 1
    }

    // MARK: - Background session lifecycle (called from the app delegate)

    /// Stores the system's completion handler from
    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`. We call it once all
    /// of the session's pending background events have been delivered (`urlSessionDidFinishEvents`).
    /// Touching `session` here also recreates it under the shared identifier so the system reattaches
    /// the outstanding tasks to our delegate.
    func setBackgroundCompletionHandler(_ handler: @escaping () -> Void, forIdentifier identifier: String) {
        guard identifier == Self.sessionIdentifier else { return }
        backgroundCompletionHandler = handler
        _ = session
    }

    /// Reattaches in-memory state to whatever tasks the system kept alive across a relaunch, so the
    /// settings UI shows the right "downloading" rows without the user re-tapping Download.
    private func reattachOutstandingTasks() {
        session.getTasksWithCompletionHandler { [weak self] _, _, downloadTasks in
            let ids = downloadTasks.compactMap(\.taskDescription)
            Task { @MainActor in
                guard let self else { return }
                for id in ids {
                    guard let model = LlmModelCatalog.byId(id),
                          let partURL = self.partURL(for: model) else { continue }
                    self.activeModelIds.insert(id)
                    let existing = self.fileSize(partURL) ?? 0
                    // Rebuild the delegate context (the `.part` baseline is its current size, since
                    // the file is untouched mid-transfer until didFinishDownloadingTo).
                    self.delegate.beginTask(modelId: id, partURL: partURL, existingBytes: existing,
                                            fallbackTotal: model.approxSizeBytes)
                    if case .downloading = self.downloadState(for: model) {} else {
                        self.states[id] = .downloading(downloadedBytes: existing,
                                                       totalBytes: model.approxSizeBytes)
                    }
                }
            }
        }
    }

    // MARK: - Delegate callbacks (main actor)

    /// Throttled progress from the delegate. Ignored once the download has been cancelled/removed.
    fileprivate func handleProgress(modelId: String, downloaded: Int64, total: Int64) {
        guard activeModelIds.contains(modelId) else { return }
        states[modelId] = .downloading(downloadedBytes: downloaded, totalBytes: max(total, downloaded))
    }

    /// Terminal handler: the delegate has appended/replaced the `.part` file (or reported a
    /// failure). On success, atomically move `.part` → final and mark complete; on cancel keep
    /// `.part`; on failure keep `.part` and surface the message. The delegate pre-reduces the outcome
    /// to a `Sendable` value (no `Error` existential crosses the actor boundary).
    fileprivate func finishDownload(modelId: String, outcome: TerminalOutcome) {
        activeModelIds.remove(modelId)
        delegate.dropTask(modelId: modelId)
        guard let model = LlmModelCatalog.byId(modelId) else { return }
        guard let finalURL = fileURL(for: model) else {
            states[modelId] = .failed(message: "On-device storage is unavailable.")
            return
        }
        switch outcome {
        case let .success(bytesOnDisk, expectedTotal):
            // Don't finalize a truncated body as "complete": if the server gave a real total and we
            // received fewer bytes, keep the `.part` for resume and fail loudly.
            if expectedTotal > 0, bytesOnDisk < expectedTotal {
                states[modelId] = .failed(message: "Download incomplete (got \(bytesOnDisk) of "
                    + "\(expectedTotal) bytes). Retry to resume.")
                return
            }
            guard let partURL = partURL(for: model) else {
                states[modelId] = .failed(message: "On-device storage is unavailable.")
                return
            }
            do {
                if FileManager.default.fileExists(atPath: finalURL.path(percentEncoded: false)) {
                    try? FileManager.default.removeItem(at: finalURL)
                }
                try FileManager.default.moveItem(at: partURL, to: finalURL)
                var excluded = finalURL
                try? excluded.excludeFromBackup()
                states[modelId] = .completed
                downloadedRevision += 1
            } catch {
                states[modelId] = .failed(message: friendlyMessage(error))
            }
        case .cancelled:
            // Stopped by the user → idle; `.part` is kept so the next download resumes.
            states[modelId] = .idle
        case let .failed(message):
            // Network/IO/HTTP failure → keep `.part`, surface the message so Retry resumes.
            states[modelId] = .failed(message: message)
        }
    }

    /// All of the background session's queued events have been delivered: invoke (and clear) the
    /// system's completion handler so iOS knows it can take a fresh UI snapshot / re-suspend the app.
    fileprivate func didFinishBackgroundEvents() {
        let handler = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        handler?()
    }

    /// Maps a thrown error (only the local finalize-move can reach here) to a user-facing message.
    private func friendlyMessage(_ error: Error) -> String {
        let message = (error as NSError).localizedDescription
        return message.isEmpty ? "Download failed. Check your connection and retry." : message
    }
}

/// The delegate's terminal verdict for one download, pre-reduced to a fully `Sendable` value so no
/// `Error` existential crosses the delegate-queue → main-actor boundary.
enum TerminalOutcome: Sendable {
    /// The `.part` body is in place: its byte count, plus the proven total (Content-Length / 206
    /// range total) or 0 if the server gave none. The manager finalizes `.part` → final.
    case success(bytesOnDisk: Int64, expectedTotal: Int64)
    /// Stopped by the user — keep `.part`, go idle.
    case cancelled
    /// HTTP / IO failure with a user-facing message — keep `.part`, surface the message.
    case failed(message: String)
}

// MARK: - URLSessionDownloadDelegate

/// Drives the single background `URLSession`. The system writes each response body to its own temp
/// file out of process and reports byte counts via `didWriteData`; we append/replace the model's
/// `.part` file in `didFinishDownloadingTo` honoring the 200/206/416 status, then call back into the
/// manager (on the main actor). Per-task append/replace state is keyed by model id so one delegate
/// can serve every download (and reattach tasks the system kept across a relaunch).
///
/// `@unchecked Sendable` because the per-task context map is guarded by `contextsLock` (it's touched
/// both from the manager's main actor — `beginTask`/`dropTask` — and from the session's delegate
/// queue), and `manager` is a `@MainActor` reference only ever dereferenced inside `MainActor.run`.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    /// Set once by the manager after init; only dereferenced on the main actor (via `MainActor.run`).
    weak var manager: ModelDownloadManager?

    /// Per-task append/replace context, keyed by model id.
    private struct TaskContext {
        let partURL: URL
        let existingBytes: Int64
        let fallbackTotal: Int64
        var resolvedTotal: Int64 = 0
        var expectedTotal: Int64 = 0
        var lastEmit = Date.distantPast
        var lastEmitBytes: Int64 = 0
        var finished = false
    }
    /// Guards `contexts`, which is read/written from both the main actor and the delegate queue.
    private let contextsLock = NSLock()
    private var contexts: [String: TaskContext] = [:]

    private func withContexts<T>(_ body: (inout [String: TaskContext]) -> T) -> T {
        contextsLock.lock()
        defer { contextsLock.unlock() }
        return body(&contexts)
    }

    /// Registers the context for a (re)started download of `modelId` (called from the main actor,
    /// before `resume()`). The lock makes the cross-queue write safe.
    func beginTask(modelId: String, partURL: URL, existingBytes: Int64, fallbackTotal: Int64) {
        withContexts { $0[modelId] = TaskContext(partURL: partURL, existingBytes: existingBytes,
                                                 fallbackTotal: fallbackTotal) }
    }

    /// Forgets the context for `modelId` (cancel / terminal completion). May run on either queue.
    func dropTask(modelId: String) {
        withContexts { $0[modelId] = nil }
    }

    /// Reads the current context for `modelId`, lazily rebuilding it for a task the system reattached
    /// after relaunch (the manager hadn't run `beginTask` for it). The `.part` baseline is its current
    /// size — untouched mid-transfer. The models directory is deterministic, so this resolves the
    /// `.part` URL itself without hopping to the (main-actor) manager.
    private func ensureContext(for modelId: String) -> TaskContext? {
        withContexts { contexts in
            if let existing = contexts[modelId] { return existing }
            guard let model = LlmModelCatalog.byId(modelId),
                  let partURL = Self.partURL(for: model) else { return nil }
            let existing = fileSize(partURL) ?? 0
            let context = TaskContext(partURL: partURL, existingBytes: existing,
                                      fallbackTotal: model.approxSizeBytes)
            contexts[modelId] = context
            return context
        }
    }

    /// Stores back a mutated copy of `modelId`'s context (no-op if it was dropped meanwhile).
    private func storeContext(_ context: TaskContext, for modelId: String) {
        withContexts { if $0[modelId] != nil { $0[modelId] = context } }
    }

    /// Deterministic `.part` URL for a reattached task (mirrors `ModelDownloadManager.partURL`).
    /// Lives here too so the delegate queue can resolve it without a main-actor hop. Resolves the
    /// Application Support directory directly via the (nonisolated) `FileManager` rather than the
    /// main-actor `BookStorage`, so it's callable from the delegate queue.
    private static func partURL(for model: LlmModel) -> URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return appSupport
            .appendingPathComponent(ModelDownloadManager.modelsDirName)
            .appendingPathComponent(model.fileName + ModelDownloadManager.partSuffix)
    }

    /// Whether this response means we're resuming (server honored the Range with a 206).
    private func isResuming(_ response: HTTPURLResponse?, existingBytes: Int64) -> Bool {
        existingBytes > 0 && response?.statusCode == 206
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let modelId = downloadTask.taskDescription,
              var context = ensureContext(for: modelId) else { return }
        let http = downloadTask.response as? HTTPURLResponse
        let resuming = isResuming(http, existingBytes: context.existingBytes)

        if context.resolvedTotal == 0 {
            // totalBytesExpectedToWrite is the *remaining* body the system will write (or -1).
            if totalBytesExpectedToWrite > 0 {
                let base = resuming ? context.existingBytes : 0
                context.expectedTotal = base + totalBytesExpectedToWrite
                context.resolvedTotal = context.expectedTotal
            } else {
                context.resolvedTotal = context.fallbackTotal
                context.expectedTotal = 0
            }
        }

        let base = resuming ? context.existingBytes : 0
        let downloaded = base + totalBytesWritten

        let now = Date()
        if downloaded - context.lastEmitBytes >= (1 << 20) || now.timeIntervalSince(context.lastEmit) >= 0.25 {
            context.lastEmit = now
            context.lastEmitBytes = downloaded
            let total = max(context.resolvedTotal, downloaded)
            Task { @MainActor [weak manager] in
                manager?.handleProgress(modelId: modelId, downloaded: downloaded, total: total)
            }
        }
        storeContext(context, for: modelId)
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let modelId = downloadTask.taskDescription,
              var context = ensureContext(for: modelId) else { return }
        let http = downloadTask.response as? HTTPURLResponse
        let status = http?.statusCode ?? 0

        do {
            // 416: the `.part` already holds the whole file — nothing to append, it's complete.
            if context.existingBytes > 0, status == 416 {
                finishOnce(modelId: modelId,
                           .success(bytesOnDisk: context.existingBytes,
                                    expectedTotal: context.existingBytes))
                return
            }
            guard status == 200 || status == 206 else {
                finishOnce(modelId: modelId, .failed(message: "Download failed (HTTP \(status))."))
                return
            }
            let resuming = isResuming(http, existingBytes: context.existingBytes)

            // Compute the proven total now (the response is final here even if didWriteData never
            // ran, e.g. a tiny tail).
            if let len = http?.expectedContentLength, len > 0 {
                context.expectedTotal = resuming ? context.existingBytes + len : len
            }

            let bytesOnDisk: Int64
            if resuming {
                bytesOnDisk = try appendTempToPart(location, partURL: context.partURL)
            } else {
                // 200: the server ignored the Range (or there was no `.part`) — replace wholesale.
                bytesOnDisk = try replacePartWithTemp(location, partURL: context.partURL)
            }
            storeContext(context, for: modelId)
            finishOnce(modelId: modelId,
                       .success(bytesOnDisk: bytesOnDisk, expectedTotal: context.expectedTotal))
        } catch {
            finishOnce(modelId: modelId, .failed(message: friendlyMessage(error)))
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        // didFinishDownloadingTo already resolved success; this fires for failures/cancellation.
        guard let modelId = task.taskDescription, let error else { return }
        // Map user/system cancellation to `.cancelled` (keep `.part`, go idle); everything else to a
        // user-facing failure message. Reduced to `Sendable` here so no `Error` crosses to the actor.
        if (error as NSError).code == NSURLErrorCancelled || error is CancellationError {
            finishOnce(modelId: modelId, .cancelled)
        } else {
            finishOnce(modelId: modelId, .failed(message: friendlyMessage(error)))
        }
    }

    /// Maps a thrown error to a short, user-facing message (delegate-queue side).
    private func friendlyMessage(_ error: Error) -> String {
        let message = (error as NSError).localizedDescription
        return message.isEmpty ? "Download failed. Check your connection and retry." : message
    }

    /// All queued background events for the session have been delivered — let the manager invoke the
    /// system's stored completion handler so iOS can re-suspend the app / snapshot the UI.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [weak manager] in
            manager?.didFinishBackgroundEvents()
        }
    }

    /// Appends the system's temp body to the existing `.part`, returns the new total size.
    private func appendTempToPart(_ tempURL: URL, partURL: URL) throws -> Int64 {
        if !FileManager.default.fileExists(atPath: partURL.path(percentEncoded: false)) {
            FileManager.default.createFile(atPath: partURL.path(percentEncoded: false), contents: nil)
            try? markPartExcludedFromBackup(partURL)
        }
        let writer = try FileHandle(forWritingTo: partURL)
        defer { try? writer.close() }
        try writer.seekToEnd()

        let reader = try FileHandle(forReadingFrom: tempURL)
        defer { try? reader.close() }
        let chunkSize = 1 << 22 // 4 MB
        while case let chunk = try reader.read(upToCount: chunkSize) ?? Data(), !chunk.isEmpty {
            try writer.write(contentsOf: chunk)
        }
        try writer.synchronize()
        if let offset = try? writer.offset() { return Int64(offset) }
        return fileSize(partURL) ?? 0
    }

    /// Moves the system's temp body to `.part`, replacing any existing partial; returns its size.
    private func replacePartWithTemp(_ tempURL: URL, partURL: URL) throws -> Int64 {
        if FileManager.default.fileExists(atPath: partURL.path(percentEncoded: false)) {
            try? FileManager.default.removeItem(at: partURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: partURL)
        try? markPartExcludedFromBackup(partURL)
        return fileSize(partURL) ?? 0
    }

    /// `.part` can be multi-GB and is kept across interruptions, so exclude it from iCloud/iTunes
    /// backup right away — not just the finished file. Sets the resource value directly (the
    /// `URL.excludeFromBackup()` helper is main-actor-isolated; this runs on the delegate queue).
    private func markPartExcludedFromBackup(_ partURL: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = partURL
        try url.setResourceValues(values)
    }

    private func fileSize(_ url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)),
              let size = attrs[.size] as? Int64 else { return nil }
        return size
    }

    private func finishOnce(modelId: String, _ outcome: TerminalOutcome) {
        // Mark terminal exactly once under the lock so a near-simultaneous didFinishDownloadingTo +
        // didCompleteWithError can't both report. The manager's `finishDownload` then drops the
        // context, but marking `finished` here is enough to dedupe.
        let shouldReport = withContexts { contexts -> Bool in
            guard var context = contexts[modelId], !context.finished else { return false }
            context.finished = true
            contexts[modelId] = context
            return true
        }
        guard shouldReport else { return }
        Task { @MainActor [weak manager] in
            manager?.finishDownload(modelId: modelId, outcome: outcome)
        }
    }
}
