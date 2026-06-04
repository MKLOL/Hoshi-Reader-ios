//
//  AiChatHistoryStore.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Reads and writes the per-manga ChatGPT history (`ai_chat_log.json`, stored in the book's
//  directory alongside `bookmark.json` etc.). Ported from Android
//  features/ai/AiChatHistoryStore.kt. Standalone (not on the shared `BookStorage`) so the ChatGPT
//  fork addition never touches upstream files.
//
//  The chat graph types (`AiChatLog` etc.) are MainActor-isolated, and the whole app persists its
//  sidecar JSON on the main actor (see `BookStorage`), so this store is `@MainActor` too. That also
//  makes the load-modify-write append naturally serial — the main actor is a serial executor, so
//  two appends finishing close together can't interleave and clobber an entry. Writes are atomic
//  (temp file + rename), and entries are deduped by content (bubbleText + timestampSeconds +
//  response) mirroring the Android sync content key, so re-pulling a synced entry or retrying never
//  produces a duplicate.
//

import Foundation

@MainActor
final class AiChatHistoryStore {
    static let shared = AiChatHistoryStore()

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted]
        return e
    }()

    init() {}

    /// The book's chat history, or an empty log if there is none yet / it cannot be read.
    func load(folder: String) -> AiChatLog {
        guard let url = logURL(folder: folder),
              FileManager.default.fileExists(atPath: url.path(percentEncoded: false)),
              let data = try? Data(contentsOf: url),
              let log = try? JSONDecoder().decode(AiChatLog.self, from: data) else {
            return AiChatLog()
        }
        return log
    }

    /// Appends `entry` to the book's history (newest last) and returns the updated log plus whether
    /// the entry was actually added. A content duplicate (same bubbleText + timestampSeconds +
    /// response) is a no-op (`added == false`) that returns the existing log unchanged.
    @discardableResult
    func append(_ entry: AiChatEntry, folder: String) -> (log: AiChatLog, added: Bool) {
        let existing = load(folder: folder)
        if existing.entries.contains(where: { Self.matchesEntry($0, entry) }) {
            return (existing, false)
        }
        let updated = AiChatLog(entries: existing.entries + [entry])
        save(updated, folder: folder)
        return (updated, true)
    }

    /// Content equality used for dedupe — mirrors the Android sync content key (bubble text +
    /// timestamp + response). Two devices that produced the same exchange converge on one entry.
    static func matchesEntry(_ lhs: AiChatEntry, _ rhs: AiChatEntry) -> Bool {
        lhs.bubbleText == rhs.bubbleText &&
        lhs.timestampSeconds == rhs.timestampSeconds &&
        lhs.response == rhs.response
    }

    // MARK: - Persistence

    private func save(_ log: AiChatLog, folder: String) {
        guard let bookRoot = bookRootURL(folder: folder),
              let payload = try? encoder.encode(log) else { return }
        try? FileManager.default.createDirectory(at: bookRoot, withIntermediateDirectories: true)
        let target = bookRoot.appendingPathComponent(FileNames.aiChatLog)
        let temp = bookRoot.appendingPathComponent("\(FileNames.aiChatLog).tmp")
        // Write to a sibling temp file then atomically replace, so a crash mid-write cannot
        // truncate the real log and lose the whole accumulated history.
        do {
            try payload.write(to: temp, options: .atomic)
            if FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: target)
            }
        } catch {
            // Fall back to an in-place atomic write; worst case is the pre-existing truncate risk
            // for this one write.
            try? payload.write(to: target, options: .atomic)
            try? FileManager.default.removeItem(at: temp)
        }
    }

    private func bookRootURL(folder: String) -> URL? {
        guard let booksDir = try? BookStorage.getBooksDirectory() else { return nil }
        return booksDir.appendingPathComponent(folder)
    }

    private func logURL(folder: String) -> URL? {
        bookRootURL(folder: folder)?.appendingPathComponent(FileNames.aiChatLog)
    }
}
