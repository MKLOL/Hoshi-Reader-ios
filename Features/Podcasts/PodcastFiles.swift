import Foundation

@MainActor final class PodcastFiles {
    let root: URL
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Podcasts", isDirectory: true)
    }
    private func directory(_ account: String) throws -> URL {
        guard PodcastRules.validID(account) else { throw CocoaError(.fileReadInvalidFileName) }
        var directory = root.appendingPathComponent(account, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        var parent = root; try parent.setResourceValues(values)
        return directory
    }
    var validatedAccount: String? {
        get { (try? String(contentsOf: root.appendingPathComponent("validated-account"), encoding: .utf8)) }
        set {
            guard let newValue else { try? FileManager.default.removeItem(at: root.appendingPathComponent("validated-account")); return }
            guard PodcastRules.validID(newValue), (try? directory(newValue)) != nil else { return }
            try? Data(newValue.utf8).write(to: root.appendingPathComponent("validated-account"), options: .atomic)
        }
    }
    func audio(account: String, id: String) -> URL? {
        guard PodcastRules.validID(account), PodcastRules.validID(id) else { return nil }
        return root.appendingPathComponent(account).appendingPathComponent(id + ".mp3")
    }
    func isDownloaded(account: String, id: String) -> Bool {
        guard let url = audio(account: account, id: id), let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
        return size > 0
    }
    private func read(_ account: String, _ name: String) -> PodcastCatalogue {
        guard PodcastRules.validID(account), let data = try? Data(contentsOf: root.appendingPathComponent(account).appendingPathComponent(name)) else { return PodcastCatalogue() }
        return (try? PodcastRules.decoder().decode(PodcastCatalogue.self, from: data)) ?? PodcastCatalogue()
    }
    private func write(_ catalogue: PodcastCatalogue, account: String, name: String) throws {
        let directory = try directory(account)
        try PodcastRules.encoder().encode(catalogue.withoutTelemetry).write(to: directory.appendingPathComponent(name), options: .atomic)
    }
    func load(_ account: String) -> PodcastCatalogue {
        let cached = read(account, "catalogue.json"), saved = read(account, "downloads.json")
        let ids = Set(saved.episodes.filter { isDownloaded(account: account, id: $0.id) }.map(\.id))
        return cached.retaining(saved, downloaded: ids).withoutTelemetry
    }
    func save(_ catalogue: PodcastCatalogue, account: String) throws -> PodcastCatalogue {
        let previous = load(account)
        var saved = read(account, "downloads.json")
        let ids = Set((previous.episodes + saved.episodes).filter { isDownloaded(account: account, id: $0.id) }.map(\.id))
        let merged = catalogue.retaining(previous.retaining(saved, downloaded: ids), downloaded: ids)
        var known = Set(saved.episodes.map(\.id))
        saved.episodes += merged.episodes.filter { ids.contains($0.id) && known.insert($0.id).inserted }
        var shows = Set(saved.shows.map(\.id)); saved.shows += merged.shows.filter { shows.insert($0.id).inserted }
        try write(saved, account: account, name: "downloads.json")
        try write(merged, account: account, name: "catalogue.json")
        return merged
    }
    func remember(_ episode: PodcastEpisode, account: String, shows: [PodcastShow]) throws {
        var saved = read(account, "downloads.json")
        saved.episodes.removeAll { $0.id == episode.id }; saved.episodes.append(episode)
        var ids = Set(shows.map(\.id)); saved.shows = shows + saved.shows.filter { ids.insert($0.id).inserted }
        try write(saved, account: account, name: "downloads.json")
    }
    func prune(except account: String) {
        guard PodcastRules.validID(account), let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for entry in entries where entry.lastPathComponent != account && PodcastRules.validID(entry.lastPathComponent) { try? FileManager.default.removeItem(at: entry) }
    }
    func position(account: String, id: String) -> Double {
        guard let directory = try? directory(account), let data = try? Data(contentsOf: directory.appendingPathComponent("positions.json")), let rows = try? JSONDecoder().decode([String: Double].self, from: data) else { return 0 }
        return rows[id] ?? 0
    }
    func savePosition(_ value: Double, account: String, id: String) {
        guard value.isFinite, value >= 0, PodcastRules.validID(id), let directory = try? directory(account) else { return }
        let file = directory.appendingPathComponent("positions.json")
        var rows = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: Double].self, from: $0) } ?? [:]
        rows[id] = value
        if let data = try? JSONEncoder().encode(rows) { try? data.write(to: file, options: .atomic) }
    }
}
