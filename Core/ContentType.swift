//
//  ContentType.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Whether a book directory holds a reflowable EPUB or a mokuro manga volume. Serialized as
/// `"epub"` / `"mokuro"` to match the Android sync wire format.
enum ContentType: String, Codable, Hashable {
    case epub
    case mokuro
}

extension ContentType {
    /// Detects a book directory's type by the presence of the `mokuro.json` sidecar. This is the
    /// routing source of truth (a stored `BookMetadata.contentType` is a hint/fallback).
    static func detect(bookDir: URL) -> ContentType {
        let mokuro = bookDir.appendingPathComponent(FileNames.mokuro)
        return FileManager.default.fileExists(atPath: mokuro.path(percentEncoded: false)) ? .mokuro : .epub
    }
}
