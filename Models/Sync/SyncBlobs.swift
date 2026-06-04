//
//  SyncBlobs.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  The Hoshi-specific JSON schemas serialized into the bytes PUT to each KV key, and the KV
//  server's own wire records. Field names MUST match the Android client
//  (features/sync/http/HttpSyncBlobs.kt + HttpSyncKv.kt) since both talk to the same server.
//
//  Key layout (also in docs/HTTP_SYNC_KV.md):
//    books/{syncId}/metadata          -> HttpSyncMetadataBlob   (overwrite)
//    books/{syncId}/bookmark          -> HttpSyncBookmarkBlob    (overwrite per page-turn batch)
//    books/{syncId}/chat/{ts}-{hash}  -> HttpSyncChatEntryBlob   (write-once)
//    books/{syncId}/payload.zip       -> bytes (application/zip)
//    books/{syncId}/payload.manifest  -> JSON
//    app/ai_chat_settings             -> HttpSyncAiChatSettingsBlob
//

import Foundation

// MARK: - Per-key Hoshi blob shapes

struct HttpSyncMetadataBlob: Codable, Equatable {
    let title: String
    let contentType: ContentType
    /// Shelf/folder placement. `nil` means intentionally unshelved. Omission ("leave the local
    /// shelf alone") is distinguished from `nil` by the reconciler via `shelfUpdatedAt`.
    var shelfName: String?
    /// RFC 3339 UTC — when local shelf organization last changed.
    var shelfUpdatedAt: String?
    /// RFC 3339 UTC — when the book was first imported on this device.
    var importedAt: String?
    /// RFC 3339 UTC — set when the user deletes the book; other devices honour it (tombstone).
    var deletedAt: String?

    init(title: String, contentType: ContentType, shelfName: String? = nil,
         shelfUpdatedAt: String? = nil, importedAt: String? = nil, deletedAt: String? = nil) {
        self.title = title
        self.contentType = contentType
        self.shelfName = shelfName
        self.shelfUpdatedAt = shelfUpdatedAt
        self.importedAt = importedAt
        self.deletedAt = deletedAt
    }

    enum CodingKeys: String, CodingKey {
        case title, contentType, shelfName, shelfUpdatedAt, importedAt, deletedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        contentType = try c.decode(ContentType.self, forKey: .contentType)
        shelfName = try c.decodeIfPresent(String.self, forKey: .shelfName)
        shelfUpdatedAt = try c.decodeIfPresent(String.self, forKey: .shelfUpdatedAt)
        importedAt = try c.decodeIfPresent(String.self, forKey: .importedAt)
        deletedAt = try c.decodeIfPresent(String.self, forKey: .deletedAt)
    }
}

struct HttpSyncBookmarkBlob: Codable, Equatable {
    let chapterIndex: Int
    let progress: Double
    let characterCount: Int
    /// RFC 3339 UTC — LWW tiebreaker when pulling.
    let lastModified: String
}

struct HttpSyncChatEntryBlob: Codable, Equatable {
    let bubbleText: String
    let prompt: String
    let model: String
    let response: String
    /// Apple-reference seconds, the same epoch the on-disk `ai_chat_log.json` uses.
    let timestampSeconds: Double
    var screenshotImage: AiChatImage?
    var dictionaryLookup: AiChatDictionaryLookup?

    init(bubbleText: String, prompt: String, model: String, response: String, timestampSeconds: Double,
         screenshotImage: AiChatImage? = nil, dictionaryLookup: AiChatDictionaryLookup? = nil) {
        self.bubbleText = bubbleText
        self.prompt = prompt
        self.model = model
        self.response = response
        self.timestampSeconds = timestampSeconds
        self.screenshotImage = screenshotImage
        self.dictionaryLookup = dictionaryLookup
    }

    enum CodingKeys: String, CodingKey {
        case bubbleText, prompt, model, response, timestampSeconds, screenshotImage, dictionaryLookup
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bubbleText = try c.decode(String.self, forKey: .bubbleText)
        prompt = try c.decode(String.self, forKey: .prompt)
        model = try c.decode(String.self, forKey: .model)
        response = try c.decode(String.self, forKey: .response)
        timestampSeconds = try c.decode(Double.self, forKey: .timestampSeconds)
        screenshotImage = try c.decodeIfPresent(AiChatImage.self, forKey: .screenshotImage)
        dictionaryLookup = try c.decodeIfPresent(AiChatDictionaryLookup.self, forKey: .dictionaryLookup)
    }
}

/// Cross-device ChatGPT settings (model + prompts). The API key is intentionally NOT here — it
/// stays per-device. `lastModified` is the LWW tiebreaker.
struct HttpSyncAiChatSettingsBlob: Codable, Equatable {
    let model: String
    let promptText: String
    var imagePromptText: String
    let lastModified: String

    init(model: String, promptText: String, imagePromptText: String, lastModified: String) {
        self.model = model
        self.promptText = promptText
        self.imagePromptText = imagePromptText
        self.lastModified = lastModified
    }

    enum CodingKeys: String, CodingKey { case model, promptText, imagePromptText, lastModified }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decode(String.self, forKey: .model)
        promptText = try c.decode(String.self, forKey: .promptText)
        imagePromptText = try c.decodeIfPresent(String.self, forKey: .imagePromptText) ?? ""
        lastModified = try c.decode(String.self, forKey: .lastModified)
    }
}

/// Manifest describing a book's payload.zip.
struct HttpSyncPayloadManifest: Codable, Equatable {
    let sha256: String
    let sizeBytes: Int
    let originalName: String
    let format: ContentType
}

// MARK: - KV server wire records (content-blind store)

/// Metadata for one key, as returned by the list endpoint and write responses.
struct HttpSyncKvKeyMeta: Codable, Equatable {
    let key: String
    let lastModified: String
    var etag: String?
    var size: Int?
    var contentType: String?

    enum CodingKeys: String, CodingKey { case key, lastModified, etag, size, contentType }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        lastModified = try c.decodeIfPresent(String.self, forKey: .lastModified) ?? ""
        etag = try c.decodeIfPresent(String.self, forKey: .etag)
        size = try c.decodeIfPresent(Int.self, forKey: .size)
        contentType = try c.decodeIfPresent(String.self, forKey: .contentType)
    }
}

/// Response of `GET /v1/kv?prefix=&since=&cursor=&limit=`.
struct HttpSyncKvList: Codable, Equatable {
    var keys: [HttpSyncKvKeyMeta]
    var truncated: Bool?
    var nextCursor: String?

    enum CodingKeys: String, CodingKey { case keys, truncated, nextCursor }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keys = try c.decodeIfPresent([HttpSyncKvKeyMeta].self, forKey: .keys) ?? []
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated)
        nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
    }
}

/// Response of a `PUT /v1/kv/{key}` (or multipart complete).
typealias HttpSyncKvWriteResponse = HttpSyncKvKeyMeta
