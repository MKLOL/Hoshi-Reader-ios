import Foundation

@MainActor final class PodcastFiles {
    let root: URL
    private struct TranscriptStamp: Equatable {
        let modified: Date
        let size: Int
        let inode: UInt64
    }
    private var transcriptAvailability: [URL: (stamp: TranscriptStamp, valid: Bool)] = [:]
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
            guard newValue != validatedAccount else { return }
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
    func originalAudio(account: String, id: String) -> URL? { path(account: account, id: id, suffix: ".original.mp3") }
    func transcript(account: String, id: String) -> URL? { path(account: account, id: id, suffix: ".transcript.json") }
    private func pendingTranscript(account: String, id: String) -> URL? { path(account: account, id: id, suffix: ".transcript.pending.json") }
    private func path(account: String, id: String, suffix: String) -> URL? {
        guard PodcastRules.validID(account), PodcastRules.validID(id) else { return nil }
        return root.appendingPathComponent(account).appendingPathComponent(id + suffix)
    }
    private func nonempty(_ url: URL?) -> Bool {
        guard let url, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
        return size > 0
    }
    func isTranscriptDownloaded(account: String, id: String) -> Bool {
        guard nonempty(originalAudio(account: account, id: id)), let url = transcript(account: account, id: id),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int, size > 0, size <= PodcastTranscript.maximumBytes,
              let modified = attributes[.modificationDate] as? Date else { return false }
        let stamp = TranscriptStamp(modified: modified, size: size, inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
        if let cached = transcriptAvailability[url], cached.stamp == stamp { return cached.valid }
        let valid = (try? transcriptData(at: url, id: id)) != nil
        transcriptAvailability[url] = (stamp, valid)
        return valid
    }
    func hasSavedMedia(account: String, id: String) -> Bool {
        isDownloaded(account: account, id: id) || isTranscriptDownloaded(account: account, id: id)
    }
    private func transcriptData(at url: URL?, id: String) throws -> Data {
        guard let url, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= PodcastTranscript.maximumBytes else {
            throw PodcastHTTPError(status: 0, message: "The podcast transcript is empty or too large.")
        }
        let data = try Data(contentsOf: url)
        guard PodcastTranscript.parse(data: data, episodeID: id) != nil else {
            throw PodcastHTTPError(status: 0, message: "The podcast transcript is invalid. Try downloading it again.")
        }
        return data
    }
    func loadTranscript(account: String, id: String) -> PodcastTranscript? {
        guard isTranscriptDownloaded(account: account, id: id),
              let data = try? transcriptData(at: transcript(account: account, id: id), id: id) else { return nil }
        return PodcastTranscript.parse(data: data, episodeID: id)
    }
    /// Validate and persist the small half before requesting the original recording.
    func stageTranscript(_ staged: URL, account: String, id: String) throws {
        let data = try transcriptData(at: staged, id: id)
        _ = try directory(account)
        guard let destination = pendingTranscript(account: account, id: id) else { throw CocoaError(.fileReadInvalidFileName) }
        try data.write(to: destination, options: .atomic)
    }
    /// The final transcript is the completion marker. A failed/interrupted recording cannot
    /// make the UI advertise a transcript whose original audio is not present.
    func installAudio(_ staged: URL, account: String, id: String, original: Bool = false) throws {
        _ = try directory(account)
        let text = original ? try transcriptData(at: pendingTranscript(account: account, id: id), id: id) : nil
        guard let destination = original ? originalAudio(account: account, id: id) : audio(account: account, id: id) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        guard nonempty(staged) else { throw PodcastHTTPError(status: 0, message: "The downloaded recording is empty.") }
        if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged) }
        else { try FileManager.default.moveItem(at: staged, to: destination) }
        if let text, let destination = transcript(account: account, id: id) {
            try text.write(to: destination, options: .atomic)
            transcriptAvailability[destination] = nil
            if let pending = pendingTranscript(account: account, id: id) { try? FileManager.default.removeItem(at: pending) }
        }
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
        let ids = Set(saved.episodes.filter { hasSavedMedia(account: account, id: $0.id) }.map(\.id))
        return cached.retaining(saved, downloaded: ids).withoutTelemetry
    }
    func save(_ catalogue: PodcastCatalogue, account: String) throws -> PodcastCatalogue {
        let previous = load(account)
        var saved = read(account, "downloads.json")
        let ids = Set((previous.episodes + saved.episodes).filter { hasSavedMedia(account: account, id: $0.id) }.map(\.id))
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
        transcriptAvailability = transcriptAvailability.filter { $0.key.deletingLastPathComponent().lastPathComponent == account }
        guard PodcastRules.validID(account), let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for entry in entries where entry.lastPathComponent != account && PodcastRules.validID(entry.lastPathComponent) { try? FileManager.default.removeItem(at: entry) }
    }
    func position(account: String, id: String, original: Bool = false) -> Double {
        guard let directory = try? directory(account), let data = try? Data(contentsOf: directory.appendingPathComponent("positions.json")), let rows = try? JSONDecoder().decode([String: Double].self, from: data) else { return 0 }
        return rows[id + (original ? ":original" : "")] ?? 0
    }
    func savePosition(_ value: Double, account: String, id: String, original: Bool = false) {
        guard value.isFinite, value >= 0, PodcastRules.validID(id), let directory = try? directory(account) else { return }
        let file = directory.appendingPathComponent("positions.json")
        var rows = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: Double].self, from: $0) } ?? [:]
        rows[id + (original ? ":original" : "")] = value
        if let data = try? JSONEncoder().encode(rows) { try? data.write(to: file, options: .atomic) }
    }
}
