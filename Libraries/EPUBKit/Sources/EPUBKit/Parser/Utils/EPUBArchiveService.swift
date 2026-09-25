//
//  EPUBArchiveService.swift
//  EPUBKit
//
//  Created by Witek Bobrowski on 30/06/2018.
//  Copyright © 2018 Witek Bobrowski. All rights reserved.
//

import Foundation

/// Protocol defining the interface for EPUB archive extraction operations.
///
/// This protocol abstracts the archive extraction functionality, allowing for
/// different implementations of ZIP extraction mechanisms.
protocol EPUBArchiveService {
    /// Extracts the contents of an EPUB archive to a temporary directory.
    ///
    /// - Parameter url: The file URL of the EPUB archive to extract.
    /// - Returns: The URL of the directory containing the extracted contents.
    /// - Throws: `EPUBParserError.unzipFailed` if extraction fails.
    func unarchive(archive url: URL) throws -> URL
}

/// Stages each extraction independently so another parser cannot observe a partial archive.
/// A first import retains the historical sibling directory used by the app's import flow.
/// Existing directories are never replaced or trusted as evidence that an archive is valid.
class EPUBArchiveServiceImplementation: EPUBArchiveService {
    func unarchive(archive url: URL) throws -> URL {
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory.appendingPathComponent("EPUB-\(UUID().uuidString)", isDirectory: true)
        do {
            try ArchiveExtractor.unzip(url, to: staging)
            let sourceDirectory = url.deletingLastPathComponent()
            guard fileManager.isWritableFile(atPath: sourceDirectory.path) else { return staging }
            let destination = URL(fileURLWithPath: url.deletingPathExtension().path, isDirectory: true)
            // Parsing the same archive again must validate its bytes, and must not overwrite a
            // previously imported book's bookmarks or other sidecars. Keep this extraction private.
            guard !fileManager.fileExists(atPath: destination.path) else { return staging }
            do {
                try fileManager.moveItem(at: staging, to: destination)
                return destination
            } catch {
                // A concurrent parser may have published its own complete extraction first.
                if fileManager.fileExists(atPath: destination.path) { return staging }
                throw error
            }
        } catch {
            try? fileManager.removeItem(at: staging)
            throw EPUBParserError.unzipFailed(reason: error)
        }
    }
}
