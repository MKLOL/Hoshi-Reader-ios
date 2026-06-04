//
//  ArchiveExtractor.swift
//  EPUBKit
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Generic zip extraction helper used by the mokuro manga importer. EPUBKit already links
//  ZipArchive (see EPUBArchiveService.swift), so exposing one thin, public entry point lets
//  the app extract `.zip`/`.cbz` bundles without taking a second zip dependency.
//

import Foundation
import ZipArchive

/// Extracts arbitrary zip archives (`.zip`/`.cbz`) into a destination directory.
///
/// Used by the mokuro importer to stage a manga bundle before assembling the on-disk book
/// layout. Extraction is guarded against path traversal ("zip-slip"): SSZipArchive already
/// rejects traversing entries, and this wrapper re-validates every extracted entry stays
/// within `destination` as defense in depth.
public enum ArchiveExtractor {
    public enum ExtractionError: LocalizedError {
        case unzipFailed(path: String)
        case pathTraversal(entry: String)

        public var errorDescription: String? {
            switch self {
            case .unzipFailed(let path):
                return "Failed to unzip archive at \(path)."
            case .pathTraversal(let entry):
                return "Unsafe archive entry detected: \(entry)."
            }
        }
    }

    /// Unzips `archiveURL` into `destination`, creating `destination` if needed.
    ///
    /// - Throws: `ExtractionError.unzipFailed` if the archive cannot be extracted, or
    ///   `ExtractionError.pathTraversal` if any extracted entry escapes `destination`.
    public static func unzip(_ archiveURL: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: destination.path) {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        }

        let success = SSZipArchive.unzipFile(atPath: archiveURL.path, toDestination: destination.path)
        guard success else {
            throw ExtractionError.unzipFailed(path: archiveURL.path)
        }

        try validateNoTraversal(in: destination)
    }

    /// Defense in depth: walk the extracted tree and confirm every file resolves to a path
    /// inside `destination`. A symlink or crafted entry pointing outside is rejected.
    private static func validateNoTraversal(in destination: URL) throws {
        let fileManager = FileManager.default
        let rootPath = destination.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"

        guard let enumerator = fileManager.enumerator(
            at: destination,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return
        }

        for case let fileURL as URL in enumerator {
            let resolved = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
            if resolved != rootPath && !resolved.hasPrefix(prefix) {
                throw ExtractionError.pathTraversal(entry: fileURL.lastPathComponent)
            }
        }
    }
}
