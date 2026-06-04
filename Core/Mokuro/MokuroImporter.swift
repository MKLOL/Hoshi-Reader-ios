//
//  MokuroImporter.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  PHASE 0 CONTRACT STUB — replaced by Agent A with the real implementation. Keep the public
//  `importBundle(from:)` signature so the bookshelf import call site stays stable.
//

import Foundation

enum MokuroImportError: LocalizedError {
    case noMokuroFile
    case noPages
    case unreadable(Error)

    var errorDescription: String? {
        switch self {
        case .noMokuroFile: return "No mokuro.json found in the selected manga."
        case .noPages: return "The mokuro file contains no pages."
        case .unreadable(let error): return "Could not import manga: \(error.localizedDescription)"
        }
    }
}

struct MokuroImporter {
    /// Imports a `.zip`/`.cbz` bundle or a folder containing a `.mokuro` sidecar + images into the
    /// Books directory, writing the canonical `mokuro.json`, `images/`, `metadata.json` (with
    /// `contentType = .mokuro` and `importedAt`), `bookinfo.json`, and a downsampled cover.
    /// Returns the created book's metadata.
    static func importBundle(from sourceURL: URL) throws -> BookMetadata {
        throw MokuroImportError.noMokuroFile // stub
    }
}
