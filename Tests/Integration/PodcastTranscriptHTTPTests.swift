import XCTest
@testable import Hoshi_Reader

/// Real authenticated HTTP and the production background URLSession delegate chain.
nonisolated final class PodcastTranscriptHTTPTests: XCTestCase {
    @MainActor func testTranscriptChainRejectsInvalidTextBeforeAudioAndPublishesBothDownloads() async throws {
        let env = ProcessInfo.processInfo.environment
        let base = try XCTUnwrap(env["HOSHI_KV_BASE_URL"])
        let token = try XCTUnwrap(env["HOSHI_KV_TOKEN"])
        let settings = HttpSyncSettingsStore.shared
        let previousBase = settings.baseURL, previousToken = settings.token
        settings.baseURL = base; settings.token = token
        let store = PodcastStore.shared
        let account = PodcastRules.account(baseURL: base, token: token)
        let monitor = Task { await store.monitorAccess() }
        defer {
            monitor.cancel(); store.invalidate()
            try? FileManager.default.removeItem(at: store.files.root.appendingPathComponent(account))
            settings.baseURL = previousBase; settings.token = previousToken
        }
        try await wait { store.enabled }
        let client = HttpSyncKvClient(baseURL: base, bearerToken: token)
        let good = String(repeating: "c", count: 64), bad = String(repeating: "d", count: 64)
        let transcript = PodcastTranscript(episode: good, duration: 60, lines: [.init(start: 1, end: 5, text: "本を読みます。", english: "I read books.")])
        let text = try PodcastRules.encoder().encode(transcript)
        for id in [good, bad] {
            _ = try await client.put(key: "podcasts/\(id)/transcript", contentType: "application/json", body: text)
            _ = try await client.put(key: "podcasts/\(id)/original", contentType: "audio/mpeg", body: Data(repeating: 7, count: 32_768))
        }
        _ = try await client.put(key: "podcasts/\(good)/audio", contentType: "audio/mpeg", body: Data(repeating: 9, count: 16_384))
        func episode(_ id: String) -> PodcastEpisode {
            PodcastEpisode(id: id, title: "Transcript fixture", publishedAt: "2026-10-01", status: "ready", transcript: true)
        }
        store.downloadTranscript(episode(bad))
        try await wait { store.transcriptDownloadErrors[bad] != nil }
        XCTAssertFalse(store.isTranscriptDownloaded(bad))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.files.originalAudio(account: account, id: bad)!.path))

        store.downloadTranscript(episode(good))
        store.download(episode(good))
        try await wait {
            store.isTranscriptDownloaded(good) && store.isDownloaded(good)
                || store.transcriptDownloadErrors[good] != nil || store.downloadErrors[good] != nil
        }
        XCTAssertNil(store.transcriptDownloadErrors[good]); XCTAssertNil(store.downloadErrors[good])
        XCTAssertEqual(store.transcript(good), transcript)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.files.originalAudio(account: account, id: good))), Data(repeating: 7, count: 32_768))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.files.audio(account: account, id: good))), Data(repeating: 9, count: 16_384))
        XCTAssertNil(store.transcriptDownloads[good]); XCTAssertNil(store.downloads[good])
        var request = URLRequest(url: URL(string: base + "/_test/requests")!)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let data = try await URLSession.shared.data(for: request).0
        let log = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let requests = try XCTUnwrap(log["requests"] as? [[String: Any]])
        let paths = requests.filter { $0["method"] as? String == "GET" }.compactMap { $0["path"] as? String }
        XCTAssertFalse(paths.contains("/v1/podcasts/\(bad)/original"), "Invalid transcript must never trigger original audio.")
        let transcriptIndex = try XCTUnwrap(paths.firstIndex(of: "/v1/podcasts/\(good)/transcript"))
        let originalIndex = try XCTUnwrap(paths.firstIndex(of: "/v1/podcasts/\(good)/original"))
        XCTAssertLessThan(transcriptIndex, originalIndex)
    }

    @MainActor private func wait(_ ready: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(60)
        while !ready(), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(ready(), "Background download did not reach its expected terminal state.")
        if !ready() { throw URLError(.timedOut) }
    }
}
