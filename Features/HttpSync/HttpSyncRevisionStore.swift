//
//  HttpSyncRevisionStore.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Per-KV-key edit-depth (Lamport) revision sidecar, persisted as
//  `.http_sync_revisions.json` in the Books directory. Mirrors Android's
//  HttpSyncRevisionStore — the wire `rev` field on bookmark/metadata/AI-settings blobs is
//  produced and consumed through this store.
//
//  Model per key:
//   - `localRev`: the edit depth of the local copy. Bumped to max(localRev, baseRev) + 1 by
//     every deliberate local edit (page turn persisted, shelf move, delete, import, settings).
//   - `baseRev`: the highest remote rev this device has observed (pushed or pulled). A push is
//     allowed only when localRev > remote rev; otherwise remote wins and is applied locally.
//
//  Like the shelf-state sidecar, reads/writes re-read the file each time: calls are rare
//  (one per user-visible edit), so simplicity beats caching.
//

import Foundation

nonisolated struct HttpSyncRevisionRecord: Codable, Equatable {
    var localRev: Int
    var baseRev: Int
}

@MainActor
enum HttpSyncRevisionStore {
    private static let filename = ".http_sync_revisions.json"

    private static func fileURL() -> URL? {
        (try? BookStorage.getBooksDirectory())?.appendingPathComponent(filename)
    }

    /// Sync reads one record per book on every foreground poll; decoding the whole file for each
    /// made a large library stall scrolling. The decoded file is kept until it changes on disk.
    private static var cached: (url: URL, stamp: Date, size: Int, records: [String: HttpSyncRevisionRecord])?

    private static func fileStamp(_ url: URL) -> (Date, Int)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)),
              let date = attributes[.modificationDate] as? Date, let size = (attributes[.size] as? NSNumber)?.intValue else { return nil }
        return (date, size)
    }

    static func load() -> [String: HttpSyncRevisionRecord] {
        guard let url = fileURL(), let (stamp, size) = fileStamp(url) else { return [:] }
        if let cached, cached.url == url, cached.stamp == stamp, cached.size == size { return cached.records }
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let records = (try? JSONDecoder().decode([String: HttpSyncRevisionRecord].self, from: data)) ?? [:]
        cached = (url, stamp, size, records)
        return records
    }

    private static func save(_ state: [String: HttpSyncRevisionRecord]) {
        guard let url = fileURL(), let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
        if let (stamp, size) = fileStamp(url) { cached = (url, stamp, size, state) } else { cached = nil }
    }

    /// The record for `key` (zeros when never seen).
    static func current(_ key: String) -> HttpSyncRevisionRecord {
        load()[key] ?? HttpSyncRevisionRecord(localRev: 0, baseRev: 0)
    }

    /// Registers a deliberate local edit of `key` and returns the new local rev:
    /// `max(localRev, baseRev) + 1`. Monotonic even if the subsequent push fails.
    @discardableResult
    static func bumpForLocalEdit(_ key: String) -> Int {
        var state = load()
        var record = state[key] ?? HttpSyncRevisionRecord(localRev: 0, baseRev: 0)
        record.localRev = max(record.localRev, record.baseRev) + 1
        state[key] = record
        save(state)
        return record.localRev
    }

    /// Records that the remote copy of `key` is at `rev`. When `appliedLocally` (we pulled the
    /// remote state into local files), the local rev is fast-forwarded too, so a later local
    /// edit builds on top of it.
    static func noteRemote(_ key: String, rev: Int?, appliedLocally: Bool) {
        let rr = rev ?? 0
        var state = load()
        var record = state[key] ?? HttpSyncRevisionRecord(localRev: 0, baseRev: 0)
        record.baseRev = max(record.baseRev, rr)
        if appliedLocally {
            record.localRev = max(record.localRev, rr)
        }
        guard state[key] != record else { return }
        state[key] = record
        save(state)
    }
}
