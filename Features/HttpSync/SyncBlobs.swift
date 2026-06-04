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

nonisolated struct HttpSyncMetadataBlob: Codable, Equatable {
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

    /// Explicit encode so EVERY key is always emitted, with `null` for absent values. Android's
    /// kotlinx.serialization uses `explicitNulls = true` (the default) + `encodeDefaults = true`,
    /// so it always writes `"shelfName": null` etc. The reconciler's shelf-presence detection
    /// uses `containsKey`, so byte-matching that "field is present even when null" behavior is
    /// load-bearing — the synthesized `Codable` encoder would otherwise omit nil optionals and
    /// silently change shelf-sync semantics across platforms.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        try c.encode(contentType, forKey: .contentType)
        try c.encode(shelfName, forKey: .shelfName)
        try c.encode(shelfUpdatedAt, forKey: .shelfUpdatedAt)
        try c.encode(importedAt, forKey: .importedAt)
        try c.encode(deletedAt, forKey: .deletedAt)
    }
}

nonisolated struct HttpSyncBookmarkBlob: Codable, Equatable {
    let chapterIndex: Int
    let progress: Double
    let characterCount: Int
    /// RFC 3339 UTC — LWW tiebreaker when pulling.
    let lastModified: String
}

nonisolated struct HttpSyncChatEntryBlob: Codable, Equatable {
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

    /// Explicit encode so the optional `screenshotImage` / `dictionaryLookup` keys are always
    /// emitted (as `null` when absent), matching Android's `explicitNulls = true`. The chat key is
    /// content-addressed by bubbleText/timestamp/response so this doesn't affect dedup, but keeping
    /// the bytes identical avoids any server-side etag drift between platforms.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bubbleText, forKey: .bubbleText)
        try c.encode(prompt, forKey: .prompt)
        try c.encode(model, forKey: .model)
        try c.encode(response, forKey: .response)
        try c.encode(timestampSeconds, forKey: .timestampSeconds)
        try c.encode(screenshotImage, forKey: .screenshotImage)
        try c.encode(dictionaryLookup, forKey: .dictionaryLookup)
    }
}

/// Cross-device ChatGPT settings (model + prompts). The API key is intentionally NOT here — it
/// stays per-device. `lastModified` is the LWW tiebreaker.
nonisolated struct HttpSyncAiChatSettingsBlob: Codable, Equatable {
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
nonisolated struct HttpSyncPayloadManifest: Codable, Equatable {
    let sha256: String
    let sizeBytes: Int
    let originalName: String
    let format: ContentType
}

// MARK: - KV server wire records (content-blind store)

/// Metadata for one key, as returned by the list endpoint and write responses.
nonisolated struct HttpSyncKvKeyMeta: Codable, Equatable {
    let key: String
    let lastModified: String
    var etag: String?
    var size: Int?
    var contentType: String?

    enum CodingKeys: String, CodingKey { case key, lastModified, etag, size, contentType }

    /// Memberwise init so the transport can synthesize a write response from the multipart-complete
    /// reply (which has a different JSON shape than this struct).
    init(key: String, lastModified: String, etag: String? = nil, size: Int? = nil, contentType: String? = nil) {
        self.key = key
        self.lastModified = lastModified
        self.etag = etag
        self.size = size
        self.contentType = contentType
    }

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
nonisolated struct HttpSyncKvList: Codable, Equatable {
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
