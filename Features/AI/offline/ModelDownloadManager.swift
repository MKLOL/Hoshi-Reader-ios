//
//  ModelDownloadManager.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Downloads on-device translation GGUF models with HTTP Range RESUME + live progress + cancel.
//  Ported from Android `features/ai/offline/OfflineLlmManager.runDownload` / `ModelDownloadService`
//  (iOS has no foreground-service equivalent, so this is a plain URLSession streaming download
//  driven from the app).
//
//  Files land in Application Support/Models/<fileName>; an in-progress download streams to a
//  `<fileName>.part` companion that is KEPT across interruptions so a later `download(_:)` resumes
//  from where it left off (HTTP `Range`), and only a fully-streamed file is given the real name.
//  The finished file is excluded from iCloud/iTunes backup (multi-GB, re-downloadable).
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

    /// In-flight download tasks, keyed by model id, so `cancel(_:)` can stop a specific download.
    private var tasks: [String: Task<Void, Never>] = [:]

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
    func download(_ model: LlmModel) {
        guard !isDownloaded(model) else { return }
        if case .downloading = downloadState(for: model) { return }
        if isAnyDownloading { return }

        let resumeFrom = (partURL(for: model).flatMap(fileSize)) ?? 0
        states[model.id] = .downloading(downloadedBytes: resumeFrom, totalBytes: model.approxSizeBytes)

        let task = Task { [weak self] in
            await self?.runDownload(model)
            return ()
        }
        tasks[model.id] = task
    }

    /// Stops the in-flight download of `model`. The `.part` file is intentionally KEPT so the next
    /// `download(_:)` resumes rather than restarting.
    func cancel(_ model: LlmModel) {
        tasks[model.id]?.cancel()
        tasks[model.id] = nil
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

    // MARK: - Streaming worker

    /// Streams `model` to its `.part` file with HTTP Range resume, reports throttled progress via
    /// `states`, then atomically moves the finished file to its real name. On error or cancellation
    /// the `.part` file is kept so a later attempt resumes.
    private func runDownload(_ model: LlmModel) async {
        guard let partURL = partURL(for: model), let finalURL = fileURL(for: model) else {
            states[model.id] = .failed(message: "On-device storage is unavailable.")
            return
        }
        do {
            try await stream(model, to: partURL)
            if FileManager.default.fileExists(atPath: finalURL.path(percentEncoded: false)) {
                try? FileManager.default.removeItem(at: finalURL)
            }
            try FileManager.default.moveItem(at: partURL, to: finalURL)
            var excluded = finalURL
            try? excluded.excludeFromBackup()
            states[model.id] = .completed
            downloadedRevision += 1
        } catch is CancellationException {
            // Stopped by the user: keep the .part file so the next start resumes.
            states[model.id] = .idle
        } catch {
            // Network/IO failure: keep the .part file so Retry resumes from here.
            states[model.id] = .failed(message: friendlyMessage(error))
        }
        tasks[model.id] = nil
    }

    /// HTTP Range streaming: 206 → append to the partial file; 200 → server ignored the range, so
    /// restart from scratch; 416 → the partial file already holds everything, so it's complete.
    /// Emits throttled progress and honors cancellation between byte chunks.
    private func stream(_ model: LlmModel, to partURL: URL) async throws {
        let existing = fileSize(partURL) ?? 0

        var request = URLRequest(url: model.downloadURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 60
        if existing > 0 {
            request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = .infinity
        config.waitsForConnectivity = true
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DownloadError("Download failed (no HTTP response).")
        }

        // The partial file is already the whole thing — nothing left to fetch.
        if existing > 0, http.statusCode == 416 {
            states[model.id] = .downloading(downloadedBytes: existing, totalBytes: existing)
            return
        }
        let resuming = http.statusCode == 206
        guard http.statusCode == 200 || resuming else {
            throw DownloadError("Download failed (HTTP \(http.statusCode)).")
        }

        // Content-Length is the *remaining* bytes on a 206, the full size on a 200, or absent (-1);
        // fall back to the catalog's advertised size for a total.
        let reported = http.expectedContentLength
        let totalBytes: Int64
        if resuming, reported > 0 {
            totalBytes = existing + reported
        } else if reported > 0 {
            totalBytes = reported
        } else {
            totalBytes = model.approxSizeBytes
        }

        // Append when resuming (206); overwrite when the server ignored the range (200).
        if !resuming {
            try? FileManager.default.removeItem(at: partURL)
        }
        if !FileManager.default.fileExists(atPath: partURL.path(percentEncoded: false)) {
            FileManager.default.createFile(atPath: partURL.path(percentEncoded: false), contents: nil)
        }
        let handle = try FileHandle(forWritingTo: partURL)
        defer { try? handle.close() }
        if resuming {
            try handle.seekToEnd()
        } else {
            try handle.truncate(atOffset: 0)
        }

        var downloaded = resuming ? existing : 0
        var buffer = Data()
        buffer.reserveCapacity(1 << 18)
        var lastEmit = Date()
        var lastEmitBytes = downloaded
        states[model.id] = .downloading(downloadedBytes: downloaded, totalBytes: totalBytes)

        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            if buffer.count >= (1 << 18) { // flush every ~256 KB
                try handle.write(contentsOf: buffer)
                downloaded += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)

                let now = Date()
                if downloaded - lastEmitBytes >= (1 << 20) || now.timeIntervalSince(lastEmit) >= 0.25 {
                    states[model.id] = .downloading(downloadedBytes: downloaded, totalBytes: totalBytes)
                    lastEmit = now
                    lastEmitBytes = downloaded
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            downloaded += Int64(buffer.count)
        }
        try handle.synchronize()
        states[model.id] = .downloading(downloadedBytes: downloaded, totalBytes: max(totalBytes, downloaded))
    }

    private func friendlyMessage(_ error: Error) -> String {
        let message = (error as NSError).localizedDescription
        return message.isEmpty ? "Download failed. Check your connection and retry." : message
    }
}

/// A user-facing download error (HTTP / IO). Distinct from `CancellationException`.
private struct DownloadError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Bridges Swift's `CancellationError` to a catchable type alias used in the worker.
private typealias CancellationException = CancellationError
