import Foundation

nonisolated struct PodcastTranscriptLine: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
    var text: String
    var english: String?
}

/// Times refer to the original recording, never to the generated lesson.
nonisolated struct PodcastTranscript: Codable, Equatable, Sendable {
    static let maximumBytes = 2 * 1024 * 1024
    var version = 1
    var episode = ""
    var duration: Double = 0
    var lines: [PodcastTranscriptLine] = []

    init(version: Int = 1, episode: String = "", duration: Double = 0, lines: [PodcastTranscriptLine] = []) {
        self.version = version; self.episode = episode; self.duration = duration; self.lines = lines
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        episode = try c.decodeIfPresent(String.self, forKey: .episode) ?? ""
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        lines = try c.decodeIfPresent([PodcastTranscriptLine].self, forKey: .lines) ?? []
    }
    static func parse(data: Data, episodeID: String) -> Self? {
        guard data.count <= maximumBytes, PodcastRules.validID(episodeID),
              let value = try? PodcastRules.decoder().decode(Self.self, from: data) else { return nil }
        return value.validated(episodeID: episodeID)
    }
    func validated(episodeID: String) -> Self? {
        guard version == 1, episode == episodeID, duration.isFinite, duration >= 0 else { return nil }
        var copy = self
        copy.lines = lines.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start
        }
        guard !copy.lines.isEmpty,
              !zip(copy.lines, copy.lines.dropFirst()).contains(where: { pair in pair.1.start < pair.0.start }) else { return nil }
        return copy
    }
    /// Keep the preceding line highlighted during pauses; repeated starts choose the last line.
    func line(at seconds: Double) -> Int? {
        guard seconds.isFinite else { return nil }
        var low = 0, high = lines.count - 1
        var found: Int?
        while low <= high {
            let middle = (low + high) / 2
            if lines[middle].start <= seconds { found = middle; low = middle + 1 }
            else { high = middle - 1 }
        }
        return found
    }
}

nonisolated enum PodcastDownloadPart: String, Sendable {
    case lesson, transcript, original
    var isTranscript: Bool { self != .lesson }
    var suffix: String { self == .lesson ? "audio" : rawValue }
    var maximumBytes: Int64 { self == .transcript ? Int64(PodcastTranscript.maximumBytes) : 512 * 1024 * 1024 }
    func validate(response: HTTPURLResponse, fileSize: Int64) throws {
        guard fileSize > 0, fileSize <= maximumBytes else {
            throw PodcastHTTPError(status: 0, message: "The downloaded podcast file is empty or too large.")
        }
        // URLSession transparently decodes Content-Encoding. Its response length can still
        // name the compressed wire bytes, while the staged file contains decoded JSON/audio.
        let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let encoded = encoding != nil && encoding != "" && encoding != "identity"
        guard encoded || response.expectedContentLength < 0 || response.expectedContentLength == fileSize else {
            throw PodcastHTTPError(status: 0, message: "The podcast download is incomplete.")
        }
        if self != .transcript, response.mimeType?.lowercased() != "audio/mpeg" {
            throw PodcastHTTPError(status: 0, message: "The server did not return an MP3 recording.")
        }
    }
}

/// Distinct task keys allow a lesson and its original recording to download independently.
/// Legacy lesson descriptions remain readable after updating or a background-session relaunch.
nonisolated struct PodcastDownloadReference: Equatable, Sendable {
    let account: String
    let id: String
    var part: PodcastDownloadPart = .lesson
    var attempt = 0
    var key: String { account + "|" + id + (part.isTranscript ? "|transcript" : "") }
    var description: String {
        if part == .lesson { return account + "|" + id + (attempt > 0 ? "|\(attempt)" : "") }
        return account + "|" + id + "|" + part.rawValue + "|\(attempt)"
    }
    init(account: String, id: String, part: PodcastDownloadPart = .lesson, attempt: Int = 0) {
        self.account = account; self.id = id; self.part = part; self.attempt = attempt
    }
    init?(_ description: String?) {
        let fields = (description ?? "").split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard (2...4).contains(fields.count), PodcastRules.validID(fields[0]), PodcastRules.validID(fields[1]) else { return nil }
        account = fields[0]; id = fields[1]
        if fields.count == 3 {
            guard let retry = Int(fields[2]), (1...2).contains(retry) else { return nil }
            attempt = retry
        } else if fields.count == 4 {
            guard let kind = PodcastDownloadPart(rawValue: fields[2]), kind != .lesson,
                  let retry = Int(fields[3]), (0...2).contains(retry) else { return nil }
            part = kind; attempt = retry
        }
    }
}
