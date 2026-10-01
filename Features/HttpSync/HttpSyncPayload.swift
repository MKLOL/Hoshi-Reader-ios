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
/// Literal on-disk names, plus `FileNames.generatedCover` so the one name the shelf writes for a
/// receiver-generated cover can never drift from the name this list excludes.
nonisolated let httpSyncPayloadExcludedFiles: Set<String> = [
    "bookmark.json",            // synced as …/bookmark
    "ai_chat_log.json",         // synced as …/chat/…
    "metadata.json",            // per-device id + lastAccess; receiver makes its own
    ".statistics_devices_v2",
    ".legacy_manga_statistics.json",
    ".http_sync_statistics_state.json",
    ".http_sync_statistics.json",
    "statistics.json",          // mutates as the user reads
    "manga_statistics.json",    // mutates as the user reads manga
    "sasayaki_match.json",      // per-device audiobook alignment
    "sasayaki_playback.json",   // per-device playhead
    "bookinfo.json",            // derived locally at import
    "highlights.json",          // per-device
    "pretranslations.json",     // synced as …/pretranslations
    "sentence_translations.json", // synced as …/sentences
    FileNames.generatedCover,     // receiver-generated cover; origin payloads never contain it
    httpSyncPayloadShaCacheFilename,
    httpSyncPayloadZipShaCacheFilename,
    ".payload.sha256.cache",
    ".payload.content.local_dirty",
    httpSyncPayloadReplacementTargetFilename,
]

/// Directories under a book root excluded from the payload, by name. Matches Android.
nonisolated let httpSyncPayloadExcludedDirs: Set<String> = ["Sasayaki"]

/// Sidecar caching the last-computed payload sha so an unchanged book isn't re-zipped/re-hashed.
nonisolated let httpSyncPayloadShaCacheFilename = ".payload.content.sha256.cache"
/// sha256 of the archive this install last uploaded or installed. While the server's manifest
/// still points at that exact archive, a content-hash disagreement can only be a derivation
/// difference between clients, never new content, so no download is owed.
nonisolated let httpSyncPayloadZipShaCacheFilename = ".payload.zip.sha256.cache"
nonisolated private let httpSyncPayloadReplacementTargetFilename = ".payload.replacement.target"
nonisolated private let httpSyncPayloadReplacementBackupPrefix = ".hoshi-sync-backup-"

/// Excluded files that are genuinely mutable/per-device and survive a static replacement.
/// `bookinfo.json` is derived from EPUB bytes and must be regenerated for changed content.
nonisolated private let httpSyncReplacementPreservedFiles = httpSyncPayloadExcludedFiles
    .subtracting([
        "bookinfo.json",
        FileNames.generatedCover,
        httpSyncPayloadShaCacheFilename,
        httpSyncPayloadZipShaCacheFilename,
        ".payload.sha256.cache",
        httpSyncPayloadReplacementTargetFilename,
    ])

/// Which pair of KV keys a book's payload lives under.
///
/// Mokuro keeps the original `payload.*` keys. EPUB deliberately gets its own: Android's
/// `parseBookKey` matches a closed set of suffixes and skips anything else without fetching it, so
/// routing novels here means the Android client never downloads a book it was not built to expect
/// and needs no changes at all. See docs/EPUB_TRANSLATION_ARCHITECTURE.md §4.
nonisolated struct HttpSyncPayloadKeys {
    let zip: String
    let manifest: String

    static func forFormat(_ format: ContentType, syncId: String) -> HttpSyncPayloadKeys {
        switch format {
        case .mokuro:
            return HttpSyncPayloadKeys(zip: SyncKeys.payloadZip(syncId),
                                       manifest: SyncKeys.payloadManifest(syncId))
        case .epub:
            return HttpSyncPayloadKeys(zip: SyncKeys.epubZip(syncId),
                                       manifest: SyncKeys.epubManifest(syncId))
        }
    }
}

/// Zips a book directory, computes sha256 of the resulting bytes, and uploads zip + manifest iff
/// the server has no manifest yet. Downloads + unpacks remote-only books. All file IO is off the
/// main actor (callers `await` it from a detached context).
nonisolated struct HttpSyncPayloadCodec {
    private static let jsonEncoder = JSONEncoder()
    private static let jsonDecoder = JSONDecoder()

    func cachedPayloadSha(bookRoot: URL) -> String? {
        let cache = bookRoot.appendingPathComponent(httpSyncPayloadShaCacheFilename)
        guard let raw = try? String(contentsOf: cache, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              raw.range(of: #"^sha256:[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return raw
    }

    /// sha256 of the archive this install last uploaded or installed for the book, if known.
    func cachedZipSha(bookRoot: URL) -> String? {
        let cache = bookRoot.appendingPathComponent(httpSyncPayloadZipShaCacheFilename)
        guard let raw = try? String(contentsOf: cache, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              raw.range(of: #"^sha256:[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return raw
    }

    private static func writeZipSha(bookRoot: URL, sha: String) {
        try? Data(sha.utf8).write(
            to: bookRoot.appendingPathComponent(httpSyncPayloadZipShaCacheFilename), options: .atomic
        )
    }

    /// Records the archive `bookRoot`'s content is known to equal. Uploads and installs write it
    /// beside the unpacked book; callers that prove an already-held book matches the server's
    /// archive without installing anything (a verify-only download, or a local re-hash that agrees
    /// with the manifest) must record it too, or a book that predates this sidecar never gains the
    /// baseline that stops cross-platform hash disagreements from re-downloading it.
    func rememberZipSha(bookRoot: URL, sha: String) {
        Self.writeZipSha(bookRoot: bookRoot, sha: sha)
    }

    /// Establishes the baseline for an upgraded client that already has this book offline.
    func rememberPayloadSha(bookRoot: URL, sha: String) throws {
        guard sha.range(of: #"^sha256:[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            throw HttpSyncError("Invalid payload sha256: \(sha)")
        }
        Self.writeCachedSha(bookRoot: bookRoot, sha: sha)
    }

    /// Computes the cross-platform static-content hash once for a pre-map import/download.
    func ensurePayloadContentSha(bookRoot: URL) async throws -> String {
        if let cached = cachedPayloadSha(bookRoot: bookRoot) { return cached }
        let hash = try await Task.detached(priority: .utility) {
            try Self.contentSha(bookRoot: bookRoot)
        }.value
        Self.writeCachedSha(bookRoot: bookRoot, sha: hash)
        return hash
    }

    /// Recomputes the content hash from disk, ignoring the cache sidecar, and rewrites it.
    /// Callers use it before replacing a book whose *cached* hash disagrees with the server: a
    /// stale or mis-derived sidecar must never cost a download that installs identical bytes.
    func refreshPayloadContentSha(bookRoot: URL) async throws -> String {
        let hash = try await Task.detached(priority: .utility) {
            try Self.contentSha(bookRoot: bookRoot)
        }.value
        Self.writeCachedSha(bookRoot: bookRoot, sha: hash)
        return hash
    }

    func markPayloadContentDirty(bookRoot: URL) {
        try? Data("1".utf8).write(
            to: bookRoot.appendingPathComponent(".payload.content.local_dirty"),
            options: .atomic
        )
    }

    func hasPayloadContentDirty(bookRoot: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: bookRoot.appendingPathComponent(".payload.content.local_dirty")
                .path(percentEncoded: false)
        )
    }

    /// Installs verified static bytes while retaining mutable/per-device sidecars and rollback.
    func installReplacement(bookRoot: URL, stagingRoot: URL, sha: String) throws {
        let fileManager = FileManager.default
        let parent = bookRoot.deletingLastPathComponent()
        recoverInterruptedReplacements(booksDirectory: parent)
        let backup = parent.appendingPathComponent(
            "\(httpSyncPayloadReplacementBackupPrefix)\(UUID().uuidString)",
            isDirectory: true
        )
        try Data(bookRoot.lastPathComponent.utf8).write(
            to: bookRoot.appendingPathComponent(httpSyncPayloadReplacementTargetFilename),
            options: .atomic
        )
        do {
            try fileManager.moveItem(at: bookRoot, to: backup)
        } catch {
            try? fileManager.removeItem(
                at: bookRoot.appendingPathComponent(httpSyncPayloadReplacementTargetFilename)
            )
            throw error
        }
        var movedSidecars: [String] = []
        do {
            try fileManager.moveItem(at: stagingRoot, to: bookRoot)
            for child in try replacementSidecars(root: backup) {
                let name = child.lastPathComponent
                let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                let destination = bookRoot.appendingPathComponent(name, isDirectory: isDirectory)
                if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: child, to: destination)
                movedSidecars.append(name)
            }
            try rememberPayloadSha(bookRoot: bookRoot, sha: sha)
            try? fileManager.removeItem(at: backup)
        } catch {
            for name in movedSidecars.reversed() {
                let source = bookRoot.appendingPathComponent(name)
                let destination = backup.appendingPathComponent(name)
                if fileManager.fileExists(atPath: source.path(percentEncoded: false)) {
                    try? fileManager.moveItem(at: source, to: destination)
                }
            }
            try? fileManager.removeItem(at: bookRoot)
            try? fileManager.moveItem(at: backup, to: bookRoot)
            try? fileManager.removeItem(
                at: bookRoot.appendingPathComponent(httpSyncPayloadReplacementTargetFilename)
            )
            throw HttpSyncError("Could not install changed payload: \(error.localizedDescription)")
        }
    }

    /// Repairs a process death at any point in the directory swap before books are listed.
    func recoverInterruptedReplacements(booksDirectory: URL) {
        let fileManager = FileManager.default
        guard let children = try? fileManager.contentsOfDirectory(
            at: booksDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }
        for backup in children where backup.lastPathComponent.hasPrefix(httpSyncPayloadReplacementBackupPrefix) {
            let marker = backup.appendingPathComponent(httpSyncPayloadReplacementTargetFilename)
            guard let targetName = try? String(contentsOf: marker, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !targetName.isEmpty,
                  !targetName.hasPrefix("."),
                  (targetName as NSString).lastPathComponent == targetName else { continue }
            let target = booksDirectory.appendingPathComponent(targetName, isDirectory: true)
            do {
                if fileManager.fileExists(atPath: target.path(percentEncoded: false)) {
                    for sidecar in try replacementSidecars(root: backup) {
                        let destination = target.appendingPathComponent(sidecar.lastPathComponent)
                        // A sidecar created after relaunch is newer than the rollback copy.
                        guard !fileManager.fileExists(atPath: destination.path(percentEncoded: false)) else {
                            continue
                        }
                        try fileManager.moveItem(at: sidecar, to: destination)
                    }
                    try fileManager.removeItem(at: backup)
                } else {
                    try fileManager.moveItem(at: backup, to: target)
                    try? fileManager.removeItem(
                        at: target.appendingPathComponent(httpSyncPayloadReplacementTargetFilename)
                    )
                }
            } catch {
                // Leave the marked backup in place; the next startup retries recovery.
                continue
            }
        }
    }

    private func replacementSidecars(root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).filter { child in
            let name = child.lastPathComponent
            let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            return (isDirectory && httpSyncPayloadExcludedDirs.contains(name)) ||
                (!isDirectory && httpSyncReplacementPreservedFiles.contains(name))
        }
    }

    /// Outbound. Returns `true` if a zip+manifest was uploaded, `false` if the server already had
    /// a manifest (no-op fast path). Throws on network / IO failure.
    func uploadIfChanged(
        transport: HttpSyncKvTransport,
        syncId: String,
        bookRoot: URL,
        originalName: String,
        format: ContentType
    ) async throws -> Bool {
        let keys = HttpSyncPayloadKeys.forFormat(format, syncId: syncId)
        if let remoteManifest = try await fetchManifest(transport: transport, keys: keys) {
            // Server already has this book — refuse to re-upload regardless of local mtime drift.
            let contentSha = try await ensurePayloadContentSha(bookRoot: bookRoot)
            let forceReplacement = hasPayloadContentDirty(bookRoot: bookRoot) &&
                remoteManifest.contentSha256 != contentSha
            if hasPayloadContentDirty(bookRoot: bookRoot), remoteManifest.contentSha256 == contentSha {
                try? FileManager.default.removeItem(
                    at: bookRoot.appendingPathComponent(".payload.content.local_dirty")
                )
            }
            if !forceReplacement { return false }
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
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let contentSha = try await Task.detached(priority: .utility) {
            try Self.contentSha(bookRoot: bookRoot)
        }.value
        Self.writeCachedSha(bookRoot: bookRoot, sha: contentSha)

        // PUT zip first so the manifest never points at a missing or stale blob.
        _ = try await transport.putFile(key: keys.zip, contentType: "application/zip", fileURL: zipURL)
        let manifest = HttpSyncPayloadManifest(
            sha256: sha,
            sizeBytes: size,
            originalName: originalName,
            format: format,
            contentSha256: contentSha
        )
        let body = try Self.jsonEncoder.encode(manifest)
        _ = try await transport.put(
            key: keys.manifest,
            contentType: "application/json; charset=utf-8",
            body: body
        )
        Self.writeZipSha(bookRoot: bookRoot, sha: sha)
        try? fileManager.removeItem(at: bookRoot.appendingPathComponent(".payload.content.local_dirty"))
        return true
    }

    /// Inbound. Downloads + validates + unpacks the payload zip into `targetDir`. Returns the
    /// manifest so the caller can use `originalName` / `format` to register the imported book.
    /// Throws if the manifest/zip is missing or the sha256 check fails.
    func downloadAndUnpack(
        transport: HttpSyncKvTransport,
        syncId: String,
        keys: HttpSyncPayloadKeys,
        expectedFormat: ContentType,
        targetDir: URL
    ) async throws -> HttpSyncPayloadManifest {
        guard let fetchedManifest = try await transport.get(key: keys.manifest) else {
            throw HttpSyncError("No payload manifest for \(syncId).")
        }
        let manifest = try Self.decodeManifest(fetchedManifest, keys: keys)
        guard manifest.format == expectedFormat else {
            throw HttpSyncError(
                "Payload manifest for \(syncId) declares \(manifest.format.rawValue), "
                + "but \(keys.manifest) requires \(expectedFormat.rawValue)."
            )
        }
        let fileManager = FileManager.default
        let cache = HttpSyncDownloadCache.shared
        let directory = cache.directory(books: targetDir.deletingLastPathComponent(), key: keys.zip, archiveSHA: manifest.sha256)
        try cache.acquire(directory)
        defer { cache.release(directory) }
        let zipURL = directory.appendingPathComponent("payload.zip")
        // A completed background transfer may have outlived its importing process. Verify its
        // manifest before reuse; a new manifest gets a distinct checkpoint directory.
        let complete = await Task.detached(priority: .utility) {
            let size = (try? zipURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
            return Int64(size) == manifest.sizeBytes && (try? Self.sha256OfFile(zipURL)) == manifest.sha256
        }.value
        try Task.checkCancellation()
        if !complete {
            if fileManager.fileExists(atPath: zipURL.path) {
                try? fileManager.removeItem(at: zipURL)
                try? fileManager.removeItem(at: zipURL.appendingPathExtension("response"))
            }
            guard try await transport.downloadToFile(key: keys.zip, targetURL: zipURL) != nil else {
                throw HttpSyncError("Payload zip missing for \(syncId) (manifest existed).")
            }
        }
        try Task.checkCancellation()
        // Offload sha verification + unzip so a large download never blocks the UI. Reference
        // FileManager.default inside the closure rather than capturing the local (non-Sendable)
        // instance, so the detached closure stays Sendable.
        try await Task.detached(priority: .utility) {
            let actualSha = try Self.sha256OfFile(zipURL)
            let size = (try zipURL.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            if actualSha != manifest.sha256 || Int64(size) != manifest.sizeBytes {
                try? FileManager.default.removeItem(at: directory)
                throw HttpSyncError("Payload zip for \(syncId) failed sha256 check (expected \(manifest.sha256), got \(actualSha)).")
            }
            try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
            do {
                try ArchiveExtractor.unzip(zipURL, to: targetDir)
            } catch {
                throw HttpSyncError("Failed to unpack payload zip for \(syncId): \(error.localizedDescription)")
            }
        }.value
        try Task.checkCancellation()
        let contentSha = try await Task.detached(priority: .utility) {
            try Self.contentSha(bookRoot: targetDir)
        }.value
        try Task.checkCancellation()
        Self.writeCachedSha(bookRoot: targetDir, sha: contentSha)
        let verified = HttpSyncPayloadManifest(
            sha256: manifest.sha256,
            sizeBytes: manifest.sizeBytes,
            originalName: manifest.originalName,
            format: manifest.format,
            contentSha256: contentSha
        )
        // The archive sha256 above is the integrity check; the content hash is a change detector
        // derived from those verified bytes. A manifest that disagrees was written by a client
        // whose derivation differed (this app through 0.11.3), so it is corrected rather than
        // treated as corruption.
        if manifest.contentSha256 != contentSha {
            try await repairManifest(transport: transport, keys: keys, verifiedAgainst: fetchedManifest.body, verified: verified)
        }
        Self.writeZipSha(bookRoot: targetDir, sha: manifest.sha256)
        try? fileManager.removeItem(at: directory)
        return verified
    }

    /// Republishes `verified` only while the server still serves byte-for-byte the manifest the
    /// archive was checked against (`verifiedAgainst`, its raw body). Another device may have
    /// published a new archive during this download; overwriting its manifest with the old sha256
    /// and size would break the book for every device until that publisher syncs again. The raw
    /// bytes are compared rather than decoded fields so a rewrite this client cannot represent (an
    /// unknown field, a different note) is never clobbered either. The KV API has no conditional
    /// PUT, so this re-fetch is the narrowest window available. A failed repair just repeats on the
    /// next sync; cancellation still propagates.
    private func repairManifest(
        transport: HttpSyncKvTransport,
        keys: HttpSyncPayloadKeys,
        verifiedAgainst: Data,
        verified: HttpSyncPayloadManifest
    ) async throws {
        do {
            guard let current = try await transport.get(key: keys.manifest), current.body == verifiedAgainst else { return }
            try await publishVerifiedContentSha(transport: transport, keys: keys, manifest: verified)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The archive is verified and unpacked; only the server-side note is stale.
        }
    }

    /// Fetches just the remote manifest (no payload). `nil` if the server has none. Throws on
    /// network errors or malformed JSON.
    func fetchManifest(
        transport: HttpSyncKvTransport,
        keys: HttpSyncPayloadKeys
    ) async throws -> HttpSyncPayloadManifest? {
        guard let fetched = try await transport.get(key: keys.manifest) else { return nil }
        return try Self.decodeManifest(fetched, keys: keys)
    }

    private static func decodeManifest(_ fetched: HttpSyncKvFetched, keys: HttpSyncPayloadKeys) throws -> HttpSyncPayloadManifest {
        do {
            return try jsonDecoder.decode(HttpSyncPayloadManifest.self, from: fetched.body)
        } catch {
            throw HttpSyncError("Manifest at \(keys.manifest): malformed JSON.")
        }
    }

    /// Publish a content hash only after it was computed from the verified remote ZIP.
    func publishVerifiedContentSha(
        transport: HttpSyncKvTransport,
        keys: HttpSyncPayloadKeys,
        manifest: HttpSyncPayloadManifest
    ) async throws {
        guard manifest.contentSha256 != nil else {
            throw HttpSyncError("Cannot publish an unverified payload content hash.")
        }
        _ = try await transport.put(
            key: keys.manifest,
            contentType: "application/json; charset=utf-8",
            body: try Self.jsonEncoder.encode(manifest)
        )
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

    /// Pre-`.generated_cover.jpg` builds materialized a receiver-side cover straight into the
    /// book root (mokuro: literal `cover.jpg`; EPUB: the manifest cover's basename), where it
    /// poisons the content hash against the origin's manifest forever. If ignoring exactly one
    /// such candidate root file makes the hash match the manifest, the local content then provably
    /// equals the origin's: rename that file to the excluded name and cache the now-matching sha
    /// instead of re-downloading the entire archive. The caller repoints the book's metadata cover path
    /// (metadata IO is main-actor-isolated; this codec is not).
    func migrateLegacyGeneratedCover(bookRoot: URL, expectedSha: String, candidateNames: [String]) -> Bool {
        let fileManager = FileManager.default
        for name in candidateNames {
            guard !name.isEmpty, name != FileNames.generatedCover, !name.contains("/") else { continue }
            let legacy = bookRoot.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: legacy.path(percentEncoded: false)) else { continue }
            guard let shaWithoutCover = try? Self.contentSha(
                // The hash compares NFC-precomposed relative paths; normalize the candidate too.
                bookRoot: bookRoot, excludingRootFiles: [name.precomposedStringWithCanonicalMapping]
            ), shaWithoutCover == expectedSha else { continue }
            let target = bookRoot.appendingPathComponent(FileNames.generatedCover)
            do {
                if fileManager.fileExists(atPath: target.path(percentEncoded: false)) {
                    _ = try fileManager.replaceItemAt(target, withItemAt: legacy)
                } else {
                    try fileManager.moveItem(at: legacy, to: target)
                }
            } catch { return false }
            Self.writeCachedSha(bookRoot: bookRoot, sha: expectedSha)
            return true
        }
        return false
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

    /// Hashes sorted relative path + length + bytes; identical content hashes the same on iOS
    /// and Android even though their ZIP encoders produce different binary archives.
    static func contentSha(bookRoot: URL, excludingRootFiles: Set<String> = []) throws -> String {
        let fileManager = FileManager.default
        // `.producesRelativePathURLs` makes `relativePath` exactly the path under the root.
        // Deriving it by character count from `path()` was wrong twice over: the enumerator
        // returns symlink-resolved paths (`/private/var/…` for the `/var/…` app container, i.e.
        // every iOS Documents directory) and `path()` keeps a trailing slash on directory URLs.
        // Both left garbage from the parent directory's name on every relative path, so the
        // hash never matched Android, and a staging directory's random UUID poisoned every
        // manifest this app published in 0.11.3. The root's own symlinks are resolved up front
        // because the enumerator does not follow a symlinked root and would yield nothing.
        let root = bookRoot.resolvingSymlinksInPath()
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.producesRelativePathURLs]
        ) else { throw HttpSyncError("Could not enumerate book payload.") }
        var files: [(String, URL)] = []
        while let url = enumerator.nextObject() as? URL {
            let relative = url.relativePath.precomposedStringWithCanonicalMapping
            let components = relative.split(separator: "/").map(String.init)
            if components.dropLast().contains(where: { httpSyncPayloadExcludedDirs.contains($0) }) {
                continue
            }
            if httpSyncPayloadExcludedFiles.contains(url.lastPathComponent) { continue }
            // Root-level only: `relative` has no "/" for files directly under the book root.
            if excludingRootFiles.contains(relative) { continue }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                files.append((relative, url))
            }
        }
        // Order by the UTF-8 bytes of the NFC path — Swift's String order is code-point order,
        // which is byte order; Android sorts the same bytes explicitly because Kotlin's String
        // order is UTF-16 code units and disagrees outside the BMP.
        files.sort { Array($0.0.utf8).lexicographicallyPrecedes(Array($1.0.utf8)) }
        var hasher = SHA256()
        for (path, url) in files {
            let pathData = Data(path.utf8)
            var pathLength = UInt32(pathData.count).bigEndian
            withUnsafeBytes(of: &pathLength) { hasher.update(data: Data($0)) }
            hasher.update(data: pathData)
            let attributes = try fileManager.attributesOfItem(atPath: url.path(percentEncoded: false))
            var size = UInt64((attributes[.size] as? NSNumber)?.uint64Value ?? 0).bigEndian
            withUnsafeBytes(of: &size) { hasher.update(data: Data($0)) }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            while true {
                let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
            }
        }
        return "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
