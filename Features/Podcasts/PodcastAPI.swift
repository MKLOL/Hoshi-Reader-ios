import Foundation

nonisolated struct PodcastHTTPError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

/// Authenticated requests never follow redirects, so a token cannot follow an audio/CDN redirect.
nonisolated final class PodcastNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

nonisolated protocol PodcastServing: Sendable {
    func access(config: HttpSyncConfig) async throws -> Bool
    func catalogue(config: HttpSyncConfig) async throws -> PodcastCatalogue
    func prepare(config: HttpSyncConfig, id: String) async throws -> PodcastEpisode
}

nonisolated struct PodcastAPI: PodcastServing {
    private static let session = URLSession(configuration: .ephemeral, delegate: PodcastNoRedirect(), delegateQueue: nil)
    static func request(config: HttpSyncConfig, suffix: String, post: Bool = false) throws -> URLRequest {
        guard let base = URLComponents(string: config.baseURL), base.user == nil, base.password == nil,
              base.query == nil, base.fragment == nil, config.isConfigured else { throw PodcastHTTPError(status: 0, message: "Set a valid HTTPS book sync server and token.") }
        guard let url = URL(string: config.baseURL + "/v1/podcasts" + suffix) else { throw PodcastHTTPError(status: 0, message: "Invalid podcast server.") }
        var request = URLRequest(url: url)
        request.setValue("Bearer " + config.token, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 45
        if post { request.httpMethod = "POST"; request.httpBody = Data() }
        return request
    }
    /// Off the caller's actor: the visible Podcasts tab polls the listing every five seconds, and
    /// reading and decoding it must not run on the main thread.
    @concurrent func get<T: Decodable & Sendable>(_ type: T.Type, config: HttpSyncConfig, suffix: String = "", post: Bool = false) async throws -> T {
        let (bytes, response) = try await Self.session.bytes(for: Self.request(config: config, suffix: suffix, post: post))
        guard let http = response as? HTTPURLResponse else { throw PodcastHTTPError(status: 0, message: "Invalid server response.") }
        var data = Data()
        let ok = (200..<300).contains(http.statusCode)
        let limit = ok ? 2 * 1024 * 1024 : 8192
        for try await byte in bytes {
            if data.count >= limit {
                if !ok { break }
                throw PodcastHTTPError(status: http.statusCode, message: "The podcast listing is too large.")
            }
            data.append(byte)
        }
        guard ok else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw PodcastHTTPError(status: http.statusCode, message: PodcastRules.display(object?["error"] as? String) ?? "HTTP \(http.statusCode)")
        }
        return try PodcastRules.decoder().decode(type, from: data)
    }
    func access(config: HttpSyncConfig) async throws -> Bool {
        struct Access: Decodable, Sendable { let enabled: Bool? }
        return try await get(Access.self, config: config, suffix: "/access").enabled ?? false
    }
    func catalogue(config: HttpSyncConfig) async throws -> PodcastCatalogue {
        try await get(PodcastCatalogue.self, config: config)
    }
    func transcript(config: HttpSyncConfig, id: String) async throws -> PodcastTranscript {
        guard PodcastRules.validID(id) else { throw PodcastHTTPError(status: 0, message: "Invalid podcast episode.") }
        let value = try await get(PodcastTranscript.self, config: config, suffix: "/\(id)/transcript")
        guard let transcript = value.validated(episodeID: id) else { throw PodcastHTTPError(status: 0, message: "The podcast transcript is invalid.") }
        return transcript
    }
    func prepare(config: HttpSyncConfig, id: String) async throws -> PodcastEpisode {
        guard PodcastRules.validID(id) else { throw PodcastHTTPError(status: 0, message: "Invalid podcast episode.") }
        return try await get(PodcastEpisode.self, config: config, suffix: "/\(id)/prepare", post: true)
    }
}
