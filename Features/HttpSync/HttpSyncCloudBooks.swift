import CryptoKit
import Foundation
import ImageIO
import Observation
import UIKit

nonisolated struct HttpSyncCloudBookRecord: Codable, Identifiable, Equatable, Sendable {
    var syncId: String
    var title: String
    var sizeBytes: Int64
    var archiveSha256: String
    var contentSha256: String?
    var shelfName: String?
    var discoveredAt: String
    var coverFile: String?
    var coverArchiveSha256: String?
    var downloadRequestedAt: String?
    var downloadError: String?
    /// Static bytes and reading sidecars are installed; bookmark maps still need applying.
    var awaitingBookmarkMap: Bool = false
    var id: String { syncId }
}

/// What a Not downloaded cell shows: waiting its turn, transferring, or installing.
nonisolated enum HttpSyncCloudDownloadState: Equatable, Sendable {
    case available, queued, downloading(Double), finishing, failed(String)
    var isActive: Bool {
        switch self {
        case .queued, .downloading, .finishing: return true
        case .available, .failed: return false
        }
    }
}

/// A server catalogue, never a source of local book-map entries or library backups. A durable
/// request survives process death; a failed request waits for an explicit retry. Incoming bytes
/// are staged here until all of the book's reading sidecars have been applied.
@MainActor @Observable
final class HttpSyncCloudBooks {
    // Opens in the current account's scope: the shelf can load before the first sync or
    // foreground activation, and must already hide a manga that is installed but not yet shown.
    static let shared = HttpSyncCloudBooks(scope: HttpSyncSettingsStore.shared.currentConfig())
    private(set) var records: [HttpSyncCloudBookRecord] = [] {
        didSet {
            let present = !records.isEmpty
            if hasRecords != present { hasRecords = present }
        }
    }
    private(set) var hasRecords = false
    private(set) var downloads: [String: Double] = [:]
    /// The manga whose archive a pass is transferring; only cancelling it stops the pass.
    private(set) var transferringSyncId: String?
    private(set) var generation = 0
    private var directory: URL
    private let baseDirectory: URL
    private var scope: String?
    @ObservationIgnored private var coverRetries: [String: (archive: String, after: Date)] = [:]

    init(directory: URL? = nil, scope config: HttpSyncConfig? = nil) {
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HoshiCloudCatalogue", isDirectory: true)
        self.baseDirectory = root
        self.directory = root
        if let config { activateScope(config: config) } else { reload() }
    }

    func activateScope(config: HttpSyncConfig) {
        var endpoint = config.baseURL
        while endpoint.hasSuffix("/") { endpoint.removeLast() }
        let identity = Self.digest(endpoint + "\n" + config.token)
        guard scope != identity else { return }
        let switching = scope != nil
        generation += 1
        scope = identity
        directory = baseDirectory.appendingPathComponent(identity, isDirectory: true)
        downloads = [:]
        coverRetries = [:]
        transferringSyncId = nil
        reload()
        // Another account hides a different set of installed books. Not from init: observers
        // would reach `shared` while it is still being created.
        if switching { NotificationCenter.default.post(name: .hoshiLibraryChanged, object: nil) }
    }

    func reload() {
        records = (try? Data(contentsOf: directory.appendingPathComponent("catalogue.json")))
            .flatMap { try? JSONDecoder().decode([HttpSyncCloudBookRecord].self, from: $0) } ?? []
    }

    var hasRequestedDownloads: Bool { records.contains { $0.downloadRequestedAt != nil } }
    var hasReadyDownloads: Bool { records.contains(where: \.awaitingBookmarkMap) }
    var readySyncIds: Set<String> { Set(records.filter(\.awaitingBookmarkMap).map(\.syncId)) }
    var requestedSyncIds: Set<String> { Set(records.filter { $0.downloadRequestedAt != nil }.map(\.syncId)) }
    var hiddenInstalledSyncIds: Set<String> {
        Set(records.filter { $0.awaitingBookmarkMap || $0.downloadRequestedAt != nil || $0.downloadError != nil }.map(\.syncId))
    }

    func record(syncId: String) -> HttpSyncCloudBookRecord? { records.first { $0.syncId == syncId } }

    func downloadState(syncId: String) -> HttpSyncCloudDownloadState {
        guard let record = record(syncId: syncId) else { return .available }
        if record.awaitingBookmarkMap { return .finishing }
        if record.downloadRequestedAt != nil {
            if transferringSyncId == syncId { return .downloading(downloads[syncId] ?? 0) }
            // A transferred archive is unpacked and installed later in the same pass.
            return downloads[syncId] == nil ? .queued : .finishing
        }
        return record.downloadError.map { .failed($0) } ?? .available
    }

    @discardableResult func requestDownload(syncId: String) -> Bool {
        guard let index = records.firstIndex(where: { $0.syncId == syncId }) else { return false }
        let previous = records[index]
        records[index].downloadRequestedAt = rfc3339Now()
        records[index].downloadError = nil
        guard save() else { records[index] = previous; return false }
        return true
    }

    func cancelRequest(syncId: String) {
        guard let index = records.firstIndex(where: { $0.syncId == syncId }) else { return }
        records[index].downloadRequestedAt = nil
        downloads.removeValue(forKey: syncId)
        endTransfer(syncId: syncId)
        save()
    }

    func withdrawRequests() {
        for index in records.indices { records[index].downloadRequestedAt = nil }
        downloads = [:]
        transferringSyncId = nil
        save()
    }

    func beginDownload(syncId: String) { downloads[syncId] = 0; transferringSyncId = syncId }
    func endTransfer(syncId: String) { if transferringSyncId == syncId { transferringSyncId = nil } }

    func updateTransfer(_ sample: HttpSyncTransferSample) {
        guard !sample.uploading, sample.key.hasPrefix("books/"), sample.key.hasSuffix("/payload.zip") else { return }
        let id = String(sample.key.dropFirst("books/".count).dropLast("/payload.zip".count))
        guard records.contains(where: { $0.syncId == id && $0.downloadRequestedAt != nil }) else { return }
        downloads[id] = sample.total > 0 ? min(1, max(0, Double(sample.completed) / Double(sample.total))) : 0
    }

    func failDownload(syncId: String, message: String) {
        guard let index = records.firstIndex(where: { $0.syncId == syncId }) else { return }
        records[index].downloadError = message
        records[index].downloadRequestedAt = nil
        downloads.removeValue(forKey: syncId)
        endTransfer(syncId: syncId)
        save()
    }

    func markAwaitingBookmarkMap(syncId: String) {
        guard let index = records.firstIndex(where: { $0.syncId == syncId }) else { return }
        records[index].awaitingBookmarkMap = true
        downloads[syncId] = 1
        save()
    }

    /// Shows installed manga, called by the manager only after a bookmark-map exchange that
    /// started once they were installed. A manga installed later waits for the next exchange.
    func reveal(_ syncIds: Set<String>) {
        let shown = records.filter { $0.awaitingBookmarkMap && syncIds.contains($0.syncId) }
        guard !shown.isEmpty else { return }
        for record in shown { remove(syncId: record.syncId) }
        // In the same main-actor turn the shelf reloads, so the manga moves from Not downloaded
        // onto its shelf without vanishing from both while the rest of the pass runs.
        NotificationCenter.default.post(name: .hoshiLibraryChanged, object: nil)
    }

    @discardableResult func recordListed(syncId: String, manifest: HttpSyncPayloadManifest, shelfName: String?, title: String? = nil) -> Bool {
        let title = title.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? manifest.originalName
        let added = record(syncId: syncId) == nil
        if let index = records.firstIndex(where: { $0.syncId == syncId }) {
            var updated = records[index]
            updated.title = title
            updated.sizeBytes = manifest.sizeBytes
            updated.archiveSha256 = manifest.sha256
            updated.contentSha256 = manifest.contentSha256
            updated.shelfName = shelfName
            guard updated != records[index] else { return false }
            records[index] = updated
        } else {
            records.append(.init(syncId: syncId, title: title, sizeBytes: manifest.sizeBytes,
                archiveSha256: manifest.sha256, contentSha256: manifest.contentSha256, shelfName: shelfName,
                discoveredAt: rfc3339Now()))
        }
        save()
        return added
    }

    func retain(syncIds: Set<String>) {
        for record in records where !syncIds.contains(record.syncId) { remove(syncId: record.syncId) }
    }

    func remove(syncId: String) {
        if let record = record(syncId: syncId), let cover = coverURL(record) { try? FileManager.default.removeItem(at: cover) }
        try? FileManager.default.removeItem(at: stagingRoot(syncId: syncId))
        records.removeAll { $0.syncId == syncId }
        downloads.removeValue(forKey: syncId)
        save()
    }

    func stagingRoot(syncId: String) -> URL {
        directory.appendingPathComponent("staging", isDirectory: true)
            .appendingPathComponent(Self.digest(syncId), isDirectory: true)
    }

    func coverURL(_ record: HttpSyncCloudBookRecord) -> URL? {
        guard let name = record.coverFile, name == (name as NSString).lastPathComponent else { return nil }
        return directory.appendingPathComponent("covers", isDirectory: true).appendingPathComponent(name)
    }

    /// Android publishes a bounded JPEG under an archive-specific key. Older servers without
    /// thumbnails keep a placeholder; listing a manga must never download its archive for a cover.
    func fetchMissingCovers(transport: HttpSyncKvTransport, now: Date = .now) async {
        let expectedGeneration = generation
        let missing = records.filter {
            guard $0.downloadRequestedAt == nil, $0.coverArchiveSha256 != $0.archiveSha256 else { return false }
            guard let retry = coverRetries[$0.syncId], retry.archive == $0.archiveSha256 else { return true }
            return now >= retry.after
        }
        for record in missing {
            guard !Task.isCancelled, generation == expectedGeneration else { return }
            let hash = String(record.archiveSha256.dropFirst("sha256:".count))
            guard record.archiveSha256.hasPrefix("sha256:"), hash.count == 64,
                  hash.allSatisfy({ $0.isHexDigit }) else { continue }
            do {
                let fetched = try await transport.getBounded(key: "books/\(record.syncId)/cover/\(hash)", maxBytes: 8 * 1024 * 1024)
                guard !Task.isCancelled, generation == expectedGeneration else { return }
                let thumbnail: Data?
                if let fetched { thumbnail = await Self.makeThumbnail(fetched.body) } else { thumbnail = nil }
                guard !Task.isCancelled, generation == expectedGeneration else { return }
                guard let index = records.firstIndex(where: { $0.syncId == record.syncId && $0.archiveSha256 == record.archiveSha256 }) else { continue }
                // Retry later for server-side backfills; a new archive is eligible immediately.
                guard let thumbnail else {
                    coverRetries[record.syncId] = (record.archiveSha256, now.addingTimeInterval(5 * 60))
                    continue
                }
                coverRetries[record.syncId] = nil
                let name = Self.digest(record.syncId + record.archiveSha256) + ".jpg"
                let covers = directory.appendingPathComponent("covers", isDirectory: true)
                try FileManager.default.createDirectory(at: covers, withIntermediateDirectories: true)
                try thumbnail.write(to: covers.appendingPathComponent(name), options: .atomic)
                records[index].coverFile = name
                records[index].coverArchiveSha256 = record.archiveSha256
                save()
            } catch { return } // One offline server must not time out once for every manga.
        }
    }

    @discardableResult private func save() -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var root = baseDirectory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? root.setResourceValues(values)
            try JSONEncoder().encode(records).write(to: directory.appendingPathComponent("catalogue.json"), options: .atomic)
            return true
        } catch { return false } // A new catalogue can be rediscovered; installed books are untouched.
    }

    nonisolated static func thumbnail(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 768,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.82)
    }

    @concurrent private static func makeThumbnail(_ data: Data) async -> Data? { thumbnail(data) }

    nonisolated private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
