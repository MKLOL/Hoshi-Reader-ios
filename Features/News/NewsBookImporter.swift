//
//  NewsBookImporter.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Registers an article written by `NewsArticleEpubWriter` as a library book. Mirrors what
//  `BookshelfViewModel.finalizeImport` does for a picked `.epub` (cover, metadata, bookinfo, sync
//  notification) and what `MokuroImporter` does for a programmatic import, without touching either.
//

import EPUBKit
import Foundation

struct NewsBookImportError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
enum NewsBookImporter {
    /// Shelf name is book data shared with other devices, so it is not localized.
    static let newsShelfName = "News"

    /// Moves the extracted EPUB tree at `stagingRoot` under `Books/<folderName>/`, writes the
    /// sidecars, publishes the book to sync and returns its metadata. `stagingRoot` is removed on
    /// failure.
    static func register(stagingRoot: URL, folderName: String) throws -> BookMetadata {
        let fm = FileManager.default
        let document: EPUBDocument
        do {
            document = try BookStorage.loadEpub(stagingRoot)
        } catch {
            try? fm.removeItem(at: stagingRoot)
            throw NewsBookImportError(message: "The article could not be parsed as a book: \(error.localizedDescription)")
        }
        let booksDir = try BookStorage.getBooksDirectory()
        let bookFolder = booksDir.appendingPathComponent(folderName, isDirectory: true)
        if fm.fileExists(atPath: bookFolder.path(percentEncoded: false)) {
            try? fm.removeItem(at: stagingRoot)
            throw NewsBookImportError(message: "A book directory named \(folderName) already exists")
        }
        try fm.moveItem(at: stagingRoot, to: bookFolder)
        do {
            // Re-parse from the final location so manifest paths resolve against it.
            let placed = try BookStorage.loadEpub(bookFolder)
            var coverPath: String?
            if let coverItem = placed.manifest.items.values.first(where: { $0.property?.contains("cover-image") == true }) {
                let source = placed.contentDirectory.appendingPathComponent(coverItem.path)
                let destination = "Books/\(folderName)/\(URL(fileURLWithPath: coverItem.path).lastPathComponent)"
                try BookStorage.copyFile(from: source, to: destination)
                coverPath = destination
            }
            let metadata = BookMetadata(
                title: placed.title ?? document.title,
                cover: coverPath,
                folder: folderName,
                lastAccess: Date(),
                contentType: .epub,
                importedAt: rfc3339Now(),
                syncId: deriveSyncId(placed.title ?? document.title, folderName: folderName)
            )
            try BookStorage.save(metadata, inside: bookFolder, as: FileNames.metadata)
            try BookStorage.save(BookProcessor.process(document: placed), inside: bookFolder, as: FileNames.bookinfo)
            // Publish the new book's metadata immediately (payload uploads on manual sync).
            HttpSyncManager.shared.onBookImported(book: metadata)
            return metadata
        } catch {
            try? fm.removeItem(at: bookFolder)
            throw error
        }
    }

    /// Puts the book on the News shelf, creating the shelf when needed, and notifies sync.
    static func addToNewsShelf(_ book: BookMetadata) throws {
        let booksDir = try BookStorage.getBooksDirectory()
        var shelves = BookStorage.loadShelves() ?? []
        for index in shelves.indices {
            shelves[index].bookIds.removeAll { $0 == book.id }
        }
        if let index = shelves.firstIndex(where: { $0.name == newsShelfName }) {
            shelves[index].bookIds.append(book.id)
        } else {
            shelves.append(BookShelf(name: newsShelfName, bookIds: [book.id]))
        }
        try BookStorage.save(shelves, inside: booksDir, as: FileNames.shelves)
        HttpSyncManager.shared.onShelfPlacementChanged(book: book, shelfName: newsShelfName)
    }

    /// `Books/` directory name: readable title plus a URL hash so two articles never collide.
    static func folderName(title: String, url: String) -> String {
        let unsafe = CharacterSet(charactersIn: "\\/:*?\"<>| ").union(.newlines).union(.controlCharacters)
        let cleaned = title.components(separatedBy: unsafe).joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = String(cleaned.prefix(60))
        return "\(safe.isEmpty ? "article" : safe)-\(sha256Hex(url).prefix(8))"
    }

    static func bookExists(id: UUID) -> Bool {
        ((try? BookStorage.loadAllBooks()) ?? []).contains { $0.id == id }
    }
}
