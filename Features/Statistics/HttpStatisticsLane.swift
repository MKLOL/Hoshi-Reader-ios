import Foundation
import CryptoKit
import UIKit

nonisolated struct HttpStatisticsShard: Codable {
    var version = 1
    var deviceId: String
    var month: String
    var books: [String: HttpStatisticsShardBook]
}
nonisolated struct HttpStatisticsShardBook: Codable {
    var title: String?
    var contentType: String?
    var reading: [Statistics] = []
    var mangaText: [MangaTextStatistic] = []
}
nonisolated struct HttpStatisticsPreferences: Codable, Equatable {
    var version = 1
    var streakMinimumMinutes: Int
    var dayResetHour: Int
    var updatedAt: Int64
    var timeZone: String? = nil
}

@MainActor enum StatisticsPreferencesStore {
    static let stampKey = "statistics.preferencesUpdatedAt"
    static let zoneKey = "statistics.timeZone"
    static func load(defaults: UserDefaults = .standard) -> HttpStatisticsPreferences {
        let goal = defaults.object(forKey: ReadingDay.goalKey) == nil ? 10 : min(120, max(1, defaults.integer(forKey: ReadingDay.goalKey)))
        let reset = ReadingDay.resetHour(defaults: defaults)
        let zone = defaults.string(forKey: zoneKey)
        var stamp = (defaults.object(forKey: stampKey) as? NSNumber)?.int64Value ?? 0
        if stamp == 0 && (goal != 10 || reset != 3 || zone != nil) { stamp = 1 }
        return HttpStatisticsPreferences(streakMinimumMinutes: goal, dayResetHour: reset, updatedAt: stamp, timeZone: zone)
    }
    static func save(_ value: HttpStatisticsPreferences, defaults: UserDefaults = .standard) {
        defaults.set(min(120, max(1, value.streakMinimumMinutes)), forKey: ReadingDay.goalKey)
        defaults.set(min(23, max(0, value.dayResetHour)), forKey: ReadingDay.resetKey)
        defaults.set(value.updatedAt, forKey: stampKey)
        if let zone = value.timeZone, StatisticsZone.zone(zone) != nil { defaults.set(zone, forKey: zoneKey) }
        NotificationCenter.default.post(name: .readingStatisticsChanged, object: nil)
    }
    static func choose(goal: Int? = nil, reset: Int? = nil, zone: String? = nil) {
        var value = load()
        let old = value
        if let goal { value.streakMinimumMinutes = goal }
        if let reset { value.dayResetHour = reset }
        if let zone { value.timeZone = zone }
        value.streakMinimumMinutes = min(120, max(1, value.streakMinimumMinutes))
        value.dayResetHour = min(23, max(0, value.dayResetHour))
        guard value != old else { return }
        value.updatedAt = max(Int64(Date().timeIntervalSince1970 * 1000), value.updatedAt == .max ? .max : value.updatedAt + 1)
        save(value)
        HttpStatisticsLane.shared.schedule(flush: true)
    }
}

/// Own-device monthly keys prevent concurrent peers from overwriting each other's history.
/// Legacy per-book keys remain bidirectional so devices can upgrade independently.
@Observable @MainActor final class HttpStatisticsLane {
    static let shared = HttpStatisticsLane()
    static let prefix = "sync/maps/stats/"
    var lastChecked: Date?
    var problem: String?
    private struct Index: Codable {
        var scope = ""
        var applied: [String: String] = [:]
        var hashes: [String: String] = [:]
        var preferences: [String: HttpStatisticsPreferences] = [:]
    }
    private struct Failure { var etag: String?; var retry: Date; var attempts: Int; var message: String? }
    private var failures: [String: Failure] = [:]
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var scheduled: Task<Void, Never>?
    private var polling: Task<Void, Never>?
    private var lastPush = Date.distantPast
    private var lastLegacyPush = Date.distantPast
    private let directory: URL?
    private let device: ReadingDevice?
    private let defaults: UserDefaults
    private let clock: () -> Date
    init(directory: URL? = nil, device: ReadingDevice? = nil, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.clock = now
        self.directory = directory; self.device = device; self.defaults = defaults
    }
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func parse(_ key: String) -> (device: String, month: String)? {
        guard key.hasPrefix(prefix) else { return nil }
        let parts = key.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, StatisticsHistory.validID(parts[0]) else { return nil }
        if parts[1] == "settings.json" { return (parts[0], "settings") }
        guard parts[1].hasSuffix(".json") else { return nil }
        let month = String(parts[1].dropLast(5))
        guard month.count == 7, ReadingDay.parse(month + "-01") != nil else { return nil }
        return (parts[0], month)
    }
    func schedule(flush: Bool = false) {
        if flush { scheduled?.cancel(); scheduled = nil }
        guard scheduled == nil else { return } // First dirty save sets a deadline; subsequent saves cannot postpone it.
        scheduled = Task { @MainActor [weak self] in
            guard let self else { return }
            if !flush { do { try await Task.sleep(for: .seconds(30)) } catch { return } }
            self.scheduled = nil
            await self.refresh(flush: flush)
        }
    }
    func refresh(flush: Bool = true) async {
        let config = HttpSyncSettingsStore.shared.currentConfig()
        guard config.isConfigured else { return }
        let work = Task { @MainActor in
            let transport = HttpSyncKvClient(baseURL: config.baseURL, bearerToken: config.token)
            do {
                var listing: [String: HttpSyncKvKeyMeta] = [:]
                try await transport.listAll(prefix: nil, since: nil) { listing[$0.key] = $0 }
                try Task.checkCancellation()
                _ = await self.run(transport: transport, listing: listing, scope: config.baseURL + ":" + self.sha(Data(config.token.utf8)), flush: flush)
            } catch { if !Task.isCancelled { self.markFailed(error) } }
        }
        var lease = UIBackgroundTaskIdentifier.invalid
        lease = UIApplication.shared.beginBackgroundTask(withName: "Reading history sync") {
            work.cancel()
            if lease != .invalid { UIApplication.shared.endBackgroundTask(lease); lease = .invalid }
        }
        defer { if lease != .invalid { UIApplication.shared.endBackgroundTask(lease) } }
        await work.value
    }
    func poll(transport: any HttpSyncKvTransport, listing: [String: HttpSyncKvKeyMeta], scope: String) {
        guard polling == nil else { return }
        polling = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.run(transport: transport, listing: listing, scope: scope)
            self.polling = nil
        }
    }
    func markFailed(_ error: Error) {
        problem = error is URLError ? "No connection. Other devices’ reading may be out of date." : "Could not check other devices’ reading: \(error.localizedDescription)"
    }
    func run(transport: any HttpSyncKvTransport, listing: [String: HttpSyncKvKeyMeta], scope: String = "", flush: Bool = false, retryFailed: Bool = false) async -> [String] {
        if busy { await withCheckedContinuation { waiters.append($0) } }
        busy = true
        defer { if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() } }
        let now = clock(), own = device ?? .current
        var errors: [String] = []
        do {
            let booksDirectory = try directory ?? BookStorage.getBooksDirectory()
            try FileManager.default.createDirectory(at: booksDirectory, withIntermediateDirectories: true)
            let file = booksDirectory.appendingPathComponent(".http_sync_statistics_lane.json")
            var index = BookStorage.load(Index.self, from: file) ?? Index()
            if index.scope != scope { index = Index(scope: scope); failures = [:]; lastPush = .distantPast; lastLegacyPush = .distantPast }
            var rootErrors: [String] = []
            var roots = Dictionary(uniqueKeysWithValues: try StatisticsHistory.roots(directory: booksDirectory, onError: { id, error in rootErrors.append("\(id): \(error.localizedDescription)") }).map { ($0.syncId, $0) })
            func blocked(_ key: String, _ etag: String?) -> Bool {
                guard !retryFailed, let failure = failures[key] else { return false }
                return failure.etag == etag && failure.retry > now
            }
            func fail(_ key: String, _ etag: String?, _ error: Error, quiet: Bool = false) {
                let attempts = (failures[key]?.attempts ?? 0) + 1
                let message = quiet ? nil : "\(key): \(error.localizedDescription)"
                failures[key] = Failure(etag: etag, retry: now.addingTimeInterval(min(600, 30 * pow(2, Double(min(5, attempts - 1))))), attempts: attempts, message: message)
                if let message { errors.append(message) }
            }
            func rootFor(_ id: String, title: String?, type: String?) throws -> URL {
                if let existing = roots[id], existing.book != nil { return existing.root }
                let contentType = type.flatMap { ContentType(rawValue: $0.lowercased()) }
                let root = try StatisticsHistory.historyRoot(id, title: title, type: contentType, directory: booksDirectory)
                let info = StatisticsHistory.info(root)
                roots[id] = StatisticsRoot(syncId: id, root: root, title: info?.title, contentType: info?.contentType, book: nil)
                return root
            }
            var readThisPass = Set<String>()
            // Apply each key only after all its rows are safely saved, including own keys after restore.
            try Task.checkCancellation()
            for meta in listing.values.sorted(by: { $0.key < $1.key }) {
                guard let parsed = Self.parse(meta.key), index.applied[meta.key] != meta.etag || meta.etag == nil, !blocked(meta.key, meta.etag) else { continue }
                do {
                    try Task.checkCancellation()
                    guard let fetched = try await transport.getBounded(key: meta.key, maxBytes: parsed.month == "settings" ? 65_536 : 4 * 1024 * 1024) else {
                        throw HttpSyncError("Statistics disappeared", skip: true)
                    }
                    let version = try JSONDecoder().decode(Version.self, from: fetched.body).version
                    guard version <= 1 else { throw HttpSyncError("Statistics need a newer app", skip: true) }
                    guard version == 1 else { throw HttpSyncError("Unsupported statistics version") }
                    if parsed.month == "settings" {
                        let value = try JSONDecoder().decode(HttpStatisticsPreferences.self, from: fetched.body)
                        index.preferences[meta.key] = value
                    } else {
                        let shard = try JSONDecoder().decode(HttpStatisticsShard.self, from: fetched.body)
                        guard shard.deviceId == parsed.device, shard.month == parsed.month else { throw HttpSyncError("Statistics belong to another device or month") }
                        for (id, value) in shard.books.sorted(by: { $0.key < $1.key }) where StatisticsHistory.validID(id) {
                            let reading = value.reading.filter { $0.deviceId == parsed.device && $0.dateKey.hasPrefix(parsed.month + "-") && ReadingDay.parse($0.dateKey) != nil }
                            let text = value.mangaText.filter { $0.deviceId == parsed.device && $0.dateKey.hasPrefix(parsed.month + "-") && ReadingDay.parse($0.dateKey) != nil }
                            guard !reading.isEmpty || !text.isEmpty else { continue }
                            let root = try rootFor(id, title: value.title ?? reading.first?.title, type: value.contentType ?? (text.isEmpty ? nil : "mokuro"))
                            try ReadingStatisticsStore.migrate(root: root)
                            let existing = try ReadingStatisticsStore.strictReading(root: root)
                            let merged = Statistics.merged(existing + reading)
                            if merged != existing { try ReadingStatisticsStore.save(merged, root: root, scheduleSync: false) }
                            let oldText = try ReadingStatisticsStore.strictText(root: root), newText = MangaTextStatistic.merged(oldText + text)
                            if newText != oldText { try ReadingStatisticsStore.saveText(newText, root: root, scheduleSync: false) }
                        }
                    }
                    readThisPass.insert(meta.key)
                    index.applied[meta.key] = fetched.etag
                    index.hashes[meta.key] = sha(fetched.body)
                    failures.removeValue(forKey: meta.key)
                } catch { if Task.isCancelled { throw CancellationError() }; fail(meta.key, meta.etag, error, quiet: (error as? HttpSyncError)?.skip == true) }
            }
            // Legacy keys for every book on the server, regardless of payload availability or tombstones.
            for key in listing.keys.sorted() {
                let parts = key.split(separator: "/").map(String.init)
                guard parts.count == 3, parts[0] == "books", StatisticsHistory.validID(parts[1]), ["statistics", "manga_statistics"].contains(parts[2]), roots[parts[1]] == nil else { continue }
                _ = try rootFor(parts[1], title: nil, type: listing["books/\(parts[1])/manga_statistics"] == nil ? nil : "mokuro")
            }
            let legacyDue = flush || now.timeIntervalSince(lastLegacyPush) >= 180
            for item in roots.values.sorted(by: { $0.syncId < $1.syncId }) {
                let key = "books/\(item.syncId)/statistics"
                guard !blocked(key, listing[key]?.etag) else { continue }
                do {
                    try await HttpReadingStatisticsSync.shared.exchange(root: item.root, syncId: item.syncId, transport: transport, listing: listing, uploadLocal: legacyDue)
                    if item.book == nil, item.title == nil, let title = try ReadingStatisticsStore.strictReading(root: item.root).first?.title {
                        _ = try rootFor(item.syncId, title: title, type: item.contentType?.rawValue)
                    }
                    failures.removeValue(forKey: key)
                } catch { fail(key, listing[key]?.etag, error, quiet: (error as? HttpSyncError)?.skip == true) }
            }
            if legacyDue { lastLegacyPush = now }
            try Task.checkCancellation()
            // Re-read after all network awaits: live sessions and deletes may have changed the roots.
            let currentRoots = try StatisticsHistory.roots(directory: booksDirectory, onError: { id, error in rootErrors.append("\(id): \(error.localizedDescription)") })
            errors += rootErrors
            var months: [String: [String: HttpStatisticsShardBook]] = [:]
            var canPublish = rootErrors.isEmpty
            for item in currentRoots {
                do {
                    let reading = try ReadingStatisticsStore.strictReading(root: item.root).filter { $0.deviceId == own.id && ReadingDay.parse($0.dateKey) != nil }
                    let text = try ReadingStatisticsStore.strictText(root: item.root).filter { $0.deviceId == own.id && ReadingDay.parse($0.dateKey) != nil }
                    let grouped = Dictionary(grouping: reading, by: { String($0.dateKey.prefix(7)) })
                    let groupedText = Dictionary(grouping: text, by: { String($0.dateKey.prefix(7)) })
                    failures.removeValue(forKey: "local:\(item.syncId)")
                    for month in Set(grouped.keys).union(groupedText.keys) {
                        months[month, default: [:]][item.syncId] = HttpStatisticsShardBook(title: item.title, contentType: item.contentType.map { $0 == .epub ? "Epub" : "Mokuro" }, reading: grouped[month] ?? [], mangaText: groupedText[month] ?? [])
                    }
                } catch { canPublish = false; fail("local:\(item.syncId)", nil, error) }
            }
            if canPublish, flush || now.timeIntervalSince(lastPush) >= 30 {
                for (month, values) in months.sorted(by: { $0.key < $1.key }) {
                    let key = Self.prefix + own.id + "/" + month + ".json"
                    let body = try encode(HttpStatisticsShard(deviceId: own.id, month: month, books: values))
                    guard index.hashes[key] != sha(body) || listing[key] == nil else { continue }
                    // Never overwrite a server month this install has not successfully read.
                    guard listing[key] == nil || readThisPass.contains(key) || (index.applied[key] != nil && index.applied[key] == listing[key]?.etag), !blocked(key, listing[key]?.etag) else { continue }
                    do {
                        let response = try await transport.put(key: key, contentType: "application/json; charset=utf-8", body: body)
                        index.applied[key] = response.etag; index.hashes[key] = sha(body); failures.removeValue(forKey: key)
                    } catch { fail(key, listing[key]?.etag, error) }
                }
                lastPush = now
            }
            var local = StatisticsPreferencesStore.load(defaults: defaults)
            let choices = index.preferences.compactMap { key, value -> (String, HttpStatisticsPreferences)? in
                Self.parse(key).map { ($0.device, value) }
            }.sorted { $0.1.updatedAt == $1.1.updatedAt ? $0.0 < $1.0 : $0.1.updatedAt < $1.1.updatedAt }
            if let winner = choices.last, winner.1.updatedAt > local.updatedAt || (winner.1.updatedAt == local.updatedAt && winner.0 > own.id) {
                var chosen = winner.1; chosen.timeZone = chosen.timeZone ?? local.timeZone
                if chosen != local { StatisticsPreferencesStore.save(chosen, defaults: defaults); local = StatisticsPreferencesStore.load(defaults: defaults) }
            }
            // Old peers omit the zone; retain the newest explicit zone independently.
            let zones = choices.filter { StatisticsZone.zone($0.1.timeZone) != nil } + (local.timeZone == nil ? [] : [(own.id, local)])
            if let zone = zones.max(by: { $0.1.updatedAt == $1.1.updatedAt ? $0.0 < $1.0 : $0.1.updatedAt < $1.1.updatedAt })?.1.timeZone, zone != local.timeZone {
                local.timeZone = zone; StatisticsPreferencesStore.save(local, defaults: defaults)
            }
            let settingsKey = Self.prefix + own.id + "/settings.json", settingsBody = try encode(local)
            if local.updatedAt > 0, index.hashes[settingsKey] != sha(settingsBody) || listing[settingsKey] == nil,
               listing[settingsKey] == nil || readThisPass.contains(settingsKey) || (index.applied[settingsKey] != nil && index.applied[settingsKey] == listing[settingsKey]?.etag), !blocked(settingsKey, listing[settingsKey]?.etag) {
                do {
                    let response = try await transport.put(key: settingsKey, contentType: "application/json; charset=utf-8", body: settingsBody)
                    index.applied[settingsKey] = response.etag; index.hashes[settingsKey] = sha(settingsBody); index.preferences[settingsKey] = local
                    failures.removeValue(forKey: settingsKey)
                } catch { fail(settingsKey, listing[settingsKey]?.etag, error) }
            }
            try FileManager.default.createDirectory(at: booksDirectory, withIntermediateDirectories: true)
            try BookStorage.save(index, inside: booksDirectory, as: file.lastPathComponent)
            problem = failures.values.compactMap(\.message).first.map { "Some reading history could not be synced: " + $0 }
            if !rootErrors.isEmpty { problem = "Some retained reading history could not be read." }
            if problem == nil { lastChecked = now }
        } catch { errors.append(error.localizedDescription); markFailed(error) }
        return errors
    }
    private struct Version: Decodable { let version: Int }
}
