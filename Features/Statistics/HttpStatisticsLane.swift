import Foundation
import CryptoKit
import UIKit

nonisolated struct HttpStatisticsShard: Codable, Sendable {
    var version = 1
    var deviceId: String
    var month: String
    var books: [String: HttpStatisticsShardBook]
}
nonisolated struct HttpStatisticsShardBook: Codable, Sendable {
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

/// A background merge is only committed while the exact files it read still exist. Reader
/// saves, imports and deletion all run on the main actor, alongside the final validation/write.
nonisolated struct HttpStatisticsPreparedBook: Sendable {
    nonisolated struct Stamp: Equatable, Sendable {
        let modified: Date?
        let size: UInt64?
        let number: UInt64?
        static func read(_ url: URL) -> Self? {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
            return Self(modified: attributes[.modificationDate] as? Date, size: attributes[.size] as? UInt64,
                        number: attributes[.systemFileNumber] as? UInt64)
        }
    }
    let root: URL
    let identity: Stamp?
    let stamps: [String: Stamp]
    let stable: Bool
    let reading: Data?
    let text: Data?
    private static let files = [FileNames.metadata, "history.json", FileNames.statistics,
                                FileNames.mangaStatistics, ReadingStatisticsStore.migration]
    private static func stamps(_ root: URL) -> [String: Stamp] {
        Dictionary(uniqueKeysWithValues: files.compactMap { name in
            Stamp.read(root.appendingPathComponent(name)).map { (name, $0) }
        })
    }
    @concurrent static func prepare(root: URL, reading: [Statistics], text: [MangaTextStatistic]) async throws -> Self {
        try Task.checkCancellation()
        let identity = Stamp.read(root), before = stamps(root), decoder = JSONDecoder()
        func rows<T: Decodable>(_ name: String) throws -> [T] {
            guard before[name] != nil else { return [] }
            return try decoder.decode([T].self, from: Data(contentsOf: root.appendingPathComponent(name)))
        }
        let old = Statistics.merged(try rows(FileNames.statistics)), oldText = MangaTextStatistic.merged(try rows(FileNames.mangaStatistics))
        let merged = Statistics.merged(old + reading), mergedText = MangaTextStatistic.merged(oldText + text)
        let encoder = JSONEncoder(); encoder.outputFormatting = .prettyPrinted
        let readingBytes = merged == old ? nil : try encoder.encode(merged)
        let textBytes = mergedText == oldText ? nil : try encoder.encode(mergedText)
        try Task.checkCancellation()
        return Self(root: root, identity: identity, stamps: before,
                    stable: identity != nil && Stamp.read(root) == identity && stamps(root) == before,
                    reading: readingBytes, text: textBytes)
    }
    /// False means that preparation must be repeated, never that stale bytes were written.
    @MainActor func commit(stillCurrent: @MainActor () -> Bool = { true }) throws -> Bool {
        try Task.checkCancellation()
        guard stillCurrent() else { throw CancellationError() }
        guard stable, identity != nil, Self.Stamp.read(root) == identity, Self.stamps(root) == stamps else { return false }
        if let reading { try reading.write(to: root.appendingPathComponent(FileNames.statistics), options: .atomic) }
        if let text { try text.write(to: root.appendingPathComponent(FileNames.mangaStatistics), options: .atomic) }
        if reading != nil || text != nil { NotificationCenter.default.post(name: .readingStatisticsChanged, object: root) }
        return true
    }
    var changed: Bool { reading != nil || text != nil }
}

nonisolated enum HttpStatisticsDecode {
    private struct Version: Decodable { let version: Int }
    @concurrent static func shard(_ body: Data, device: String, month: String) async throws -> HttpStatisticsShard {
        try Task.checkCancellation()
        let decoder = JSONDecoder(), version = try decoder.decode(Version.self, from: body).version
        guard version <= 1 else { throw HttpSyncError("Statistics need a newer app", skip: true) }
        guard version == 1 else { throw HttpSyncError("Unsupported statistics version") }
        var shard = try decoder.decode(HttpStatisticsShard.self, from: body)
        guard shard.deviceId == device, shard.month == month else { throw HttpSyncError("Statistics belong to another device or month") }
        shard.books = shard.books.filter { StatisticsHistory.validID($0.key) }.mapValues { book in
            var book = book
            book.reading = Statistics.merged(book.reading.filter { $0.deviceId == device && $0.dateKey.hasPrefix(month + "-") && ReadingDay.parse($0.dateKey) != nil })
            book.mangaText = MangaTextStatistic.merged(book.mangaText.filter { $0.deviceId == device && $0.dateKey.hasPrefix(month + "-") && ReadingDay.parse($0.dateKey) != nil })
            return book
        }
        return shard
    }
}

@MainActor enum StatisticsPreferencesStore {
    static let stampKey = "statistics.preferencesUpdatedAt"
    // Retain this preference on the wire for peers that still count in a shared zone.
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
    static func choose(goal: Int? = nil, reset: Int? = nil) {
        var value = load()
        let old = value
        if let goal { value.streakMinimumMinutes = goal }
        if let reset { value.dayResetHour = reset }
        value.streakMinimumMinutes = min(120, max(1, value.streakMinimumMinutes))
        value.dayResetHour = min(23, max(0, value.dayResetHour))
        guard value != old else { return }
        value.updatedAt = max(Int64(Date().timeIntervalSince1970 * 1000), value.updatedAt == .max ? .max : value.updatedAt + 1)
        save(value)
        HttpStatisticsLane.shared.schedule(flush: true)
    }
}

/// What a statistics pass reads from every book, read off the main thread. Reading each book's
/// files on the main actor stalled scrolling for tens of milliseconds every pass in a large library.
nonisolated struct HttpStatisticsDisk: Sendable {
    var roots: [StatisticsRoot] = []
    var errors: [String] = []
    /// A retained history whose book is installed again is absorbed by `StatisticsHistory.roots`,
    /// which writes on the main actor.
    var needsAbsorb = false
    /// Each book's statistics files as modified, so a pass can tell what changed since the last.
    var stamps: [String: String] = [:]
    var digest = ""
    /// An ETag is only applied while its rows are still present locally. A backup restore may
    /// replace or remove sidecars without changing the server's ETag.
    var invalidShards: Set<String> = []

    @concurrent static func read(booksDirectory: URL, stateFile: String, applied: [String: String] = [:], hashes: [String: String] = [:], scope: String = "", validatedDisk: String? = nil) async -> HttpStatisticsDisk {
        var disk = HttpStatisticsDisk(), installed: [String: StatisticsRoot] = [:]
        let manager = FileManager.default, decoder = JSONDecoder()
        do {
            for folder in try manager.contentsOfDirectory(at: booksDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                let metadata = folder.appendingPathComponent(FileNames.metadata)
                if let book = (try? Data(contentsOf: metadata)).flatMap({ try? decoder.decode(BookMetadata.self, from: $0) }) {
                    guard let id = syncId(for: book), let name = book.folder else { continue }
                    installed[id] = StatisticsRoot(syncId: id, root: booksDirectory.appendingPathComponent(name), title: book.title, contentType: book.resolvedContentType, book: book)
                } else if manager.fileExists(atPath: metadata.path) || manager.fileExists(atPath: folder.appendingPathComponent(FileNames.statistics).path) {
                    disk.errors.append("\(folder.lastPathComponent): Unreadable book metadata at \(folder.lastPathComponent)")
                }
            }
        } catch { disk.errors.append("Books: \(error.localizedDescription)") }
        let parent = booksDirectory.appendingPathComponent(StatisticsHistory.directoryName)
        if manager.fileExists(atPath: parent.path) {
            do {
                for folder in try manager.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey]) {
                    let id = folder.lastPathComponent
                    guard StatisticsHistory.validID(id) else { continue }
                    guard let info = (try? Data(contentsOf: folder.appendingPathComponent("history.json"))).flatMap({ try? decoder.decode(StatisticsHistoryInfo.self, from: $0) }),
                          info.syncId == id else { disk.errors.append("\(id): Unreadable retained history at \(id)"); continue }
                    if installed[id] != nil { disk.needsAbsorb = true }
                    else { installed[id] = StatisticsRoot(syncId: id, root: folder, title: info.title, contentType: info.contentType, book: nil) }
                }
            } catch { disk.errors.append("\(StatisticsHistory.directoryName): \(error.localizedDescription)") }
        }
        disk.roots = installed.values.sorted { $0.syncId < $1.syncId }
        let files = [FileNames.metadata, FileNames.statistics, FileNames.mangaStatistics, stateFile, "history.json", ReadingStatisticsStore.migration]
        for root in disk.roots {
            disk.stamps[root.syncId] = root.root.path + files.map { name in
                let attributes = try? manager.attributesOfItem(atPath: root.root.appendingPathComponent(name).path)
                return (attributes?[.modificationDate] as? Date)
                    .map { String($0.timeIntervalSinceReferenceDate.bitPattern, radix: 36) + ":\(attributes?[.size] as? UInt64 ?? 0)" } ?? "-"
            }.joined(separator: ",")
        }
        disk.digest = SHA256.hash(data: Data(disk.roots.map { disk.stamps[$0.syncId] ?? "" }.joined(separator: "\n").utf8)).lowercaseHex
        guard disk.digest != validatedDisk else { return disk }
        var reading: [String: [Statistics]] = [:], text: [String: [MangaTextStatistic]] = [:]
        func rows<T: Decodable>(_ root: URL, _ name: String) throws -> [T] {
            let file = root.appendingPathComponent(name)
            guard manager.fileExists(atPath: file.path) else { return [] }
            return try decoder.decode([T].self, from: Data(contentsOf: file))
        }
        for key in applied.keys {
            guard let parsed = HttpStatisticsLane.parse(key), parsed.month != "settings" else { continue }
            do {
                let body = try Data(contentsOf: cacheURL(key: key, scope: scope, booksDirectory: booksDirectory))
                guard body.count <= 4 * 1024 * 1024, SHA256.hash(data: body).lowercaseHex == hashes[key] else { disk.invalidShards.insert(key); continue }
                let shard = try decoder.decode(HttpStatisticsShard.self, from: body)
                guard shard.deviceId == parsed.device, shard.month == parsed.month else { disk.invalidShards.insert(key); continue }
                for (id, book) in shard.books where StatisticsHistory.validID(id) {
                    let expected = book.reading.filter { $0.deviceId == parsed.device && $0.dateKey.hasPrefix(parsed.month + "-") && ReadingDay.parse($0.dateKey) != nil }
                    let expectedText = book.mangaText.filter { $0.deviceId == parsed.device && $0.dateKey.hasPrefix(parsed.month + "-") && ReadingDay.parse($0.dateKey) != nil }
                    guard !expected.isEmpty || !expectedText.isEmpty else { continue }
                    guard let root = installed[id]?.root else { disk.invalidShards.insert(key); break }
                    if reading[id] == nil { reading[id] = Statistics.merged(try rows(root, FileNames.statistics)) }
                    if text[id] == nil { text[id] = MangaTextStatistic.merged(try rows(root, FileNames.mangaStatistics)) }
                    if Statistics.merged(reading[id]! + expected) != reading[id]! || MangaTextStatistic.merged(text[id]! + expectedText) != text[id]! {
                        disk.invalidShards.insert(key); break
                    }
                }
            } catch { disk.invalidShards.insert(key) }
        }
        return disk
    }

    private static func cacheURL(key: String, scope: String, booksDirectory: URL) -> URL {
        let account = SHA256.hash(data: Data(scope.utf8)).lowercaseHex
        let name = SHA256.hash(data: Data(key.utf8)).lowercaseHex + ".json"
        return booksDirectory.appendingPathComponent(".http_sync_statistics_cache").appendingPathComponent(account).appendingPathComponent(name)
    }
    /// Keep the exact accepted evidence off the main actor. Validation can then distinguish a
    /// normal reading advance from restored older rows without fetching every unchanged shard.
    @concurrent static func cache(_ body: Data, key: String, scope: String, booksDirectory: URL) async throws {
        let file = cacheURL(key: key, scope: scope, booksDirectory: booksDirectory)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: file, options: .atomic)
        var directory = booksDirectory.appendingPathComponent(".http_sync_statistics_cache"), values = URLResourceValues()
        values.isExcludedFromBackup = true; try directory.setResourceValues(values)
    }

    /// This device's rows of every book as encoded monthly shards with their hashes.
    @concurrent static func shards(roots: [StatisticsRoot], device: String) async -> (months: [String: (body: Data, sha: String)], errors: [String: String]) {
        let decoder = JSONDecoder()
        func rows<T: Decodable>(_ root: URL, _ name: String) throws -> [T] {
            let file = root.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: file.path) else { return [] }
            return try decoder.decode([T].self, from: Data(contentsOf: file))
        }
        var months: [String: [String: HttpStatisticsShardBook]] = [:], errors: [String: String] = [:]
        for item in roots {
            do {
                let reading = Statistics.merged(try rows(item.root, FileNames.statistics)).filter { $0.deviceId == device && ReadingDay.parse($0.dateKey) != nil }
                let text = MangaTextStatistic.merged(try rows(item.root, FileNames.mangaStatistics)).filter { $0.deviceId == device && ReadingDay.parse($0.dateKey) != nil }
                let grouped = Dictionary(grouping: reading, by: { String($0.dateKey.prefix(7)) })
                let groupedText = Dictionary(grouping: text, by: { String($0.dateKey.prefix(7)) })
                for month in Set(grouped.keys).union(groupedText.keys) {
                    months[month, default: [:]][item.syncId] = HttpStatisticsShardBook(title: item.title, contentType: item.contentType.map { $0 == .epub ? "Epub" : "Mokuro" }, reading: grouped[month] ?? [], mangaText: groupedText[month] ?? [])
                }
            } catch { errors[item.syncId] = error.localizedDescription }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var encoded: [String: (body: Data, sha: String)] = [:]
        for (month, books) in months {
            guard let body = try? encoder.encode(HttpStatisticsShard(deviceId: device, month: month, books: books)) else { continue }
            encoded[month] = (body, SHA256.hash(data: body).lowercaseHex)
        }
        return (encoded, errors)
    }
}

/// Own-device monthly keys prevent concurrent peers from overwriting each other's history.
/// Legacy per-book keys remain bidirectional so devices can upgrade independently.
@Observable @MainActor final class HttpStatisticsLane {
    static let shared = HttpStatisticsLane()
    nonisolated static let prefix = "sync/maps/stats/"
    var lastChecked: Date?
    var problem: String?
    private struct Index: Codable, Equatable {
        var scope = ""
        var applied: [String: String] = [:]
        var hashes: [String: String] = [:]
        var preferences: [String: HttpStatisticsPreferences] = [:]
        /// The disk, server listing and preferences after the last pass that left everything synced;
        /// a pass finding the same has nothing to do.
        var settled: String?
        /// Per book, its files and server copies when its exchange last found nothing to do.
        var legacy: [String: String]?
        /// The local file signature last checked against the cached, accepted shard evidence.
        var validatedDisk: String?
    }
    private struct Failure { var etag: String?; var retry: Date; var attempts: Int; var message: String? }
    private var failures: [String: Failure] = [:]
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var scheduled: Task<Void, Never>?
    private var scheduledConfig: HttpSyncConfig?
    private var polling: Task<Void, Never>?
    private var lastPush = Date.distantPast
    private var lastLegacyPush = Date.distantPast
    private let directory: URL?
    private let device: ReadingDevice?
    private let defaults: UserDefaults
    private let clock: () -> Date
    private let usageLane: HttpUsageLane?
    init(directory: URL? = nil, device: ReadingDevice? = nil, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init, usageLane: HttpUsageLane? = nil) {
        self.usageLane = directory == nil ? (usageLane ?? .shared) : usageLane
        self.clock = now
        self.directory = directory; self.device = device; self.defaults = defaults
    }
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private func sha(_ data: Data) -> String { SHA256.hash(data: data).lowercaseHex }
    nonisolated static func parse(_ key: String) -> (device: String, month: String)? {
        guard key.hasPrefix(prefix) else { return nil }
        let parts = key.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, StatisticsHistory.validID(parts[0]) else { return nil }
        if parts[1] == "settings.json" { return (parts[0], "settings") }
        guard parts[1].hasSuffix(".json") else { return nil }
        let month = String(parts[1].dropLast(5))
        // This fixed wire grammar needs no calendar or ICU formatter. It is evaluated for
        // every device-month key before the five-second poll's unchanged-listing skip.
        let bytes = Array(month.utf8)
        guard bytes.count == 7, bytes[4] == 45,
              [0, 1, 2, 3, 5, 6].allSatisfy({ (48...57).contains(bytes[$0]) }),
              bytes[0...3].contains(where: { $0 != 48 }),
              (1...12).contains(Int(bytes[5] - 48) * 10 + Int(bytes[6] - 48)) else { return nil }
        return (parts[0], month)
    }
    func schedule(flush: Bool = false) {
        let config = HttpSyncSettingsStore.shared.currentConfig()
        guard config.isConfigured else { return }
        if flush || scheduledConfig != config { scheduled?.cancel(); scheduled = nil }
        guard scheduled == nil else { return } // First dirty save sets a deadline; subsequent saves cannot postpone it.
        scheduledConfig = config
        scheduled = Task { @MainActor [weak self] in
            guard let self else { return }
            if !flush { do { try await Task.sleep(for: .seconds(30)) } catch { return } }
            self.scheduled = nil
            self.scheduledConfig = nil
            guard HttpSyncSettingsStore.shared.currentConfig() == config else { return }
            await self.refresh(flush: flush)
        }
    }
    func refresh(flush: Bool = true) async {
        let config = HttpSyncSettingsStore.shared.currentConfig()
        guard config.isConfigured else { return }
        let stillCurrent = { @MainActor in HttpSyncSettingsStore.shared.currentConfig() == config }
        let work = Task { @MainActor in
            let transport = HttpSyncKvClient(baseURL: config.baseURL, bearerToken: config.token)
            do {
                var listing: [String: HttpSyncKvKeyMeta] = [:]
                try await transport.listAll(prefix: nil, since: nil) { listing[$0.key] = $0 }
                try Task.checkCancellation()
                guard stillCurrent() else { return }
                _ = await self.run(transport: transport, listing: listing, scope: config.baseURL + ":" + self.sha(Data(config.token.utf8)), flush: flush, stillCurrent: stillCurrent)
            } catch { if !Task.isCancelled, stillCurrent() { self.markFailed(error) } }
        }
        var lease = UIBackgroundTaskIdentifier.invalid
        lease = UIApplication.shared.beginBackgroundTask(withName: "Reading history sync") {
            work.cancel()
            if lease != .invalid { UIApplication.shared.endBackgroundTask(lease); lease = .invalid }
        }
        defer { if lease != .invalid { UIApplication.shared.endBackgroundTask(lease) } }
        await work.value
    }
    /// The statistics keys and scope of the last poll's pass. Other devices' statistics only
    /// change with their keys, so an unchanged listing skips the pass (which reads every book's
    /// history); a pass still runs once a minute for backed-off keys. Local reading is pushed by
    /// `schedule`, not here.
    private var polledStatistics: (scope: String, keys: [String: String], at: Date, revision: UInt64)?
    private var pollRevision: UInt64 = 0

    @discardableResult func poll(transport: any HttpSyncKvTransport, listing: [String: HttpSyncKvKeyMeta], scope: String, stillCurrent: @escaping @MainActor () -> Bool = { true }) -> Task<Void, Never>? {
        guard polling == nil, !Task.isCancelled, stillCurrent() else { return nil }
        let keys = listing.filter { Self.parse($0.key) != nil }.mapValues(Self.listed)
        if let previous = polledStatistics, previous.scope == scope, previous.keys == keys,
           clock().timeIntervalSince(previous.at) < 60 { return nil }
        pollRevision &+= 1
        let revision = pollRevision
        polledStatistics = (scope, keys, clock(), revision)
        let work = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.run(transport: transport, listing: listing, scope: scope, stillCurrent: stillCurrent)
            if !stillCurrent() || Task.isCancelled, self.polledStatistics?.revision == revision { self.polledStatistics = nil }
            self.polling = nil
        }
        polling = work
        return work
    }
    private func noteUploaded(_ response: HttpSyncKvWriteResponse, key: String, scope: String, observed: HttpSyncKvKeyMeta?) {
        guard var previous = polledStatistics, previous.scope == scope,
              previous.keys[key] == observed.map(Self.listed) else { return }
        // A pass may have waited behind a later poll. Change only a key still matching this
        // pass's observation; never replace another account or a newer server observation.
        previous.keys[key] = Self.listed(response)
        polledStatistics = previous
    }
    func markFailed(_ error: Error) {
        problem = error is URLError ? "No connection. Other devices’ reading may be out of date." : "Could not check other devices’ reading: \(error.localizedDescription)"
    }
    func run(transport: any HttpSyncKvTransport, listing: [String: HttpSyncKvKeyMeta], scope: String = "", flush: Bool = false, retryFailed: Bool = false, stillCurrent: @escaping @MainActor () -> Bool = { true }) async -> [String] {
        if busy { await withCheckedContinuation { waiters.append($0) } }
        busy = true
        defer { if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() } }
        guard !Task.isCancelled, stillCurrent() else { return [] }
        let now = clock(), own = device ?? .current
        var failures = self.failures, lastPush = self.lastPush, lastLegacyPush = self.lastLegacyPush
        var errors: [String] = []
        func checkCurrent() throws {
            try Task.checkCancellation()
            guard stillCurrent() else { throw CancellationError() }
        }
        do {
            let booksDirectory = try directory ?? BookStorage.getBooksDirectory()
            try FileManager.default.createDirectory(at: booksDirectory, withIntermediateDirectories: true)
            let file = booksDirectory.appendingPathComponent(".http_sync_statistics_lane.json")
            var index = BookStorage.load(Index.self, from: file) ?? Index()
            let stored = FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) ? index : nil
            if index.scope != scope { index = Index(scope: scope); failures = [:]; lastPush = .distantPast; lastLegacyPush = .distantPast }
            var rootErrors: [String] = []
            func finish() async throws {
                try checkCurrent()
                if let usageLane {
                    errors += await usageLane.run(transport: transport, listing: listing, deviceID: own.id, scope: scope, flush: flush, retryFailed: retryFailed, stillCurrent: stillCurrent)
                    try checkCurrent()
                }
                self.failures = failures; self.lastPush = lastPush; self.lastLegacyPush = lastLegacyPush
                if index != stored {
                    try FileManager.default.createDirectory(at: booksDirectory, withIntermediateDirectories: true)
                    try BookStorage.save(index, inside: booksDirectory, as: file.lastPathComponent)
                }
                problem = failures.values.compactMap(\.message).first.map { "Some reading history could not be synced: " + $0 }
                if let usageProblem = usageLane?.problem { problem = usageProblem }
                if !rootErrors.isEmpty { problem = "Some retained reading history could not be read." }
                if problem == nil { lastChecked = now }
            }
            let disk = try await readDisk(booksDirectory, index: index, stillCurrent: stillCurrent) { rootErrors.append($0) }
            try checkCurrent()
            let listed = Self.statisticsListing(listing)
            if !flush, !retryFailed, failures.isEmpty, rootErrors.isEmpty, disk.invalidShards.isEmpty,
               index.settled == settledSignature(disk, listed) {
                try await finish()
                return errors
            }
            var roots = Dictionary(uniqueKeysWithValues: disk.roots.map { ($0.syncId, $0) })
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
                if let existing = roots[id], let book = existing.book,
                   let current = BookStorage.loadMetadata(root: existing.root), current.id == book.id,
                   syncId(for: current) == id { return existing.root }
                // An installed book may have been removed/replaced while decoding or merging.
                // Keep remote evidence in retained history; never recreate its payload folder.
                if roots[id]?.book != nil { roots.removeValue(forKey: id) }
                let contentType = type.flatMap { ContentType(rawValue: $0.lowercased()) }
                let root = try StatisticsHistory.historyRoot(id, title: title, type: contentType, directory: booksDirectory)
                let info = StatisticsHistory.info(root)
                roots[id] = StatisticsRoot(syncId: id, root: root, title: info?.title, contentType: info?.contentType, book: nil)
                return root
            }
            var readThisPass = Set<String>(), touched = Set<String>()
            // Apply each key only after all its rows are safely saved, including own keys after restore.
            try checkCurrent()
            for meta in listing.values.filter({ $0.key.hasPrefix(Self.prefix) }).sorted(by: { $0.key < $1.key }) {
                guard let parsed = Self.parse(meta.key), index.applied[meta.key] != meta.etag || meta.etag == nil || disk.invalidShards.contains(meta.key), !blocked(meta.key, meta.etag) else { continue }
                do {
                    try checkCurrent()
                    guard let fetched = try await transport.getBounded(key: meta.key, maxBytes: parsed.month == "settings" ? 65_536 : 4 * 1024 * 1024) else {
                        throw HttpSyncError("Statistics disappeared", skip: true)
                    }
                    try checkCurrent()
                    if parsed.month == "settings" {
                        let version = try JSONDecoder().decode(Version.self, from: fetched.body).version
                        guard version <= 1 else { throw HttpSyncError("Statistics need a newer app", skip: true) }
                        guard version == 1 else { throw HttpSyncError("Unsupported statistics version") }
                        let value = try JSONDecoder().decode(HttpStatisticsPreferences.self, from: fetched.body)
                        index.preferences[meta.key] = value
                    } else {
                        let shard = try await HttpStatisticsDecode.shard(fetched.body, device: parsed.device, month: parsed.month)
                        try checkCurrent()
                        for (id, value) in shard.books.sorted(by: { $0.key < $1.key }) {
                            let reading = value.reading, text = value.mangaText
                            guard !reading.isEmpty || !text.isEmpty else { continue }
                            var committed = false
                            for _ in 0..<8 {
                                try checkCurrent()
                                let root = try rootFor(id, title: value.title ?? reading.first?.title, type: value.contentType ?? (text.isEmpty ? nil : "mokuro"))
                                try ReadingStatisticsStore.migrate(root: root)
                                let prepared: HttpStatisticsPreparedBook
                                do { prepared = try await HttpStatisticsPreparedBook.prepare(root: root, reading: reading, text: text) }
                                catch where !FileManager.default.fileExists(atPath: root.path) { continue }
                                try checkCurrent()
                                if try prepared.commit(stillCurrent: stillCurrent) {
                                    if prepared.changed { touched.insert(id) }
                                    committed = true; break
                                }
                            }
                            guard committed else { throw HttpSyncError("Reading history changed during sync; it will be retried.") }
                        }
                        try await HttpStatisticsDisk.cache(fetched.body, key: meta.key, scope: scope, booksDirectory: booksDirectory)
                        try checkCurrent()
                    }
                    readThisPass.insert(meta.key)
                    index.applied[meta.key] = fetched.etag
                    index.hashes[meta.key] = sha(fetched.body)
                    failures.removeValue(forKey: meta.key)
                } catch { try checkCurrent(); fail(meta.key, meta.etag, error, quiet: (error as? HttpSyncError)?.skip == true) }
            }
            // Legacy keys for every book on the server, regardless of payload availability or tombstones.
            for key in listed.keys.filter({ $0.hasPrefix("books/") }).sorted() {
                let parts = key.split(separator: "/").map(String.init)
                guard parts.count == 3, parts[0] == "books", StatisticsHistory.validID(parts[1]), ["statistics", "manga_statistics"].contains(parts[2]), roots[parts[1]] == nil else { continue }
                _ = try rootFor(parts[1], title: nil, type: listing["books/\(parts[1])/manga_statistics"] == nil ? nil : "mokuro")
            }
            let legacyDue = flush || now.timeIntervalSince(lastLegacyPush) >= 180
            var legacy = index.legacy ?? [:], quietBooks: [String] = [], legacySettled = true
            func legacySignature(_ id: String, _ stamps: String?) -> String? {
                stamps.map { $0 + "|" + (listed["books/\(id)/statistics"] ?? "") + "|" + (listed["books/\(id)/manga_statistics"] ?? "") }
            }
            for item in roots.values.sorted(by: { $0.syncId < $1.syncId }) {
                let key = "books/\(item.syncId)/statistics"
                guard !blocked(key, listing[key]?.etag) else { legacySettled = false; continue }
                // Files and server copies as its last exchange left them: nothing to exchange.
                if !retryFailed, !touched.contains(item.syncId), let signature = legacySignature(item.syncId, disk.stamps[item.syncId]), legacy[item.syncId] == signature { continue }
                legacy[item.syncId] = nil
                do {
                    let exchanged = try await HttpReadingStatisticsSync.shared.exchange(root: item.root, syncId: item.syncId, transport: transport, listing: listing, uploadLocal: legacyDue, stillCurrent: stillCurrent)
                    try checkCurrent()
                    if exchanged {
                        legacySettled = false
                    } else { quietBooks.append(item.syncId) }
                    if item.book == nil, item.title == nil, let title = try ReadingStatisticsStore.strictReading(root: item.root).first?.title {
                        _ = try rootFor(item.syncId, title: title, type: item.contentType?.rawValue)
                    }
                    failures.removeValue(forKey: key)
                } catch { try checkCurrent(); legacySettled = false; fail(key, listing[key]?.etag, error, quiet: (error as? HttpSyncError)?.skip == true) }
            }
            if legacyDue { lastLegacyPush = now }
            try checkCurrent()
            // Re-read after all network awaits: live sessions and deletes may have changed the roots.
            let current = try await readDisk(booksDirectory, index: index, stillCurrent: stillCurrent) { rootErrors.append($0) }
            try checkCurrent()
            errors += rootErrors
            let shards = await HttpStatisticsDisk.shards(roots: current.roots, device: own.id)
            try checkCurrent()
            var canPublish = rootErrors.isEmpty
            for item in current.roots {
                if let message = shards.errors[item.syncId] { canPublish = false; fail("local:\(item.syncId)", nil, HttpSyncError(message)) }
                else { failures.removeValue(forKey: "local:\(item.syncId)") }
            }
            var listedAfter = listed
            if canPublish, flush || now.timeIntervalSince(lastPush) >= 30 {
                for (month, shard) in shards.months.sorted(by: { $0.key < $1.key }) {
                    let key = Self.prefix + own.id + "/" + month + ".json"
                    guard index.hashes[key] != shard.sha || listing[key] == nil else { continue }
                    // Never overwrite a server month this install has not successfully read.
                    guard listing[key] == nil || readThisPass.contains(key) || (index.applied[key] != nil && index.applied[key] == listing[key]?.etag), !blocked(key, listing[key]?.etag) else { continue }
                    do {
                        let response = try await transport.put(key: key, contentType: "application/json; charset=utf-8", body: shard.body)
                        try checkCurrent()
                        noteUploaded(response, key: key, scope: scope, observed: listing[key])
                        try await HttpStatisticsDisk.cache(shard.body, key: key, scope: scope, booksDirectory: booksDirectory)
                        try checkCurrent()
                        index.applied[key] = response.etag; index.hashes[key] = shard.sha; failures.removeValue(forKey: key)
                        listedAfter[key] = Self.listed(response)
                    } catch { try checkCurrent(); fail(key, listing[key]?.etag, error) }
                }
                lastPush = now
            }
            let monthsSynced = shards.months.allSatisfy { month, shard in
                let key = Self.prefix + own.id + "/" + month + ".json"
                return index.hashes[key] == shard.sha && listedAfter[key] != nil
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
                    try checkCurrent()
                    noteUploaded(response, key: settingsKey, scope: scope, observed: listing[settingsKey])
                    index.applied[settingsKey] = response.etag; index.hashes[settingsKey] = sha(settingsBody); index.preferences[settingsKey] = local
                    failures.removeValue(forKey: settingsKey)
                    listedAfter[settingsKey] = Self.listed(response)
                } catch { try checkCurrent(); fail(settingsKey, listing[settingsKey]?.etag, error) }
            }
            // The stamps read before the exchange: a save after it must still look new.
            for id in quietBooks where !touched.contains(id) { legacy[id] = legacySignature(id, disk.stamps[id]) }
            legacy = legacy.filter { current.stamps[$0.key] != nil }
            index.legacy = legacy.isEmpty ? nil : legacy
            let settingsSynced = local.updatedAt <= 0 || index.hashes[settingsKey] == sha(settingsBody)
            index.validatedDisk = current.invalidShards.isEmpty ? current.digest : nil
            let settled = errors.isEmpty && failures.isEmpty && legacySettled && monthsSynced && settingsSynced && current.invalidShards.isEmpty && !current.needsAbsorb && current.digest == disk.digest
            index.settled = settled ? settledSignature(current, listedAfter) : nil
            try await finish()
        } catch {
            guard !Task.isCancelled, stillCurrent() else { return [] }
            errors.append(error.localizedDescription); markFailed(error)
        }
        return errors
    }
    private struct Version: Decodable { let version: Int }

    private func readDisk(_ booksDirectory: URL, index: Index, stillCurrent: @MainActor () -> Bool, onError: (String) -> Void) async throws -> HttpStatisticsDisk {
        let disk = await HttpStatisticsDisk.read(booksDirectory: booksDirectory, stateFile: HttpReadingStatisticsSync.stateFile, applied: index.applied, hashes: index.hashes, scope: index.scope, validatedDisk: index.validatedDisk)
        guard !Task.isCancelled, stillCurrent() else { throw CancellationError() }
        guard disk.needsAbsorb else { disk.errors.forEach(onError); return disk }
        var reported: [String] = []
        _ = try StatisticsHistory.roots(directory: booksDirectory, onError: { id, error in reported.append("\(id): \(error.localizedDescription)") })
        reported.forEach(onError)
        let absorbed = await HttpStatisticsDisk.read(booksDirectory: booksDirectory, stateFile: HttpReadingStatisticsSync.stateFile, applied: index.applied, hashes: index.hashes, scope: index.scope, validatedDisk: index.validatedDisk)
        guard !Task.isCancelled, stillCurrent() else { throw CancellationError() }
        return absorbed
    }
    private static func listed(_ meta: HttpSyncKvKeyMeta) -> String { "\(meta.etag ?? "")|\(meta.size ?? -1)|\(meta.lastModified)" }
    /// The statistics keys as listed, so an unchanged server is recognized without reading anything.
    private static func statisticsListing(_ listing: [String: HttpSyncKvKeyMeta]) -> [String: String] {
        listing.filter { key, _ in parse(key) != nil || (key.hasPrefix("books/") && (key.hasSuffix("/statistics") || key.hasSuffix("/manga_statistics"))) }
            .mapValues(listed)
    }
    private func settledSignature(_ disk: HttpStatisticsDisk, _ listed: [String: String]) -> String {
        let preferences = StatisticsPreferencesStore.load(defaults: defaults)
        let server = listed.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }.joined(separator: "\n")
        return sha(Data((disk.digest + "\n\(preferences.streakMinimumMinutes)|\(preferences.dayResetHour)|\(preferences.updatedAt)|\(preferences.timeZone ?? "")\n" + server).utf8))
    }
}
