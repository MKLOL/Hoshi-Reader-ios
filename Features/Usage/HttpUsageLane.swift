import Foundation
import CryptoKit

/// Each installation owns only its own gzip keys. Other devices' raw logs stay in a separate cache.
@MainActor final class HttpUsageLane {
    static let shared = HttpUsageLane()
    static let prefix = "sync/maps/usage/"
    static let suffix = ".ndjson.gz"
    nonisolated struct Key: Sendable { let device: String; let day: String?; let month: String }
    private struct Index: Codable {
        var scope = ""
        var applied: [String: String] = [:]
        var hashes: [String: String] = [:]
        var stamps: [String: String] = [:]
        var days: [String: [String]] = [:]
    }
    private struct Failure { var etag: String?; var attempts: Int; var retry: Date; var message: String? }
    nonisolated private struct LineStamp: Decodable { let at: Int64; let utcOffset: String? }
    private var failures: [String: Failure] = [:]
    private var lastPush = Date.distantPast
    private let log: UsageLog
    private let clock: () -> Date
    var problem: String? { failures.values.compactMap(\.message).first }
    init(log: UsageLog = .shared, now: @escaping () -> Date = Date.init) { self.log = log; clock = now }
    static func parse(_ key: String) -> Key? {
        guard key.hasPrefix(prefix), key.hasSuffix(suffix) else { return nil }
        let parts = key.dropFirst(prefix.count).dropLast(suffix.count).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, StatisticsHistory.validID(parts[0]) else { return nil }
        let date = parts[1]
        if date.count == 10, ReadingDay.parse(date) != nil { return Key(device: parts[0], day: date, month: String(date.prefix(7))) }
        if date.count == 7, ReadingDay.parse(date + "-01") != nil { return Key(device: parts[0], day: nil, month: date) }
        return nil
    }
    nonisolated private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    nonisolated private static func days(_ data: Data, key: Key) throws -> [String: Data] {
        if let day = key.day { return [day: data] }
        var result: [String: Data] = [:]
        var formatters: [String: DateFormatter] = [:]
        let decoder = JSONDecoder()
        for line in data.split(separator: 10) {
            try Task.checkCancellation()
            guard let stamp = try? decoder.decode(LineStamp.self, from: Data(line)) else { continue }
            let zone = StatisticsZone.zone(stamp.utcOffset) ?? TimeZone(secondsFromGMT: 0)!
            let formatter: DateFormatter
            if let old = formatters[zone.identifier] { formatter = old }
            else {
                formatter = DateFormatter(); formatter.calendar = StatisticsZone.calendar(zone: zone); formatter.timeZone = zone
                formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
                formatters[zone.identifier] = formatter
            }
            let day = formatter.string(from: Date(timeIntervalSince1970: Double(stamp.at) / 1000))
            guard day.hasPrefix(key.month + "-") else { continue }
            result[day, default: Data()].append(contentsOf: line); result[day]!.append(10)
        }
        return result
    }
    /// Called under the statistics lane's serialization, so manual, periodic and close passes cannot overlap.
    func run(transport: any HttpSyncKvTransport, listing: [String: HttpSyncKvKeyMeta], deviceID: String, scope: String, flush: Bool, retryFailed: Bool, stillCurrent: @escaping @MainActor () -> Bool = { true }) async -> [String] {
        guard !Task.isCancelled, stillCurrent() else { return [] }
        let now = clock(), currentDay = MangaStatisticsTracker.dateKey(for: now), currentMonth = String(currentDay.prefix(7))
        var failures = self.failures, lastPush = self.lastPush
        var errors: [String] = []
        func checkCurrent() throws {
            try Task.checkCancellation()
            guard stillCurrent() else { throw CancellationError() }
        }
        do {
            let indexURL = log.directory.appendingPathComponent(".http_sync_usage_lane.json")
            var index = BookStorage.load(Index.self, from: indexURL) ?? Index()
            if index.scope != scope {
                try await log.clearDeviceDays()
                try checkCurrent()
                index = Index(scope: scope); failures = [:]; lastPush = .distantPast
            }
            let metas = listing.filter { Self.parse($0.key) != nil }
            func blocked(_ key: String, _ etag: String?) -> Bool {
                guard !retryFailed, let failure = failures[key] else { return false }
                return failure.etag == etag && failure.retry > now
            }
            func fail(_ key: String, _ etag: String?, _ error: Error, quiet: Bool = false) {
                let attempts = failures[key]?.etag == etag ? (failures[key]?.attempts ?? 0) + 1 : 1
                let message = quiet ? nil : "\(key): \(error.localizedDescription)"
                failures[key] = Failure(etag: etag, attempts: attempts, retry: now.addingTimeInterval(min(600, 30 * pow(2, Double(min(5, attempts - 1))))), message: message)
                if let message { errors.append(message) }
            }
            var readThisPass = Set<String>()
            // Day records sort before the corresponding compacted month. The month is authoritative.
            for (key, meta) in metas.sorted(by: { $0.key < $1.key }) {
                let parsed = Self.parse(key)!, own = parsed.device == deviceID
                let cached = own ? log.hasOwnDays(index.days[key] ?? []) : log.hasDeviceDays(index.days[key] ?? [], device: parsed.device)
                if let etag = meta.etag, index.applied[key] == etag, cached { continue }
                if blocked(key, meta.etag) { continue }
                do {
                    try checkCurrent()
                    guard let fetched = try await transport.getBounded(key: key, maxBytes: UsageGzip.compressedLimit) else { throw HttpSyncError("Usage log disappeared", skip: true) }
                    try checkCurrent()
                    let decode = Task.detached(priority: .utility) { (try Self.days(UsageGzip.expand(fetched.body), key: parsed), Self.hash(fetched.body)) }
                    let decoded = try await withTaskCancellationHandler { try await decode.value } onCancel: { decode.cancel() }
                    try checkCurrent()
                    let grouped = decoded.0
                    try await log.store(days: grouped, device: own ? nil : parsed.device, mergeOwn: own)
                    try checkCurrent()
                    index.applied[key] = fetched.etag; index.hashes[key] = decoded.1; index.days[key] = grouped.keys.sorted()
                    if own { index.stamps.removeValue(forKey: key) }
                    readThisPass.insert(key); failures.removeValue(forKey: key)
                } catch {
                    try checkCurrent()
                    fail(key, meta.etag, error, quiet: (error as? HttpSyncError)?.skip == true)
                }
            }
            let ownFiles = try await log.ownFiles()
            try checkCurrent()
            let byMonth = Dictionary(grouping: ownFiles, by: { String($0.day.prefix(7)) })
            var units: [(key: String, files: [UsageLog.DayFile], finished: Bool)] = []
            for (month, files) in byMonth {
                if month < currentMonth { units.append((Self.prefix + deviceID + "/" + month + Self.suffix, files, true)) }
                else { for file in files { units.append((Self.prefix + deviceID + "/" + file.day + Self.suffix, [file], file.day < currentDay)) } }
            }
            var confirmed = Set<String>(), pushed = false
            for unit in units.sorted(by: { $0.key < $1.key }) {
                try checkCurrent()
                guard unit.finished || flush || now.timeIntervalSince(lastPush) >= 120, !blocked(unit.key, metas[unit.key]?.etag) else { continue }
                let parsed = Self.parse(unit.key)!
                // Merge every server copy for the month before a compaction or restore can replace it.
                let unread = metas.contains { key, meta in
                    guard let remote = Self.parse(key), remote.device == deviceID, remote.month == parsed.month, parsed.day == nil || key == unit.key else { return false }
                    return !readThisPass.contains(key) && (meta.etag == nil || index.applied[key] != meta.etag)
                }
                guard !unread else { continue }
                let stamp = unit.files.map(\.stamp).joined(separator: "|")
                if index.stamps[unit.key] == stamp, metas[unit.key] != nil { confirmed.insert(unit.key); continue }
                do {
                    let raw = try await log.bytes(files: unit.files)
                    try checkCurrent()
                    let compressed = try await Task.detached { let body = try UsageGzip.compress(raw); return (body, Self.hash(body)) }.value
                    try checkCurrent()
                    let body = compressed.0
                    if index.hashes[unit.key] != compressed.1 || metas[unit.key] == nil {
                        let response = try await transport.put(key: unit.key, contentType: "application/gzip", body: body)
                        try checkCurrent()
                        index.applied[unit.key] = response.etag; index.hashes[unit.key] = compressed.1; pushed = true
                    }
                    index.stamps[unit.key] = stamp; index.days[unit.key] = unit.files.map(\.day)
                    confirmed.insert(unit.key); failures.removeValue(forKey: unit.key)
                } catch { try checkCurrent(); fail(unit.key, metas[unit.key]?.etag, error) }
            }
            // Only own past-day keys are removed, after their complete month was confirmed.
            for (key, meta) in metas {
                guard let parsed = Self.parse(key), parsed.device == deviceID, parsed.day != nil, parsed.month < currentMonth,
                      confirmed.contains(Self.prefix + deviceID + "/" + parsed.month + Self.suffix), !blocked(key, meta.etag),
                      readThisPass.contains(key) || (meta.etag != nil && index.applied[key] == meta.etag) else { continue }
                do { try checkCurrent(); try await transport.delete(key: key); try checkCurrent(); index.applied.removeValue(forKey: key); index.hashes.removeValue(forKey: key); failures.removeValue(forKey: key) }
                catch { try checkCurrent(); fail(key, meta.etag, error) }
            }
            if pushed { lastPush = now }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(index)
            try FileManager.default.createDirectory(at: log.directory, withIntermediateDirectories: true)
            if (try? Data(contentsOf: indexURL)) != data { try data.write(to: indexURL, options: .atomic) }
            self.failures = failures; self.lastPush = lastPush
        } catch {
            guard !Task.isCancelled, stillCurrent() else { return [] }
            errors.append(error.localizedDescription)
        }
        return errors
    }
}
