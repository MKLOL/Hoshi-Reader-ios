//
//  SentenceTranslationsWriter.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Builds the `sentence_translations.json` blob the reader and sync already understand and writes
//  it into the book directory. The blob is validated with the same rules the sync importer applies
//  to a server copy, so a device that downloads it later cannot reject what this device wrote.
//

import Foundation

nonisolated extension HttpSyncSentencesBlob {
    /// Memberwise construction for the in-app writer; the struct otherwise only decodes.
    init(version: Int, kind: String, syncId: String, title: String, model: String, promptId: String,
         generatedAt: String, spineCount: Int, entries: [String: HttpSyncSentenceEntry]) {
        self.version = version
        self.kind = kind
        self.syncId = syncId
        self.title = title
        self.model = model
        self.promptId = promptId
        self.generatedAt = generatedAt
        self.spineCount = spineCount
        self.entries = entries
    }
}

nonisolated enum SentenceTranslationsWriter {
    static let contentType = "application/json; charset=utf-8"

    static func buildBlob(plan: PretranslationPlan, translations: [String: SentenceTranslationResult], model: String, promptId: String, generatedAt: Date = Date()) -> HttpSyncSentencesBlob {
        var entries: [String: HttpSyncSentenceEntry] = [:]
        for sentence in plan.sentences {
            guard let translation = translations[sentence.id] else { continue }
            let normalized = EpubTranslationStore.normalize(sentence.text)
            if normalized.isEmpty { continue }
            entries[sentence.id] = HttpSyncSentenceEntry(
                spine: sentence.spine,
                start: sentence.start,
                len: normalized.unicodeScalars.count,
                text: sentence.text,
                hash: EpubTranslationStore.textHash(normalized),
                translation: translation.translation,
                explanation: translation.explanation
            )
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return HttpSyncSentencesBlob(
            version: 1, kind: HttpSyncSentencesBlob.expectedKind, syncId: plan.syncId, title: plan.title, model: model,
            promptId: promptId, generatedAt: iso.string(from: generatedAt), spineCount: plan.spineCount, entries: entries
        )
    }

    /// Returns the validation error for `blob`, or nil when the sync importer would accept it.
    static func validationError(_ blob: HttpSyncSentencesBlob) -> String? {
        blob.validationError(expectedSyncId: blob.syncId, spineCount: blob.spineCount)
    }

    static func encode(_ blob: HttpSyncSentencesBlob) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(blob)
    }

    /// A failed or incomplete rerun cannot erase translations from another configuration.
    static func writeResult(_ blob: HttpSyncSentencesBlob, sentenceCount: Int, bookRoot: URL) throws -> Bool {
        if blob.entries.count < sentenceCount && hasSidecarForOtherConfiguration(
            bookRoot: bookRoot, syncId: blob.syncId, model: blob.model, promptId: blob.promptId) { return false }
        try write(encode(blob), bookRoot: bookRoot)
        return true
    }

    /// Writes `data` atomically as the book's sidecar and drops the reader's cached copy.
    static func write(_ data: Data, bookRoot: URL) throws {
        try data.write(to: bookRoot.appendingPathComponent(FileNames.sentenceTranslations), options: .atomic)
        EpubTranslationStore.invalidate(root: bookRoot)
    }

    private static func existingBlob(bookRoot: URL) -> HttpSyncSentencesBlob? {
        let url = bookRoot.appendingPathComponent(FileNames.sentenceTranslations)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(HttpSyncSentencesBlob.self, from: data)
    }

    /// Whether the book already has a sidecar for another model/prompt combination. A partial result
    /// must never replace such a complete blob; a same-configuration or missing sidecar may.
    static func hasSidecarForOtherConfiguration(bookRoot: URL, syncId: String, model: String, promptId: String) -> Bool {
        guard let blob = existingBlob(bookRoot: bookRoot) else { return false }
        return blob.syncId == syncId && (blob.model != model || blob.promptId != promptId)
    }

    /// Sentences the existing sidecar already covers with the same model and prompt, so a re-run only
    /// pays for what is missing while a run with a different model or note setting starts over.
    static func existingTranslations(bookRoot: URL, plan: PretranslationPlan, model: String, promptId: String) -> [String: SentenceTranslationResult] {
        guard let blob = existingBlob(bookRoot: bookRoot), blob.syncId == plan.syncId, blob.model == model, blob.promptId == promptId else { return [:] }
        let byId = Dictionary(uniqueKeysWithValues: plan.sentences.map { ($0.id, $0) })
        var result: [String: SentenceTranslationResult] = [:]
        for (id, entry) in blob.entries {
            guard let sentence = byId[id], entry.hash == EpubTranslationStore.textHash(EpubTranslationStore.normalize(sentence.text)) else { continue }
            result[id] = SentenceTranslationResult(sentenceId: id, translation: entry.translation, explanation: entry.explanation)
        }
        return result
    }
}

/// Publishes a book's sentence translations to `books/{syncId}/sentences`, the key the sync engines
/// on every platform already download from. Sync itself stays download-only for this key; this is
/// the one deliberate writer, and the bytes match the local sidecar.
nonisolated struct SentenceTranslationsUploader: Sendable {
    let transport: any HttpSyncKvTransport

    func upload(syncId: String, blob: Data) async throws {
        _ = try await transport.put(key: SyncKeys.sentences(syncId), contentType: SentenceTranslationsWriter.contentType, body: blob)
    }
}
