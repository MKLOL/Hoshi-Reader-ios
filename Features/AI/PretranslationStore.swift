//
//  PretranslationStore.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Reads the per-volume offline translation cache (`pretranslations.json`, synced from
//  `books/{syncId}/pretranslations`) and resolves a tapped speech bubble to its pre-computed
//  translation + explanation.
//
//  These are produced ahead of time by the desktop tool in tools/pretranslate and are strictly a
//  read-only cache: nothing here writes to `ai_chat_log.json`, because a cache hit is not a
//  conversation the user had. See MangaAiController.ask.
//
//  Bubble addressing: the primary key is the bubble's mokuro address, `p{page}b{block}`, which the
//  reader carries through the page HTML as `data-hoshi-block`. Because that address is derived from
//  the OCR file, it is identical on every device and survives re-imports. The stored text hash
//  guards against a re-OCR having changed what that address points at; when it has, a whole-text
//  match is tried before giving up.
//

import Foundation
import CryptoKit

/// One resolved offline translation for a bubble.
nonisolated struct Pretranslation: Equatable {
    let bubbleText: String
    let translation: String
    let explanation: String
    /// The model that produced it, surfaced in the popup so a cached reply is never mistaken for a
    /// live one.
    let model: String

    /// The popup renders Markdown, so present the translation and the explanation the same way the
    /// online tutor prompt does.
    var markdownResponse: String {
        explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? translation
            : "\(translation)\n\n\(explanation)"
    }
}

/// Loads and caches `pretranslations.json` per book directory.
///
/// `nonisolated` + an explicit lock rather than `@MainActor`: the sync reconciler calls
/// `invalidate` after writing a fresh blob, and that code resumes OFF the main actor after its
/// `await`s. A `@MainActor` annotation here would compile to a direct, unchecked call from that
/// context and let the cache dictionary be mutated while the reader is reading it.
nonisolated final class PretranslationStore: @unchecked Sendable {
    static let shared = PretranslationStore()

    private let lock = NSLock()

    private struct Loaded {
        let blob: HttpSyncPretranslationsBlob
        /// Secondary index: source-text hash -> entry, for when block indices have shifted.
        let byHash: [String: HttpSyncPretranslationEntry]
    }

    /// Keyed by book folder name. A volume's blob is a few hundred KB, and the reader only ever has
    /// one book open, so caching the parsed form avoids re-reading on every bubble tap.
    private var cache: [String: Loaded?] = [:]

    private init() {}

    /// Drops the cached parse for a book (called after sync writes a fresh blob).
    static func invalidate(root: URL) {
        shared.invalidate(root: root)
    }

    func invalidate(root: URL) {
        lock.lock()
        defer { lock.unlock() }
        cache.removeValue(forKey: root.lastPathComponent)
    }

    func invalidateAll() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
    }

    /// True when this book has any offline translations available.
    func hasPretranslations(folder: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return load(folder: folder) != nil
    }

    /// Number of cached bubbles for the book, for settings/diagnostics display.
    func count(folder: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return load(folder: folder)?.blob.entries.count ?? 0
    }

    /// Resolves a tapped bubble.
    ///
    /// - Parameters:
    ///   - blockId: the bubble's `p{page}b{block}` address, when the reader knew it.
    ///   - bubbleText: the OCR text actually tapped; used to validate the hit and as a fallback key.
    func lookup(blockId: String?, bubbleText: String, folder: String) -> Pretranslation? {
        lock.lock()
        defer { lock.unlock() }
        guard let loaded = load(folder: folder) else { return nil }
        let trimmed = bubbleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let wantedHash = Self.textHash(trimmed)

        if let blockId, let entry = loaded.blob.entries[blockId] {
            // Trust the address only when the text still matches. A blob generated before a re-OCR
            // would otherwise hand back a neighbouring line with total confidence.
            if entry.hash == wantedHash || entry.text == trimmed {
                return make(entry, model: loaded.blob.model)
            }
        }
        // Either no address (an older page render) or the address went stale — fall back to the
        // text itself. Identical lines elsewhere in the volume share a translation, which is the
        // right answer for a bubble whose entire content is "うん".
        if let entry = loaded.byHash[wantedHash] {
            return make(entry, model: loaded.blob.model)
        }
        return nil
    }

    private func make(_ entry: HttpSyncPretranslationEntry, model: String) -> Pretranslation {
        Pretranslation(
            bubbleText: entry.text,
            translation: entry.translation,
            explanation: entry.explanation,
            model: model
        )
    }

    // MARK: - Loading

    private func load(folder: String) -> Loaded? {
        if let cached = cache[folder] { return cached }
        let loaded = readFromDisk(folder: folder)
        cache[folder] = loaded
        return loaded
    }

    /// The Books directory, resolved without `BookStorage` (which is main-actor isolated and so
    /// unreachable from this deliberately `nonisolated` type). Mirrors
    /// `BookStorage.getBooksDirectory()` — Application Support + "Books".
    private static func booksDirectory() -> URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Books")
    }

    private func readFromDisk(folder: String) -> Loaded? {
        guard let booksDir = Self.booksDirectory() else { return nil }
        let url = booksDir
            .appendingPathComponent(folder)
            .appendingPathComponent(FileNames.pretranslations)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let blob = try? JSONDecoder().decode(HttpSyncPretranslationsBlob.self, from: data) else {
            return nil
        }
        // Sorted, not `blob.entries.values`: dictionary iteration order varies per launch, so an
        // unsorted build would pick an arbitrary winner among duplicate source lines (a volume has
        // many bubbles reading just "うん") and answer the same tap differently on each run.
        var byHash: [String: HttpSyncPretranslationEntry] = [:]
        byHash.reserveCapacity(blob.entries.count)
        for key in blob.entries.keys.sorted() {
            guard let entry = blob.entries[key], byHash[entry.hash] == nil else { continue }
            byHash[entry.hash] = entry
        }
        return Loaded(blob: blob, byHash: byHash)
    }

    /// Short sha256 of the source Japanese. Must match the writer in
    /// tools/pretranslate/hoshi_pretranslate/blob.py (`sha256(...).hexdigest()[:16]`) and the
    /// Android reader.
    static func textHash(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).lowercased()
    }
}
