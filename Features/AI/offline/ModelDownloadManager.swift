//
//  ModelDownloadManager.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Downloads on-device translation GGUF models with HTTP Range RESUME + live progress + cancel.
//  Ported from Android `features/ai/offline/OfflineLlmManager.runDownload` / `ModelDownloadService`
//  (iOS has no foreground-service equivalent, so this is a `URLSessionDownloadTask` driven from the
//  app via a `URLSessionDownloadDelegate` — the system streams the body in large chunks, so there's
//  no per-byte loop for a multi-GB file).
//
//  Files land in Application Support/Models/<fileName>; an in-progress download accumulates in a
//  `<fileName>.part` companion that is KEPT across interruptions so a later `download(_:)` resumes
//  from where it left off (HTTP `Range`: the delegate appends a 206 body to it, or replaces it on a
//  200), and only a fully-downloaded file is given the real name. Both the `.part` companion and the
//  finished file are excluded from iCloud/iTunes backup (multi-GB, re-downloadable).
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
    private static let modelsDirName = "Models"
    private static let partSuffix = ".part"

    /// Per-model-id download state. Models not present are implicitly `.idle`.
    private(set) var states: [String: ModelDownloadState] = [:]

    /// Bumped whenever the set of on-disk models changes (completed download / delete), so SwiftUI
    /// views that compute `isDownloaded` re-render even when `states` lands back on `.idle`.
    private(set) var downloadedRevision = 0

    /// In-flight downloads, keyed by model id, so `cancel(_:)` can stop a specific download. Holds
    /// the URLSession + its download task; the session owns the delegate (keeping it alive) and is
    /// invalidated when the download ends.
    private var downloads: [String: ActiveDownload] = [:]

    /// One in-flight `URLSessionDownloadTask` plus the session that owns its delegate.
    private struct ActiveDownload {
        let session: URLSession
        let task: URLSessionDownloadTask
    }

    private init() {}

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

    /// Starts (or resumes) downloading `model`. No-op if it is already complete or already in
    /// flight, or if another model is downloading (one at a time).
    ///
    /// Uses a `URLSessionDownloadTask` driven by a `URLSessionDownloadDelegate`: the system streams
    /// the body to its own temp file in large chunks (no per-byte loop) and reports progress via
    /// `didWriteData`. HTTP `Range` resume is preserved by sending `bytes=<existing>-` for any
    /// `.part` already on disk; the delegate appends the 206 body to it (or replaces it on a 200),
    /// then this method atomically finalizes `.part` → final.
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

        var request = URLRequest(url: model.downloadURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 60
        if existing > 0 {
            request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
        }

        // The delegate runs the chunked writes on a private queue and calls back here (main actor)
        // with throttled progress and a single terminal completion.
        let modelId = model.id
        let fallbackTotal = model.approxSizeBytes
        let delegate = DownloadDelegate(
            partURL: partURL,
            existingBytes: existing,
            fallbackTotal: fallbackTotal,
            onProgress: { [weak self] downloaded, total in
                Task { @MainActor in self?.handleProgress(modelId: modelId, downloaded: downloaded, total: total) }
            },
            onComplete: { [weak self] result in
                Task { @MainActor in self?.finishDownload(model, result: result) }
            }
        )

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = .infinity
        config.waitsForConnectivity = true
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

        let task = session.downloadTask(with: request)
        downloads[model.id] = ActiveDownload(session: session, task: task)
        task.resume()
    }

    /// Stops the in-flight download of `model`. The `.part` file is intentionally KEPT so the next
    /// `download(_:)` resumes rather than restarting.
    func cancel(_ model: LlmModel) {
        if let active = downloads[model.id] {
            active.task.cancel()
            active.session.invalidateAndCancel()
            downloads[model.id] = nil
        }
        states[model.id] = .idle
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

    // MARK: - Delegate callbacks (main actor)

    /// Throttled progress from the delegate. Ignored once the download has been cancelled/removed.
    private func handleProgress(modelId: String, downloaded: Int64, total: Int64) {
        guard downloads[modelId] != nil else { return }
        states[modelId] = .downloading(downloadedBytes: downloaded, totalBytes: max(total, downloaded))
    }

    /// Terminal handler: the delegate has appended/replaced the `.part` file (or reported a
    /// failure). On success, atomically move `.part` → final and mark complete; on cancel keep
    /// `.part`; on failure keep `.part` and surface the message.
    private func finishDownload(_ model: LlmModel, result: Result<DownloadOutcome, Error>) {
        if let active = downloads[model.id] {
            active.session.finishTasksAndInvalidate()
            downloads[model.id] = nil
        }
        guard let finalURL = fileURL(for: model) else {
            states[model.id] = .failed(message: "On-device storage is unavailable.")
            return
        }
        switch result {
        case .success(let outcome):
            // Don't finalize a truncated body as "complete": if the server gave a real total and we
            // received fewer bytes, keep the `.part` for resume and fail loudly (R1#5).
            if outcome.expectedTotal > 0, outcome.bytesOnDisk < outcome.expectedTotal {
                states[model.id] = .failed(message: friendlyMessage(
                    DownloadError("Download incomplete (got \(outcome.bytesOnDisk) of "
                        + "\(outcome.expectedTotal) bytes). Retry to resume.")
                ))
                return
            }
            guard let partURL = partURL(for: model) else {
                states[model.id] = .failed(message: "On-device storage is unavailable.")
                return
            }
            do {
                if FileManager.default.fileExists(atPath: finalURL.path(percentEncoded: false)) {
                    try? FileManager.default.removeItem(at: finalURL)
                }
                try FileManager.default.moveItem(at: partURL, to: finalURL)
                var excluded = finalURL
                try? excluded.excludeFromBackup()
                states[model.id] = .completed
                downloadedRevision += 1
            } catch {
                states[model.id] = .failed(message: friendlyMessage(error))
            }
        case .failure(let error):
            // Stopped by the user → idle; network/IO failure → failed. Either way `.part` is kept.
            if (error as NSError).code == NSURLErrorCancelled || error is CancellationError {
                states[model.id] = .idle
            } else {
                states[model.id] = .failed(message: friendlyMessage(error))
            }
        }
    }

    private func friendlyMessage(_ error: Error) -> String {
        if let download = error as? DownloadError { return download.message }
        let message = (error as NSError).localizedDescription
        return message.isEmpty ? "Download failed. Check your connection and retry." : message
    }
}

/// What the delegate handed back on success: the bytes now on disk in `.part` and the real total it
/// could prove (Content-Length / 206 range total), or 0 if the server didn't provide one.
private struct DownloadOutcome: Sendable {
    let bytesOnDisk: Int64
    let expectedTotal: Int64
}

/// A user-facing download error (HTTP / IO).
private struct DownloadError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

// MARK: - URLSessionDownloadDelegate

/// Drives one chunked `URLSessionDownloadTask`. The system writes the response body to its own temp
/// file in large chunks and reports byte counts via `didWriteData`; we append/replace the `.part`
/// file in `didFinishDownloadingTo` honoring the 200/206/416 status, then call back into the
/// manager. `@unchecked Sendable` because all mutable state is confined to the session's serial
/// delegate queue (one task per delegate).
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let partURL: URL
    private let existingBytes: Int64
    private let fallbackTotal: Int64
    private let onProgress: @Sendable (_ downloaded: Int64, _ total: Int64) -> Void
    private let onComplete: @Sendable (Result<DownloadOutcome, Error>) -> Void

    /// Resolved total once the response is seen (range total on 206, Content-Length on 200), or the
    /// catalog fallback. `expectedTotal` is the *proven* total (0 when the server didn't give one).
    private var resolvedTotal: Int64 = 0
    private var expectedTotal: Int64 = 0
    private var lastEmit = Date.distantPast
    private var lastEmitBytes: Int64 = 0
    private var finished = false

    init(partURL: URL,
         existingBytes: Int64,
         fallbackTotal: Int64,
         onProgress: @escaping @Sendable (Int64, Int64) -> Void,
         onComplete: @escaping @Sendable (Result<DownloadOutcome, Error>) -> Void) {
        self.partURL = partURL
        self.existingBytes = existingBytes
        self.fallbackTotal = fallbackTotal
        self.onProgress = onProgress
        self.onComplete = onComplete
    }

    /// Whether this response means we're resuming (server honored the Range with a 206).
    private func isResuming(_ response: HTTPURLResponse?) -> Bool {
        existingBytes > 0 && response?.statusCode == 206
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let http = downloadTask.response as? HTTPURLResponse
        let resuming = isResuming(http)

        if resolvedTotal == 0 {
            // totalBytesExpectedToWrite is the *remaining* body the system will write (or -1).
            if totalBytesExpectedToWrite > 0 {
                let base = resuming ? existingBytes : 0
                expectedTotal = base + totalBytesExpectedToWrite
                resolvedTotal = expectedTotal
            } else {
                resolvedTotal = fallbackTotal
                expectedTotal = 0
            }
        }

        let base = resuming ? existingBytes : 0
        let downloaded = base + totalBytesWritten

        let now = Date()
        if downloaded - lastEmitBytes >= (1 << 20) || now.timeIntervalSince(lastEmit) >= 0.25 {
            lastEmit = now
            lastEmitBytes = downloaded
            onProgress(downloaded, max(resolvedTotal, downloaded))
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let http = downloadTask.response as? HTTPURLResponse
        let status = http?.statusCode ?? 0

        do {
            // 416: the `.part` already holds the whole file — nothing to append, it's complete.
            if existingBytes > 0, status == 416 {
                finishOnce(.success(DownloadOutcome(bytesOnDisk: existingBytes, expectedTotal: existingBytes)))
                return
            }
            guard status == 200 || status == 206 else {
                finishOnce(.failure(DownloadError("Download failed (HTTP \(status)).")))
                return
            }
            let resuming = isResuming(http)

            // Compute the proven total now (the response is final here even if didWriteData never
            // ran, e.g. a tiny tail).
            if let len = http?.expectedContentLength, len > 0 {
                expectedTotal = resuming ? existingBytes + len : len
            }

            let bytesOnDisk: Int64
            if resuming {
                bytesOnDisk = try appendTempToPart(location)
            } else {
                // 200: the server ignored the Range (or there was no `.part`) — replace wholesale.
                bytesOnDisk = try replacePartWithTemp(location)
            }
            finishOnce(.success(DownloadOutcome(bytesOnDisk: bytesOnDisk, expectedTotal: expectedTotal)))
        } catch {
            finishOnce(.failure(error))
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        // didFinishDownloadingTo already resolved success; this fires for failures/cancellation.
        if let error { finishOnce(.failure(error)) }
    }

    /// Appends the system's temp body to the existing `.part`, returns the new total size.
    private func appendTempToPart(_ tempURL: URL) throws -> Int64 {
        if !FileManager.default.fileExists(atPath: partURL.path(percentEncoded: false)) {
            FileManager.default.createFile(atPath: partURL.path(percentEncoded: false), contents: nil)
            try? markPartExcludedFromBackup()
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
    private func replacePartWithTemp(_ tempURL: URL) throws -> Int64 {
        if FileManager.default.fileExists(atPath: partURL.path(percentEncoded: false)) {
            try? FileManager.default.removeItem(at: partURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: partURL)
        try? markPartExcludedFromBackup()
        return fileSize(partURL) ?? 0
    }

    /// `.part` can be multi-GB and is kept across interruptions, so exclude it from iCloud/iTunes
    /// backup right away (R3#4) — not just the finished file. Sets the resource value directly
    /// (the `URL.excludeFromBackup()` helper is main-actor-isolated; this runs on the delegate queue).
    private func markPartExcludedFromBackup() throws {
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

    private func finishOnce(_ result: Result<DownloadOutcome, Error>) {
        guard !finished else { return }
        finished = true
        onComplete(result)
    }
}
