//
//  SentenceReaderPositionStore.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Remembers where sentence mode left off in each book.
//
//  Deliberately a single file in Application Support rather than a sidecar in the book directory.
//  Everything inside a book directory is part of that book's HTTP-sync payload and of the content
//  hash derived from it, so a new sidecar there would have to be added to
//  `httpSyncPayloadExcludedFiles` on BOTH platforms — and until it was, every device would compute
//  a different hash for the same book and re-upload it forever. A per-device cursor into an
//  experimental reading mode is not worth that coupling. Android stores the same map in its app
//  files directory (`sentence_mode_positions.json`), outside the book folder, for the same reason.
//
//  Keyed by book folder name, which is the on-disk identity the rest of the app uses.
//

import Foundation

nonisolated enum SentenceReaderPositionStore {
    private static let fileName = "sentence_mode_positions.json"

    private static var fileURL: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(fileName)
    }

    static func load(bookKey: String) -> SentencePosition? {
        readAll()[bookKey]
    }

    /// Every save runs on one serial queue, off the caller's actor: a swipe never waits on the
    /// file, and two quick swipes cannot interleave their read-modify-write and keep the older one.
    private static let queue = DispatchQueue(label: "moe.antimony.hoshi.sentence-positions", qos: .utility)

    static func save(_ position: SentencePosition, bookKey: String) {
        guard let fileURL else { return }
        queue.async {
            var all = readAll()
            guard all[bookKey] != position else { return }
            all[bookKey] = position
            guard let data = try? JSONEncoder().encode(all) else { return }
            // Atomic: a half-written map would lose every book's cursor, not just this one's.
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private static func readAll() -> [String: SentencePosition] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: SentencePosition].self, from: data)) ?? [:]
    }
}
