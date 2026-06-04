//
//  MokuroBookParser.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Parses the `mokuro.json` sidecar — the raw mokuro tool output, copied verbatim into the
//  book directory by the importer — into a `MokuroBook`. Pure Swift/Foundation: unlike the
//  EPUB parser this has no native dependency, since the mokuro format is already structured
//  JSON. Ported from the Android `MokuroBookParser`.
//

import Foundation

/// Parses `mokuro.json` book sidecars into reader-facing `MokuroBook` models.
///
/// Holds a single-entry cache keyed by (sidecar path, mtime, size). The book-open path parses
/// the same `mokuro.json` more than once in quick succession (once when the bookshelf reads
/// metadata, once when the reader loads), so coalescing those into one parse + decode avoids
/// re-reading a large sidecar. The cache clears automatically when the file changes.
final class MokuroBookParser: @unchecked Sendable {
    /// Shared instance so the bookshelf and reader share one cache entry.
    static let shared = MokuroBookParser()

    private struct CachedParse {
        let path: String
        let mtime: Date?
        let size: Int
        let book: MokuroBook
    }

    private let lock = NSLock()
    private var cached: CachedParse?

    /// Parses `bookRoot/mokuro.json`.
    ///
    /// - Throws: `MokuroImportError.noMokuroFile` if the sidecar is missing,
    ///   `MokuroImportError.noPages` if it decodes to zero pages, and
    ///   `MokuroImportError.unreadable` for malformed JSON or read failures.
    func parse(bookRoot: URL) throws -> MokuroBook {
        let sidecar = bookRoot.appendingPathComponent(FileNames.mokuro)
        let path = sidecar.path(percentEncoded: false)

        guard FileManager.default.fileExists(atPath: path) else {
            throw MokuroImportError.noMokuroFile
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let mtime = attrs?[.modificationDate] as? Date
        let size = (attrs?[.size] as? Int) ?? -1

        lock.lock()
        if let hit = cached, hit.path == path, hit.mtime == mtime, hit.size == size {
            let book = hit.book
            lock.unlock()
            return book
        }
        lock.unlock()

        let data: Data
        do {
            data = try Data(contentsOf: sidecar)
        } catch {
            throw MokuroImportError.unreadable(error)
        }

        let raw: RawMokuro
        do {
            raw = try JSONDecoder().decode(RawMokuro.self, from: data)
        } catch {
            throw MokuroImportError.unreadable(error)
        }

        guard let book = raw.toMokuroBook(fallbackTitle: bookRoot.lastPathComponent) else {
            throw MokuroImportError.noPages
        }

        lock.lock()
        cached = CachedParse(path: path, mtime: mtime, size: size, book: book)
        lock.unlock()

        return book
    }
}
