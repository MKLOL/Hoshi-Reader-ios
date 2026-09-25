import Foundation
import CryptoKit

nonisolated struct PodcastEpisode: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var title: String
    var publishedAt: String
    var durationSeconds = 0
    var status: String
    var lessonDurationSeconds: Double?
    var errorCode: String?
    var errorMessage: String?
    var failureCount = 0
    var show = ""
    var retryable = true
    func needsAdministrator(maxFailures: Int?) -> Bool {
        status == "failed" && (!retryable || maxFailures.map { failureCount >= $0 } == true)
    }
}
nonisolated extension PodcastEpisode {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        publishedAt = try c.decode(String.self, forKey: .publishedAt)
        durationSeconds = try c.decodeIfPresent(Int.self, forKey: .durationSeconds) ?? 0
        status = try c.decode(String.self, forKey: .status)
        lessonDurationSeconds = try c.decodeIfPresent(Double.self, forKey: .lessonDurationSeconds)
        errorCode = try c.decodeIfPresent(String.self, forKey: .errorCode)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        failureCount = try c.decodeIfPresent(Int.self, forKey: .failureCount) ?? 0
        show = try c.decodeIfPresent(String.self, forKey: .show) ?? ""
        retryable = try c.decodeIfPresent(Bool.self, forKey: .retryable) ?? true
    }
}
nonisolated struct PodcastShow: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var feedStale: Bool? = false
}
nonisolated struct PodcastWorker: Codable, Sendable {
    var alive: Bool?
    var lastSeenSeconds: Int?
    var problems: [String]?
}
nonisolated struct PodcastGeneration: Codable, Sendable {
    var episode: String
    var stage: String
    var done: Int
    var total: Int
    var percent: Int
    var ageSeconds: Int?
    func progress(for id: String, worker: PodcastWorker?, elapsed: TimeInterval) -> Double? {
        guard episode == id, total > 0, worker?.alive != false,
              (ageSeconds ?? 0) >= 0, Double(ageSeconds ?? 0) + max(0, elapsed) < 90 else { return nil }
        return Double(min(100, max(0, percent))) / 100
    }
    var stageLabel: String {
        switch stage {
        case "download": return "Fetching the recording"
        case "transcription": return "Transcribing the Japanese"
        case "segmentation": return "Finding sentence boundaries"
        case "translation": return "Translating"
        case "vocabulary": return "Choosing vocabulary"
        case "speech": return "Recording the voices"
        case "render": return "Assembling the lesson"
        default: return "Preparing lesson"
        }
    }
}
nonisolated extension PodcastGeneration {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        episode = try c.decodeIfPresent(String.self, forKey: .episode) ?? ""
        stage = try c.decodeIfPresent(String.self, forKey: .stage) ?? ""
        done = try c.decodeIfPresent(Int.self, forKey: .done) ?? 0
        total = try c.decodeIfPresent(Int.self, forKey: .total) ?? 0
        percent = try c.decodeIfPresent(Int.self, forKey: .percent) ?? 0
        ageSeconds = try c.decodeIfPresent(Int.self, forKey: .ageSeconds)
    }
}
nonisolated struct PodcastCatalogue: Codable, Sendable {
    var episodes: [PodcastEpisode] = []
    var shows: [PodcastShow] = []
    var feedStale = false
    var worker: PodcastWorker?
    var maxFailures: Int?
    var generating: PodcastGeneration?

    var withoutTelemetry: Self { var copy = self; copy.worker = nil; copy.generating = nil; return copy }
    func retaining(_ saved: Self, downloaded: Set<String>) -> Self {
        var copy = self
        var ids = Set<String>()
        copy.episodes = episodes.filter { PodcastRules.validID($0.id) && ids.insert($0.id).inserted }
        let retained = saved.episodes.filter { downloaded.contains($0.id) && ids.insert($0.id).inserted }
        copy.episodes += retained
        copy.episodes.sort { $0.publishedAt > $1.publishedAt }
        var showIDs = Set(shows.map(\.id))
        copy.shows += saved.shows.filter { show in retained.contains { $0.show == show.id } && showIDs.insert(show.id).inserted }
        return copy
    }
}
nonisolated extension PodcastCatalogue {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        episodes = try c.decodeIfPresent([PodcastEpisode].self, forKey: .episodes) ?? []
        shows = try c.decodeIfPresent([PodcastShow].self, forKey: .shows) ?? []
        feedStale = try c.decodeIfPresent(Bool.self, forKey: .feedStale) ?? false
        worker = try c.decodeIfPresent(PodcastWorker.self, forKey: .worker)
        maxFailures = try c.decodeIfPresent(Int.self, forKey: .maxFailures)
        generating = try c.decodeIfPresent(PodcastGeneration.self, forKey: .generating)
    }
}
nonisolated enum PodcastLength: String, CaseIterable {
    case all = "All lengths", short = "≤10 min", medium = "10–20 min", long = ">20 min"
    func includes(_ episode: PodcastEpisode) -> Bool {
        switch self {
        case .all: return true
        case .short: return (1...600).contains(episode.durationSeconds)
        case .medium: return (601...1200).contains(episode.durationSeconds)
        case .long: return episode.durationSeconds > 1200
        }
    }
}
nonisolated enum PodcastRules {
    static func validID(_ value: String) -> Bool { value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    static func account(baseURL: String, token: String) -> String {
        SHA256.hash(data: Data((baseURL + "\n" + token).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func display(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.replacingOccurrences(of: #"[\p{Z}\p{Cc}\p{Cf}]+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : String(result.prefix(300))
    }
    /// Underlying file and transport errors can contain private paths or URLs. Only the
    /// server's deliberately supplied error text is suitable for direct display.
    static func failureMessage(_ error: Error) -> String {
        if let error = error as? PodcastHTTPError { return display(error.message) ?? "The podcast request failed." }
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost: return "The network connection was lost. Try again when connected."
            case .timedOut: return "The podcast server took too long to respond. Try again."
            case .cancelled: return "The download was cancelled."
            default: return "Could not reach the podcast server. Try again."
            }
        }
        if error is DecodingError { return "The podcast server returned an invalid response." }
        if error is CocoaError { return "Could not save the lesson. Check the available storage and try again." }
        return "The podcast operation failed. Try again."
    }
    static func decoder() -> JSONDecoder { let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; return d }
    static func encoder() -> JSONEncoder { let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase; e.outputFormatting = [.sortedKeys]; return e }
}

/// Session task IDs are unique for the lifetime of a URLSession. A generation distinguishes
/// a cancelled transfer from a new one even when the user returns to the same account.
nonisolated struct PodcastDownloadEpochs {
    private var generation = 0
    private var tasks: [Int: Int] = [:]
    private var cancelledThrough: [String: Int] = [:]

    mutating func record(_ taskID: Int) { tasks[taskID] = tasks[taskID] ?? generation }
    mutating func retire(accounts: Set<String>) {
        for account in accounts { cancelledThrough[account] = generation }
        generation += 1
    }
    func isRetired(_ taskID: Int, account: String) -> Bool {
        guard let cutoff = cancelledThrough[account] else { return false }
        return (tasks[taskID] ?? -1) <= cutoff
    }
    func accepts(_ taskID: Int, account: String, currentTaskID: Int?) -> Bool {
        guard !isRetired(taskID, account: account) else { return false }
        if let currentTaskID { return currentTaskID == taskID }
        // Unregistered callbacks may be queued completion events from a cold relaunch.
        return tasks[taskID] == nil
    }
}
