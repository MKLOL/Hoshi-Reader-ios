//
//  HttpSyncPayload.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Book-payload (the mokuro pages/json or .epub bytes) round-trip over the v2 KV sync. Ported
//  from the Android HttpSyncPayload.kt, with iOS using SSZipArchive (via EPUBKit's ArchiveExtractor
//  for unzip and SSZipArchive.createZipFile for zip) instead of java.util.zip.
//
//  Wire layout, per book:
//   - books/{syncId}/payload.zip      — application/zip, the actual content bytes
//   - books/{syncId}/payload.manifest — JSON {sha256, sizeBytes, originalName, format}
//
//  The manifest is the change detector. We compute the local zip's sha256 and the receiving
//  device validates the downloaded zip bytes against the manifest's sha256 before unpacking. The
//  manifest's sha is the sha of THIS device's zip bytes; because zip implementations differ across
//  platforms, an iOS-uploaded sha won't equal an Android-uploaded sha for identical content — but
//  that's fine: a receiver only ever validates a downloaded zip against the same-origin manifest.
//
//  Manifest-existence policy (matches Android): if the server already has a manifest for a book,
//  we never re-upload from this device. Mokuro/EPUB content is immutable post-import; everything
//  that mutates as you read (bookmark, chat, stats) syncs through its own key.
//

import EPUBKit
import Foundation
import CryptoKit
import ZipArchive

/// Files inside a book directory that must NOT be zipped — they're per-device or synced via their
/// own key path. Must match Android `PAYLOAD_EXCLUDED_FILES`. iOS-specific additions
/// (`bookinfo.json`, `highlights.json`) are per-device-derived state that should not churn the sha.
///
/// Literals (not `FileNames.*`) on purpose: this global is `nonisolated` so the off-main payload
/// codec can read it, and `FileNames` is a main-actor-isolated type in Core/. The names are stable
/// on-disk filenames, so duplicating them here is safe and keeps the codec actor-independent.
nonisolated let httpSyncPayloadExcludedFiles: Set<String> = [
    "bookmark.json",            // synced as …/bookmark
    "ai_chat_log.json",         // synced as …/chat/…
    "metadata.json",            // per-device id + lastAccess; receiver makes its own
    "statistics.json",          // mutates as the user reads
    "sasayaki_match.json",      // per-device audiobook alignment
    "sasayaki_playback.json",   // per-device playhead
    "bookinfo.json",            // derived locally at import
    "highlights.json",          // per-device
    httpSyncPayloadShaCacheFilename,
]

/// Directories under a book root excluded from the payload, by name. Matches Android.
nonisolated let httpSyncPayloadExcludedDirs: Set<String> = ["Sasayaki"]

/// Sidecar caching the last-computed payload sha so an unchanged book isn't re-zipped/re-hashed.
nonisolated let httpSyncPayloadShaCacheFilename = ".payload.sha256.cache"

/// Zips a book directory, computes sha256 of the resulting bytes, and uploads zip + manifest iff
/// the server has no manifest yet. Downloads + unpacks remote-only books. All file IO is off the
/// main actor (callers `await` it from a detached context).
nonisolated struct HttpSyncPayloadCodec {
    private static let jsonEncoder = JSONEncoder()
    private static let jsonDecoder = JSONDecoder()

    /// Outbound. Returns `true` if a zip+manifest was uploaded, `false` if the server already had
    /// a manifest (no-op fast path). Throws on network / IO failure.
    func uploadIfChanged(
        transport: HttpSyncKvTransport,
        syncId: String,
        bookRoot: URL,
        originalName: String,
        format: ContentType
    ) async throws -> Bool {
        if try await fetchManifest(transport: transport, syncId: syncId) != nil {
            // Server already has this book — refuse to re-upload regardless of local mtime drift.
            return false
        }

        let fileManager = FileManager.default
        let spoolDir = fileManager.temporaryDirectory
        let zipURL = spoolDir.appendingPathComponent("hoshi-sync-upload-\(UUID().uuidString).zip")
        defer { try? fileManager.removeItem(at: zipURL) }

        // Offload the CPU/IO-heavy zip + hash so a 50 MB volume never blocks the UI.
        let sha = try await Task.detached(priority: .utility) {
            try Self.zipBookDirectory(bookRoot: bookRoot, to: zipURL)
        }.value
        let attrs = try? fileManager.attributesOfItem(atPath: zipURL.path(percentEncoded: false))
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        Self.writeCachedSha(bookRoot: bookRoot, sha: sha)

        // PUT zip first so the manifest never points at a missing or stale blob.
        _ = try await transport.putFile(key: SyncKeys.payloadZip(syncId), contentType: "application/zip", fileURL: zipURL)
        let manifest = HttpSyncPayloadManifest(
            sha256: sha,
            sizeBytes: size,
            originalName: originalName,
            format: format
        )
        let body = try Self.jsonEncoder.encode(manifest)
        _ = try await transport.put(
            key: SyncKeys.payloadManifest(syncId),
            contentType: "application/json; charset=utf-8",
            body: body
        )
        return true
    }

    /// Inbound. Downloads + validates + unpacks the payload zip into `targetDir`. Returns the
    /// manifest so the caller can use `originalName` / `format` to register the imported book.
    /// Throws if the manifest/zip is missing or the sha256 check fails.
    func downloadAndUnpack(
        transport: HttpSyncKvTransport,
        syncId: String,
        targetDir: URL
    ) async throws -> HttpSyncPayloadManifest {
        guard let manifest = try await fetchManifest(transport: transport, syncId: syncId) else {
            throw HttpSyncError("No payload manifest for \(syncId).")
        }
        let fileManager = FileManager.default
        let zipURL = fileManager.temporaryDirectory.appendingPathComponent("hoshi-sync-download-\(UUID().uuidString).zip")
        defer { try? fileManager.removeItem(at: zipURL) }

        guard try await transport.downloadToFile(key: SyncKeys.payloadZip(syncId), targetURL: zipURL) != nil else {
            throw HttpSyncError("Payload zip missing for \(syncId) (manifest existed).")
        }
        // Offload sha verification + unzip so a large download never blocks the UI. Reference
        // FileManager.default inside the closure rather than capturing the local (non-Sendable)
        // instance, so the detached closure stays Sendable.
        try await Task.detached(priority: .utility) {
            let actualSha = try Self.sha256OfFile(zipURL)
            if actualSha != manifest.sha256 {
                throw HttpSyncError("Payload zip for \(syncId) failed sha256 check (expected \(manifest.sha256), got \(actualSha)).")
            }
            try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
            do {
                try ArchiveExtractor.unzip(zipURL, to: targetDir)
            } catch {
                throw HttpSyncError("Failed to unpack payload zip for \(syncId): \(error.localizedDescription)")
            }
        }.value
        return manifest
    }

    /// Fetches just the remote manifest (no payload). `nil` if the server has none. Throws on
    /// network errors or malformed JSON.
    func fetchManifest(transport: HttpSyncKvTransport, syncId: String) async throws -> HttpSyncPayloadManifest? {
        guard let fetched = try await transport.get(key: SyncKeys.payloadManifest(syncId)) else { return nil }
        do {
            return try Self.jsonDecoder.decode(HttpSyncPayloadManifest.self, from: fetched.body)
        } catch {
            throw HttpSyncError("Manifest for \(syncId): malformed JSON.")
        }
    }

    // MARK: - Zip helpers

    /// Zips every non-excluded regular file under `bookRoot` into `zipURL` and returns the
    /// `sha256:<hex>` of the produced zip bytes. Because SSZipArchive can't selectively exclude
    /// files from a directory zip, we stage a filtered copy first (hard-link where possible to
    /// avoid duplicating large page images).
    private static func zipBookDirectory(bookRoot: URL, to zipURL: URL) throws -> String {
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory.appendingPathComponent("hoshi-sync-stage-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        try stageFilteredCopy(from: bookRoot, to: staging)

        let ok = SSZipArchive.createZipFile(
            atPath: zipURL.path(percentEncoded: false),
            withContentsOfDirectory: staging.path(percentEncoded: false)
        )
        guard ok else { throw HttpSyncError("Failed to zip book payload for upload.") }
        return try sha256OfFile(zipURL)
    }

    /// Recursively copies `source` into `dest`, skipping excluded files and directories.
    private static func stageFilteredCopy(from source: URL, to dest: URL) throws {
        let fileManager = FileManager.default
        let children = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }

        for child in children {
            let name = child.lastPathComponent
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                if httpSyncPayloadExcludedDirs.contains(name) { continue }
                let childDest = dest.appendingPathComponent(name, isDirectory: true)
                try fileManager.createDirectory(at: childDest, withIntermediateDirectories: true)
                try stageFilteredCopy(from: child, to: childDest)
            } else {
                if httpSyncPayloadExcludedFiles.contains(name) { continue }
                let childDest = dest.appendingPathComponent(name)
                try fileManager.copyItem(at: child, to: childDest)
            }
        }
    }

    private static func writeCachedSha(bookRoot: URL, sha: String) {
        let cacheURL = bookRoot.appendingPathComponent(httpSyncPayloadShaCacheFilename)
        try? Data(sha.utf8).write(to: cacheURL, options: .atomic)
    }

    private static func sha256OfFile(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }
}
