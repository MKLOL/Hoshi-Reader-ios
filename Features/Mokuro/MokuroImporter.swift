//
//  MokuroImporter.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Imports a mokuro manga volume into a Hoshi book directory. Ported from the Android
//  `MokuroImporter`. Mokuro's output for one volume is a `.mokuro` JSON file plus a folder of
//  page images; this importer accepts that output as a `.zip`/`.cbz` bundle or a picked
//  folder and produces the canonical on-disk layout under `Books/<safeTitle>/`:
//
//   - `mokuro.json`: the `.mokuro` JSON with every page's `img_path` rewritten to
//     `images/<basename>` so it resolves against the book directory. Unknown fields are
//     preserved verbatim.
//   - `images/`: every page image, flattened to basenames.
//   - `cover.jpg`: a downsampled thumbnail of page 1 (bookshelf cover).
//   - `metadata.json` / `bookinfo.json`: the shared Hoshi sidecars.
//

import EPUBKit
import Foundation

enum MokuroImportError: LocalizedError {
    case noMokuroFile
    case noPages
    case missingImage(String)
    case unreadable(Error)

    var errorDescription: String? {
        switch self {
        case .noMokuroFile:
            return "No mokuro.json found in the selected manga."
        case .noPages:
            return "The mokuro file contains no pages."
        case .missingImage(let path):
            return "Page image referenced by the mokuro file is missing: \(path)"
        case .unreadable(let error):
            return "Could not import manga: \(error.localizedDescription)"
        }
    }
}

struct MokuroImporter {
    /// File extensions accepted as zip archives of a mokuro volume.
    private static let archiveExtensions: Set<String> = ["zip", "cbz"]
    /// The `.mokuro` JSON file extension.
    private static let mokuroExtension = "mokuro"
    /// Book-root-relative directory page images are flattened into.
    private static let imagesDir = FileNames.mokuroImages

    /// Imports a `.zip`/`.cbz` bundle or a folder containing a `.mokuro` sidecar + images into
    /// the Books directory, writing the canonical `mokuro.json`, `images/`, a downsampled
    /// `cover.jpg`, `metadata.json` (with `contentType = .mokuro` and `importedAt`), and
    /// `bookinfo.json` (with `characterCount = page count` so the bookshelf progress bar is
    /// page-based). Returns the created book's metadata, or the existing metadata if a book
    /// directory with the same sanitized title already exists.
    static func importBundle(from sourceURL: URL) throws -> BookMetadata {
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let fileManager = FileManager.default

        // Stage the source into a directory we can freely walk. Folders are staged in place
        // (the picked tree); archives are extracted into a temp staging dir.
        let staging: URL
        let stagingToCleanup: URL?
        var isDirectory: ObjCBool = false
        fileManager.fileExists(atPath: sourceURL.path(percentEncoded: false), isDirectory: &isDirectory)

        if isDirectory.boolValue {
            staging = sourceURL
            stagingToCleanup = nil
        } else {
            let tempStaging = fileManager.temporaryDirectory
                .appendingPathComponent("MokuroImport-\(UUID().uuidString)", isDirectory: true)
            do {
                try EPUBKit.ArchiveExtractor.unzip(sourceURL, to: tempStaging)
            } catch {
                try? fileManager.removeItem(at: tempStaging)
                throw MokuroImportError.unreadable(error)
            }
            staging = tempStaging
            stagingToCleanup = tempStaging
        }
        defer {
            if let cleanup = stagingToCleanup {
                try? fileManager.removeItem(at: cleanup)
            }
        }

        return try assembleBook(staging: staging, fallbackName: sourceURL.deletingPathExtension().lastPathComponent)
    }

    // MARK: - Assembly

    /// Given a `staging` directory mirroring the source layout, locate the `.mokuro` file,
    /// copy its referenced images into the target book directory, write the path-rewritten
    /// `mokuro.json`, the cover, and the metadata/bookinfo sidecars.
    private static func assembleBook(staging: URL, fallbackName: String) throws -> BookMetadata {
        let fileManager = FileManager.default

        guard let mokuroFile = findMokuroFile(in: staging) else {
            throw MokuroImportError.noMokuroFile
        }
        let sourceRoot = mokuroFile.deletingLastPathComponent()

        // Load the raw sidecar twice: as a typed model (for title + page basics) and as a
        // mutable JSON object (so unknown fields survive the rewrite).
        let rawData: Data
        do {
            rawData = try Data(contentsOf: mokuroFile)
        } catch {
            throw MokuroImportError.unreadable(error)
        }

        let rawMokuro: RawMokuro
        do {
            rawMokuro = try JSONDecoder().decode(RawMokuro.self, from: rawData)
        } catch {
            throw MokuroImportError.unreadable(error)
        }
        guard !rawMokuro.pages.isEmpty else {
            throw MokuroImportError.noPages
        }

        guard
            let rootObject = (try? JSONSerialization.jsonObject(with: rawData)) as? [String: Any],
            let pageObjects = rootObject["pages"] as? [[String: Any]],
            !pageObjects.isEmpty
        else {
            throw MokuroImportError.noPages
        }

        let title = rawMokuro.volume?.nonBlank
            ?? rawMokuro.title?.nonBlank
            ?? mokuroFile.deletingPathExtension().lastPathComponent

        // First pass: resolve every page image against the source layout and plan its
        // flattened destination basename. Fail before touching the target directory so a
        // partial book is never left on disk. `plannedImages` preserves insertion order.
        var plannedBasenames: [String] = []
        var plannedSources: [String: URL] = [:]
        var takenBasenames: Set<String> = []
        var rewrittenPages = pageObjects

        for (idx, page) in pageObjects.enumerated() {
            guard let imgPath = (page["img_path"] as? String)?.nonBlank else {
                throw MokuroImportError.missingImage("(page \(idx) has no img_path)")
            }
            guard let sourceImage = locatePageImage(staging: staging, sourceRoot: sourceRoot, imgPath: imgPath) else {
                throw MokuroImportError.missingImage(imgPath)
            }
            let basename = uniqueBasename(sourceImage.lastPathComponent, taken: takenBasenames)
            takenBasenames.insert(basename)
            plannedBasenames.append(basename)
            plannedSources[basename] = sourceImage
            rewrittenPages[idx]["img_path"] = "\(imagesDir)/\(basename)"
        }

        // Determine the target directory. Dedupe a true re-import of the SAME volume (same title
        // + page count) by returning the existing book; otherwise uniquify the directory name so a
        // different volume that sanitizes to the same name never clears/overwrites an existing
        // book's images/bookmark/statistics (mirrors Android's createMokuroBookDirectory).
        let booksDir = try BookStorage.getBooksDirectory()
        let safeTitle = sanitizeFileName(title)
        let primaryRoot = booksDir.appendingPathComponent(safeTitle)
        if fileManager.fileExists(atPath: primaryRoot.path(percentEncoded: false)),
           let existing = BookStorage.loadMetadata(root: primaryRoot),
           existing.title == title,
           BookStorage.loadBookInfo(root: primaryRoot)?.characterCount == plannedBasenames.count {
            return existing
        }

        var folderName = safeTitle
        var suffix = 1
        while fileManager.fileExists(atPath: booksDir.appendingPathComponent(folderName).path(percentEncoded: false)) {
            folderName = "\(safeTitle)-\(suffix)"
            suffix += 1
        }
        let targetRoot = booksDir.appendingPathComponent(folderName)

        do {
            // Copy images into images/.
            let imagesTarget = targetRoot.appendingPathComponent(imagesDir, isDirectory: true)
            try fileManager.createDirectory(at: imagesTarget, withIntermediateDirectories: true)
            for basename in plannedBasenames {
                guard let source = plannedSources[basename] else { continue }
                let dest = imagesTarget.appendingPathComponent(basename)
                try? fileManager.removeItem(at: dest)
                try fileManager.copyItem(at: source, to: dest)
            }

            // Write the rewritten, unknown-field-preserving mokuro.json.
            var rewrittenRoot = rootObject
            rewrittenRoot["pages"] = rewrittenPages
            let rewrittenData = try JSONSerialization.data(
                withJSONObject: rewrittenRoot,
                options: [.prettyPrinted]
            )
            let mokuroDest = targetRoot.appendingPathComponent(FileNames.mokuro)
            try rewrittenData.write(to: mokuroDest, options: .atomic)

            // Generate the cover from the first page image.
            let coverRelative = "Books/\(folderName)/cover.jpg"
            var coverPath: String?
            if let firstBasename = plannedBasenames.first {
                let firstImage = imagesTarget.appendingPathComponent(firstBasename)
                let coverDest = targetRoot.appendingPathComponent("cover.jpg")
                do {
                    try MokuroCover.generateThumbnail(from: firstImage, to: coverDest)
                    coverPath = coverRelative
                } catch {
                    // A cover failure should not abort the import; the bookshelf tolerates a
                    // nil cover. Leave coverPath nil.
                    coverPath = nil
                }
            }

            let metadata = BookMetadata(
                title: title,
                cover: coverPath,
                folder: folderName,
                lastAccess: Date(),
                contentType: .mokuro,
                importedAt: rfc3339Now()
            )
            try BookStorage.save(metadata, inside: targetRoot, as: FileNames.metadata)

            // Page-based progress: total = page count, no per-chapter info.
            let bookInfo = BookInfo(characterCount: plannedBasenames.count, chapterInfo: [:])
            try BookStorage.save(bookInfo, inside: targetRoot, as: FileNames.bookinfo)

            return metadata
        } catch {
            // Clean up the partial book directory on any mid-way failure.
            try? fileManager.removeItem(at: targetRoot)
            throw error
        }
    }

    // MARK: - Location helpers

    /// Finds the single `.mokuro` JSON file anywhere within `root`. If several are present (a
    /// multi-volume archive) the shallowest, then alphabetically-first, one wins so the choice
    /// is deterministic — matching Android's `findMokuroFile`.
    private static func findMokuroFile(in root: URL) -> URL? {
        let candidates = allFiles(in: root).filter {
            $0.pathExtension.lowercased() == mokuroExtension
        }
        guard !candidates.isEmpty else { return nil }
        return candidates.min { lhs, rhs in
            let lDepth = relativeDepth(of: lhs, under: root)
            let rDepth = relativeDepth(of: rhs, under: root)
            if lDepth != rDepth { return lDepth < rDepth }
            return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
        }
    }

    /// Locates the page image referenced by a mokuro `img_path`.
    ///
    /// Mokuro's standard output keeps the `.mokuro` file as a *sibling* of the image folder,
    /// so `img_path` is relative to that folder rather than to the `.mokuro` file's own
    /// directory. Resolution therefore falls back from the strict interpretation to matching
    /// the `img_path` tail, then a unique basename, anywhere under the staging tree. Every
    /// candidate comes from a walk over `staging`, so results stay inside it (no traversal).
    private static func locatePageImage(staging: URL, sourceRoot: URL, imgPath: String) -> URL? {
        // 1. Strict: img_path relative to the .mokuro file's own directory.
        if let strict = resolveWithin(base: sourceRoot, relativePath: imgPath),
           isFile(strict) {
            return strict
        }

        let normalized = imgPath
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let trimmed = normalized.hasPrefix("/") ? String(normalized.drop { $0 == "/" }) : normalized
        guard !trimmed.isEmpty else { return nil }

        let allStagingFiles = allFiles(in: staging)

        // 2. Common mokuro layout: images in a sibling folder — match the img_path tail.
        if let tailMatch = allStagingFiles.first(where: { fileURL in
            fileURL.path(percentEncoded: false).hasSuffix("/\(trimmed)")
        }) {
            return tailMatch
        }

        // 3. Last resort: a single unambiguous basename match anywhere in the tree.
        let basename = String(trimmed.split(separator: "/").last ?? Substring(trimmed))
        let basenameMatches = allStagingFiles.filter { $0.lastPathComponent == basename }
        if basenameMatches.count == 1 {
            return basenameMatches[0]
        }
        return nil
    }

    /// Resolves `relativePath` against `base`, returning nil if it escapes `base`.
    private static func resolveWithin(base: URL, relativePath: String) -> URL? {
        let cleaned = relativePath.replacingOccurrences(of: "\\", with: "/")
        let resolved = base.appendingPathComponent(cleaned).standardizedFileURL
        let rootPath = base.standardizedFileURL.path(percentEncoded: false)
        let resolvedPath = resolved.path(percentEncoded: false)
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        if resolvedPath == rootPath || resolvedPath.hasPrefix(prefix) {
            return resolved
        }
        return nil
    }

    /// Returns a destination basename for `originalName` not already used in `taken`. Flattening
    /// to basenames can collide when a source nests images in differently-named subfolders; a
    /// numeric suffix keeps every page distinct — matching Android's `uniqueBasename`.
    private static func uniqueBasename(_ originalName: String, taken: Set<String>) -> String {
        if !taken.contains(originalName) { return originalName }
        let url = URL(fileURLWithPath: originalName)
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        var index = 1
        while taken.contains("\(stem)-\(index)\(suffix)") { index += 1 }
        return "\(stem)-\(index)\(suffix)"
    }

    // MARK: - Filesystem walk helpers

    /// All regular files under `root` (recursive), skipping hidden files.
    private static func allFiles(in root: URL) -> [URL] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            if isFile(url) {
                files.append(url)
            }
        }
        return files
    }

    private static func isFile(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDir)
        return exists && !isDir.boolValue
    }

    /// Number of path separators between `url` and `root` — i.e. nesting depth.
    private static func relativeDepth(of url: URL, under root: URL) -> Int {
        let rootComponents = root.standardizedFileURL.pathComponents
        let urlComponents = url.standardizedFileURL.pathComponents
        guard urlComponents.count > rootComponents.count else { return 0 }
        // Components below root, minus the file name itself.
        return urlComponents.count - rootComponents.count - 1
    }

    // MARK: - Title sanitization

    /// Mirrors `BookshelfViewModel.sanitizeFileName` so EPUB and mokuro imports name book
    /// directories identically.
    private static func sanitizeFileName(_ string: String) -> String {
        string
            .components(separatedBy: CharacterSet(charactersIn: "\\/:*?\"<>|").union(.newlines).union(.controlCharacters))
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    /// Kotlin `String.ifBlank { null }`: nil if empty or all-whitespace.
    var nonBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
