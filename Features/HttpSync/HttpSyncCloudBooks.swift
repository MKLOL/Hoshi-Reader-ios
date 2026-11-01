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

/// A server catalogue, never a source of local book-map entries or library backups. A durable
/// request survives process death; a failed request waits for an explicit retry. Incoming bytes
/// are staged here until all of the book's reading sidecars have been applied.
@MainActor @Observable
final class HttpSyncCloudBooks {
    static let shared = HttpSyncCloudBooks()
    private(set) var records: [HttpSyncCloudBookRecord] = []
    private(set) var downloads: [String: Double] = [:]
    private(set) var generation = 0
    private var directory: URL
    private let baseDirectory: URL
    private var scope: String?

    init(directory: URL? = nil) {
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HoshiCloudCatalogue", isDirectory: true)
        self.baseDirectory = root
        self.directory = root
        reload()
    }

    func activateScope(config: HttpSyncConfig) {
        var endpoint = config.baseURL
        while endpoint.hasSuffix("/") { endpoint.removeLast() }
        let identity = Self.digest(endpoint + "\n" + config.token)
        guard scope != identity else { return }
        generation += 1
        scope = identity
        directory = baseDirectory.appendingPathComponent(identity, isDirectory: true)
        downloads = [:]
        reload()
    }

    func reload() {
        records = (try? Data(contentsOf: directory.appendingPathComponent("catalogue.json")))
            .flatMap { try? JSONDecoder().decode([HttpSyncCloudBookRecord].self, from: $0) } ?? []
    }

    var hasRequestedDownloads: Bool { records.contains { $0.downloadRequestedAt != nil } }
    var hasReadyDownloads: Bool { records.contains(where: \.awaitingBookmarkMap) }
    var requestedSyncIds: Set<String> { Set(records.filter { $0.downloadRequestedAt != nil }.map(\.syncId)) }
    var hiddenInstalledSyncIds: Set<String> {
        Set(records.filter { $0.awaitingBookmarkMap || $0.downloadRequestedAt != nil || $0.downloadError != nil }.map(\.syncId))
    }

    func record(syncId: String) -> HttpSyncCloudBookRecord? { records.first { $0.syncId == syncId } }

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
        save()
    }

    func withdrawRequests() {
        for index in records.indices { records[index].downloadRequestedAt = nil }
        downloads = [:]
        save()
    }

    func beginDownload(syncId: String) { downloads[syncId] = 0 }

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
        save()
    }

    func markAwaitingBookmarkMap(syncId: String) {
        guard let index = records.firstIndex(where: { $0.syncId == syncId }) else { return }
        records[index].awaitingBookmarkMap = true
        downloads[syncId] = 1
        save()
    }

    /// Called by the manager only after its bookmark-map lane has seen the newly installed book.
    func finishDownloads(success: Bool) {
        let ready = records.filter(\.awaitingBookmarkMap)
        if success {
            for record in ready { remove(syncId: record.syncId) }
        } else {
            for record in ready {
                failDownload(syncId: record.syncId, message: "Reading data could not finish syncing. Tap to retry.")
            }
        }
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
    func fetchMissingCovers(transport: HttpSyncKvTransport) async {
        let expectedGeneration = generation
        let missing = records.filter { $0.downloadRequestedAt == nil && $0.coverArchiveSha256 != $0.archiveSha256 }
        for record in missing {
            guard !Task.isCancelled, generation == expectedGeneration else { return }
            let hash = String(record.archiveSha256.dropFirst("sha256:".count))
            guard record.archiveSha256.hasPrefix("sha256:"), hash.count == 64,
                  hash.allSatisfy({ $0.isHexDigit }) else { continue }
            do {
                let fetched = try await transport.getBounded(key: "books/\(record.syncId)/cover/\(hash)", maxBytes: 8 * 1024 * 1024)
                guard !Task.isCancelled, generation == expectedGeneration else { return }
                let thumbnail = fetched.flatMap { Self.thumbnail($0.body) }
                guard let index = records.firstIndex(where: { $0.syncId == record.syncId && $0.archiveSha256 == record.archiveSha256 }) else { continue }
                // An absent thumbnail may be backfilled by another device later: don't mark it
                // permanently unavailable. A future sync can discover it without the archive.
                guard let thumbnail else { continue }
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

    nonisolated private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
