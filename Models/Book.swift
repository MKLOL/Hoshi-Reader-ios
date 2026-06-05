//
//  Book.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

enum SortOption: String, CaseIterable, Identifiable {
    case recent = "Recent"
    case title = "Title"
    
    var id: String { self.rawValue }
    var icon: String {
        switch self {
        case .recent: return "clock"
        case .title: return "textformat"
        }
    }
}

struct BookMetadata: Codable, Identifiable, Hashable {
    let id: UUID
    let title: String?
    var cover: String?
    let folder: String?
    var lastAccess: Date
    /// EPUB vs mokuro manga. Optional for backward compatibility: metadata written before this
    /// field existed decodes as `nil` and is treated as `.epub` (see `resolvedContentType`).
    var contentType: ContentType?
    /// RFC 3339 UTC — when the book was first imported on this device. Used by HTTP sync's
    /// re-import-after-tombstone guard. Optional for legacy metadata.
    var importedAt: String?
    /// Stable HTTP-sync key for this local book. Optional for legacy metadata; sync backfills it
    /// from title + folder so duplicate/sanitized-colliding manga volumes do not share one key.
    var syncId: String?

    init(id: UUID = UUID(), title: String?, cover: String?, folder: String?, lastAccess: Date,
         contentType: ContentType? = nil, importedAt: String? = nil, syncId: String? = nil) {
        self.id = id
        self.title = title
        self.cover = cover
        self.folder = folder
        self.lastAccess = lastAccess
        self.contentType = contentType
        self.importedAt = importedAt
        self.syncId = syncId
    }

    /// The content type, defaulting to `.epub` for legacy metadata that predates the field.
    var resolvedContentType: ContentType { contentType ?? .epub }
}

struct Bookmark: Codable {
    let chapterIndex: Int
    let progress: Double
    let characterCount: Int
    var lastModified: Date?
}

struct BookInfo: Codable {
    let characterCount: Int
    let chapterInfo: [String: ChapterInfo]
    
    struct ChapterInfo: Codable {
        let spineIndex: Int?
        let currentTotal: Int
        let chapterCount: Int
    }
    
    func resolveCharacterPosition(_ characterCount: Int) -> (spineIndex: Int, progress: Double)? {
        let clamped = max(0, min(characterCount, self.characterCount - 1))
        for chapter in chapterInfo.values {
            guard let spineIndex = chapter.spineIndex, chapter.chapterCount > 0 else {
                continue
            }
            let start = chapter.currentTotal
            let end = start + chapter.chapterCount
            if clamped >= start && clamped < end {
                let progress = Double(clamped - start) / Double(chapter.chapterCount)
                return (spineIndex, progress)
            }
        }
        return nil
    }
}

struct BookShelf: Codable {
    let name: String
    var bookIds: [UUID]
}
