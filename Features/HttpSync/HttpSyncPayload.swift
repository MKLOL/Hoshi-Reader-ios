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
    "manga_statistics.json",    // mutates as the user reads manga
    "sasayaki_match.json",      // per-device audiobook alignment
    "sasayaki_playback.json",   // per-device playhead
    "bookinfo.json",            // derived locally at import
    "highlights.json",          // per-device
    "pretranslations.json",     // synced as …/pretranslations
    "sentence_translations.json", // synced as …/sentences
    httpSyncPayloadShaCacheFilename,
    ".payload.sha256.cache",
    ".payload.content.local_dirty",
    httpSyncPayloadReplacementTargetFilename,
]

/// Directories under a book root excluded from the payload, by name. Matches Android.
nonisolated let httpSyncPayloadExcludedDirs: Set<String> = ["Sasayaki"]

/// Sidecar caching the last-computed payload sha so an unchanged book isn't re-zipped/re-hashed.
nonisolated let httpSyncPayloadShaCacheFilename = ".payload.content.sha256.cache"
nonisolated private let httpSyncPayloadReplacementTargetFilename = ".payload.replacement.target"
nonisolated private let httpSyncPayloadReplacementBackupPrefix = ".hoshi-sync-backup-"

/// Excluded files that are genuinely mutable/per-device and survive a static replacement.
/// `bookinfo.json` is derived from EPUB bytes and must be regenerated for changed content.
nonisolated private let httpSyncReplacementPreservedFiles = httpSyncPayloadExcludedFiles
    .subtracting([
        "bookinfo.json",
        httpSyncPayloadShaCacheFilename,
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
        guard let manifest = try await fetchManifest(transport: transport, keys: keys) else {
            throw HttpSyncError("No payload manifest for \(syncId).")
        }
        guard manifest.format == expectedFormat else {
            throw HttpSyncError(
                "Payload manifest for \(syncId) declares \(manifest.format.rawValue), "
                + "but \(keys.manifest) requires \(expectedFormat.rawValue)."
            )
        }
        let fileManager = FileManager.default
        let zipURL = fileManager.temporaryDirectory.appendingPathComponent("hoshi-sync-download-\(UUID().uuidString).zip")
        defer { try? fileManager.removeItem(at: zipURL) }

        guard try await transport.downloadToFile(key: keys.zip, targetURL: zipURL) != nil else {
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
        let contentSha = try await Task.detached(priority: .utility) {
            try Self.contentSha(bookRoot: targetDir)
        }.value
        if let declared = manifest.contentSha256, declared != contentSha {
            throw HttpSyncError(
                "Payload content for \(syncId) failed sha256 check (expected \(declared), got \(contentSha))."
            )
        }
        Self.writeCachedSha(bookRoot: targetDir, sha: contentSha)
        return HttpSyncPayloadManifest(
            sha256: manifest.sha256,
            sizeBytes: manifest.sizeBytes,
            originalName: manifest.originalName,
            format: manifest.format,
            contentSha256: contentSha
        )
    }

    /// Fetches just the remote manifest (no payload). `nil` if the server has none. Throws on
    /// network errors or malformed JSON.
    func fetchManifest(
        transport: HttpSyncKvTransport,
        keys: HttpSyncPayloadKeys
    ) async throws -> HttpSyncPayloadManifest? {
        guard let fetched = try await transport.get(key: keys.manifest) else { return nil }
        do {
            return try Self.jsonDecoder.decode(HttpSyncPayloadManifest.self, from: fetched.body)
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
    static func contentSha(bookRoot: URL) throws -> String {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: bookRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { throw HttpSyncError("Could not enumerate book payload.") }
        var files: [(String, URL)] = []
        while let url = enumerator.nextObject() as? URL {
            let relative = String(url.path(percentEncoded: false).dropFirst(
                bookRoot.path(percentEncoded: false).count + 1
            )).precomposedStringWithCanonicalMapping
            let components = relative.split(separator: "/").map(String.init)
            if components.dropLast().contains(where: { httpSyncPayloadExcludedDirs.contains($0) }) {
                continue
            }
            if httpSyncPayloadExcludedFiles.contains(url.lastPathComponent) { continue }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                files.append((relative, url))
            }
        }
        files.sort { $0.0 < $1.0 }
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
