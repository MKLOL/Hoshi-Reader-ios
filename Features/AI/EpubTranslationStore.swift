//
//  EpubTranslationStore.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Reads a novel's offline sentence-translation cache (`sentence_translations.json`, synced from
//  `books/{syncId}/sentences`) and answers two questions for the reader:
//
//    1. "which sentences in chapter N have a translation, and where are they?"  → `anchors(spine:)`
//    2. "the reader pressed the button with this id, what does it say?"         → `lookup(id:)`
//
//  The EPUB counterpart of `PretranslationStore`. Same contract: produced ahead of time by the
//  desktop tool, strictly read-only, and never written into `ai_chat_log.json` — a cache hit is not
//  a conversation the user had.
//
//  Sentence addressing: `c{spine}s{normalizedStart}`, where the offset counts only *matchable*
//  characters (`String.filtered()`'s class) from the start of the chapter. That is the same space
//  Sasayaki cues live in, which is why `reader.js` can already turn one back into a DOM range.
//
//  `nonisolated` + an explicit lock, like PretranslationStore: the sync reconciler invalidates this
//  after writing a fresh blob, and that code resumes OFF the main actor after its `await`s.
//

import Foundation
import CryptoKit

/// One resolved offline translation for a sentence.
nonisolated struct SentenceTranslation: Equatable {
    let id: String
    let sentenceText: String
    let translation: String
    let explanation: String
    /// The model that produced it, so a cached reply is never mistaken for a live one.
    let model: String

    /// The popup renders Markdown, so present it exactly as the online tutor reply is presented.
    var markdownResponse: String {
        explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? translation
            : "\(translation)\n\n\(explanation)"
    }
}

/// Where a sentence's translate button goes, in the chapter's normalized-character offset space.
/// Serialized to the web view as `{id, start, len, hash}` — the same shape Sasayaki cues use.
nonisolated struct SentenceAnchor: Equatable, Encodable {
    let id: String
    let start: Int
    let len: Int
    /// The sentence's NORMALIZED text. `translations.js` compares this against what it finds at
    /// `start` before placing a button, and falls back to searching for it when the offset is
    /// stale — so a chapter that changed since the blob was made shows no button rather than the
    /// wrong translation.
    ///
    /// The text itself rather than a hash of it: the comparison is exact either way, but this
    /// keeps SHA-256 out of the web view (Web Crypto's digest is async-only, which would turn a
    /// single synchronous DOM walk into a promise chain) and it is what makes the fallback search
    /// possible. One chapter's anchors are a few KB.
    let text: String
}

nonisolated final class EpubTranslationStore: @unchecked Sendable {
    static let shared = EpubTranslationStore()

    private let lock = NSLock()

    private struct Loaded {
        let blob: HttpSyncSentencesBlob
        let expectedSyncId: String
        let expectedSpineCount: Int
        /// Anchors grouped by spine index and sorted by offset, so a chapter load is one lookup
        /// rather than a scan of every sentence in the book.
        let anchorsBySpine: [Int: [SentenceAnchor]]
    }

    /// Keyed by book folder name. A novel's blob is a few MB, so the parsed form is cached — the
    /// reader only ever has one book open.
    private var cache: [String: Loaded] = [:]
    /// Invalidating while an off-main preload is decoding must also prevent that old decode from
    /// repopulating the cache after a replacement blob has landed.
    private var generations: [String: UInt64] = [:]

    private init() {}

    // MARK: - Cache lifecycle

    static func invalidate(root: URL) {
        shared.invalidate(root: root)
    }

    func invalidate(root: URL) {
        lock.lock()
        defer { lock.unlock() }
        let folder = root.lastPathComponent
        cache.removeValue(forKey: folder)
        generations[folder, default: 0] &+= 1
    }

    func invalidateAll() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
        let folders = Array(generations.keys)
        for folder in folders {
            generations[folder, default: 0] &+= 1
        }
    }

    /// Parses the blob if it isn't cached yet. Call this off the main thread when the reader opens:
    /// a novel's blob is 1–5 MB and decoding it on the main actor would hitch the first page turn.
    @discardableResult
    func preload(folder: String, expectedSyncId: String, spineCount: Int) -> Bool {
        lock.lock()
        if let loaded = cache[folder],
           loaded.expectedSyncId == expectedSyncId,
           loaded.expectedSpineCount == spineCount {
            lock.unlock()
            return true
        }
        let generation = generations[folder, default: 0]
        lock.unlock()

        // File IO and the multi-megabyte JSON decode deliberately happen without the lock. Reader
        // queries therefore return no button while loading instead of blocking the main actor.
        let loaded = readFromDisk(
            folder: folder,
            expectedSyncId: expectedSyncId,
            spineCount: spineCount
        )
        lock.lock()
        defer { lock.unlock() }
        guard generations[folder, default: 0] == generation else { return false }
        if let loaded { cache[folder] = loaded }
        return loaded != nil
    }

    // MARK: - Queries

    /// True when this book has any offline sentence translations.
    func hasTranslations(folder: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cache[folder] != nil
    }

    /// Number of translated sentences, for settings/diagnostics display.
    func count(folder: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return cache[folder]?.blob.entries.count ?? 0
    }

    /// Every translated sentence in one chapter, in reading order.
    func anchors(folder: String, expectedSyncId: String, spineCount: Int, spine: Int) -> [SentenceAnchor] {
        lock.lock()
        defer { lock.unlock() }
        guard let loaded = validatedCache(
            folder: folder,
            expectedSyncId: expectedSyncId,
            spineCount: spineCount
        ) else { return [] }
        return loaded.anchorsBySpine[spine] ?? []
    }

    /// Resolves a pressed button.
    func lookup(id: String, folder: String) -> SentenceTranslation? {
        lock.lock()
        defer { lock.unlock() }
        return lookup(id: id, loaded: cache[folder])
    }

    /// Contextual lookup used by the reader. A matching folder name is insufficient after a
    /// delete/re-import: both the persisted sync identity and the loaded EPUB spine count must agree.
    func lookup(id: String, folder: String, expectedSyncId: String, spineCount: Int) -> SentenceTranslation? {
        lock.lock()
        defer { lock.unlock() }
        return lookup(
            id: id,
            loaded: validatedCache(
                folder: folder,
                expectedSyncId: expectedSyncId,
                spineCount: spineCount
            )
        )
    }

    private func lookup(id renderedId: String, loaded: Loaded?) -> SentenceTranslation? {
        guard let loaded,
              let separator = renderedId.lastIndex(of: "#") else {
            return nil
        }
        let id = String(renderedId[..<separator])
        let renderedHash = String(renderedId[renderedId.index(after: separator)...])
        guard let entry = loaded.blob.entries[id], entry.hash == renderedHash else { return nil }
        return SentenceTranslation(
            id: id,
            sentenceText: entry.text,
            translation: entry.translation,
            explanation: entry.explanation,
            model: loaded.blob.model
        )
    }

    // MARK: - Loading

    private func validatedCache(folder: String, expectedSyncId: String, spineCount: Int) -> Loaded? {
        guard let loaded = cache[folder],
              loaded.expectedSyncId == expectedSyncId,
              loaded.expectedSpineCount == spineCount else { return nil }
        return loaded
    }

    /// The Books directory, resolved without `BookStorage` (main-actor isolated, so unreachable
    /// from this deliberately `nonisolated` type). Mirrors `BookStorage.getBooksDirectory()`.
    private static func booksDirectory() -> URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Books")
    }

    private func readFromDisk(folder: String, expectedSyncId: String, spineCount: Int) -> Loaded? {
        guard let booksDir = Self.booksDirectory() else { return nil }
        let url = booksDir
            .appendingPathComponent(folder)
            .appendingPathComponent(FileNames.sentenceTranslations)
        guard let data = try? Data(contentsOf: url),
              let blob = try? JSONDecoder().decode(HttpSyncSentencesBlob.self, from: data),
              blob.validationError(expectedSyncId: expectedSyncId, spineCount: spineCount) == nil
        else { return nil }

        var anchorsBySpine: [Int: [SentenceAnchor]] = [:]
        for (id, entry) in blob.entries {
            let normalized = Self.normalize(entry.text)
            anchorsBySpine[entry.spine, default: []].append(
                // Include the validated source hash in the rendered identity. If sync replaces the
                // cache while this page stays open, an old button can never resolve to unrelated
                // text at a reused c{spine}s{start} address.
                SentenceAnchor(id: "\(id)#\(entry.hash)", start: entry.start, len: entry.len, text: normalized)
            )
        }
        let spines = Array(anchorsBySpine.keys)
        for spine in spines {
            // The web view walks the chapter once in document order, so anchors must arrive sorted.
            anchorsBySpine[spine]?.sort { $0.start < $1.start }
        }
        return Loaded(
            blob: blob,
            expectedSyncId: expectedSyncId,
            expectedSpineCount: spineCount,
            anchorsBySpine: anchorsBySpine
        )
    }

    /// The reader's "matchable character" class — kana, kanji, radicals, ASCII/fullwidth
    /// alphanumerics — which is the offset space sentence addresses are counted in.
    ///
    /// Deliberately a local copy of the character class in `String.filtered()`
    /// (`Util/Extensions.swift`) rather than a call to it. `filtered()` is main-actor isolated by
    /// the project default, and this type is `nonisolated` on purpose so the sync reconciler can
    /// invalidate it off the main actor. Marking `filtered()` `nonisolated` to share it was tried
    /// and rejected: it perturbs overload resolution for the C++-interop `String.init(std.string)`
    /// and breaks `PopupView`. The character class is a stable on-the-wire contract shared with
    /// `reader.js` and the Python tool, so pinning it here is safe — the same reasoning as
    /// `httpSyncPayloadExcludedFiles`.
    ///
    /// Only the character filter, not `filtered()`'s markup handling: a blob's sentence text is
    /// already plain text, which makes this exactly `hoshiReader.normalizeText`.
    static func normalize(_ text: String) -> String {
        text.replacingOccurrences(
            of: "[^0-9A-Za-z○◯々-〇〻ぁ-ゖゝ-ゞァ-ヺー０-９Ａ-Ｚａ-ｚｦ-ﾝ\\p{Radical}\\p{Unified_Ideograph}]",
            with: "",
            options: .regularExpression
        )
    }

    /// Short sha256 of a sentence's normalized text. Must match the writer in
    /// tools/pretranslate/hoshi_pretranslate/epub.py (`text_hash`).
    static func textHash(_ normalizedText: String) -> String {
        let digest = SHA256.hash(data: Data(normalizedText.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).lowercased()
    }
}

// MARK: - Fail-closed EPUB sentence blob contract

nonisolated extension HttpSyncSentencesBlob {
    /// Returns a diagnostic for the first contract violation. Any invalid entry rejects the whole
    /// blob: selectively accepting it would make a partially rebuilt EPUB appear trustworthy.
    func validationError(expectedSyncId: String, spineCount expectedSpineCount: Int) -> String? {
        guard version >= 1, version <= Self.supportedVersion else {
            return "unsupported version \(version)"
        }
        guard kind == Self.expectedKind else { return "wrong kind \(kind.isEmpty ? "(none)" : kind)" }
        guard !expectedSyncId.isEmpty, syncId == expectedSyncId else {
            return "syncId \(syncId.isEmpty ? "(none)" : syncId) does not match \(expectedSyncId)"
        }
        guard expectedSpineCount > 0, spineCount == expectedSpineCount else {
            return "spineCount \(spineCount) does not match EPUB spine count \(expectedSpineCount)"
        }
        guard !entries.isEmpty else { return "no entries" }

        for (id, entry) in entries {
            guard entry.spine >= 0, entry.spine < expectedSpineCount else {
                return "entry \(id) has out-of-bounds spine \(entry.spine)"
            }
            guard entry.start >= 0, entry.len > 0, entry.start <= Int.max - entry.len else {
                return "entry \(id) has invalid start/len"
            }
            guard id == "c\(entry.spine)s\(entry.start)" else {
                return "entry \(id) does not match its address"
            }
            let normalized = EpubTranslationStore.normalize(entry.text)
            guard normalized.unicodeScalars.count == entry.len else {
                return "entry \(id) length does not match normalized text"
            }
            guard entry.hash == EpubTranslationStore.textHash(normalized) else {
                return "entry \(id) hash does not match normalized text"
            }
            guard !entry.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "entry \(id) has an empty translation"
            }
        }
        return nil
    }
}
