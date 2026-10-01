import XCTest
@testable import Hoshi_Reader

nonisolated final class PodcastTranscriptDataTests: XCTestCase {
    private let id = String(repeating: "a", count: 64)
    private let account = String(repeating: "b", count: 64)
    private let other = String(repeating: "c", count: 64)
    private func document(_ episode: String? = nil, lines: [PodcastTranscriptLine]? = nil) -> PodcastTranscript {
        PodcastTranscript(episode: episode ?? id, duration: 20, lines: lines ?? [
            PodcastTranscriptLine(start: 1, end: 3, text: "こんにちは。", english: "Hello."),
            PodcastTranscriptLine(start: 5, end: 9, text: "元気ですか。", english: nil),
        ])
    }
    private func data(_ value: PodcastTranscript) throws -> Data { try PodcastRules.encoder().encode(value) }
    private func episode() -> PodcastEpisode {
        PodcastEpisode(id: id, title: "Original", publishedAt: "2026-09-30", status: "ready", show: "show", transcript: true)
    }

    func testCatalogueFlagsDefaultForOlderServersAndDecodeCurrentContract() throws {
        let old = Data("{\"id\":\"\(id)\",\"title\":\"Old\",\"published_at\":\"2026-09-30\",\"status\":\"ready\"}".utf8)
        let oldEpisode = try PodcastRules.decoder().decode(PodcastEpisode.self, from: old)
        XCTAssertFalse(oldEpisode.transcript); XCTAssertFalse(oldEpisode.uploaded)
        var current = episode(); current.uploaded = true
        let decoded = try PodcastRules.decoder().decode(PodcastEpisode.self, from: PodcastRules.encoder().encode(current))
        XCTAssertTrue(decoded.transcript); XCTAssertTrue(decoded.uploaded)
    }
    func testTranscriptFiltersUnusableLinesAndPreservesTranslationAndTimings() throws {
        let lines = [PodcastTranscriptLine(start: -1, end: 0, text: "bad"),
                     PodcastTranscriptLine(start: 0, end: 1, text: " \n"),
                     PodcastTranscriptLine(start: 1, end: 3, text: "有効", english: "Valid"),
                     PodcastTranscriptLine(start: 5, end: 4, text: "bad")]
        let value = try XCTUnwrap(PodcastTranscript.parse(data: data(document(lines: lines)), episodeID: id))
        XCTAssertEqual(value.lines.count, 1)
        XCTAssertEqual(value.lines[0].english, "Valid")
        XCTAssertEqual(value.lines[0].start, 1)
    }
    func testWrongEpisodeMalformedEmptyUnsupportedOversizedAndBackwardsTranscriptsFailClosed() throws {
        XCTAssertNil(PodcastTranscript.parse(data: try data(document(other)), episodeID: id))
        XCTAssertNil(PodcastTranscript.parse(data: Data("not json".utf8), episodeID: id))
        XCTAssertNil(PodcastTranscript.parse(data: try data(document(lines: [])), episodeID: id))
        var unsupported = document(); unsupported.version = 2
        XCTAssertNil(PodcastTranscript.parse(data: try data(unsupported), episodeID: id))
        var backwards = document(); backwards.lines.reverse()
        XCTAssertNil(PodcastTranscript.parse(data: try data(backwards), episodeID: id))
        var oversized = document(); oversized.lines[0].text = String(repeating: "x", count: PodcastTranscript.maximumBytes)
        XCTAssertNil(PodcastTranscript.parse(data: try data(oversized), episodeID: id))
        var invalid = document(); invalid.lines = [PodcastTranscriptLine(start: .nan, end: 3, text: "bad")]
        XCTAssertNil(invalid.validated(episodeID: id))
    }
    func testCurrentLineKeepsHighlightDuringGapsAndUsesLastRepeatedStart() {
        var transcript = document()
        XCTAssertNil(transcript.line(at: 0))
        XCTAssertEqual(transcript.line(at: 1), 0)
        XCTAssertEqual(transcript.line(at: 4), 0)
        XCTAssertEqual(transcript.line(at: 5), 1)
        XCTAssertEqual(transcript.line(at: 999), 1)
        XCTAssertNil(transcript.line(at: .infinity))
        transcript.lines.insert(PodcastTranscriptLine(start: 5, end: 5, text: "same"), at: 1)
        XCTAssertEqual(transcript.line(at: 5), 2)
    }
    func testBackgroundTaskDescriptionsKeepLessonAndTranscriptIndependentAcrossRetries() throws {
        let lesson = PodcastDownloadReference(account: account, id: id)
        let transcript = PodcastDownloadReference(account: account, id: id, part: .transcript)
        let original = PodcastDownloadReference(account: account, id: id, part: .original, attempt: 2)
        XCTAssertNotEqual(lesson.key, transcript.key)
        XCTAssertEqual(transcript.key, original.key)
        for value in [lesson, transcript, original, PodcastDownloadReference(account: account, id: id, attempt: 1)] {
            XCTAssertEqual(PodcastDownloadReference(value.description), value)
        }
        XCTAssertNil(PodcastDownloadReference(account + "|../outside"))
        XCTAssertNil(PodcastDownloadReference(account + "|" + id + "|original|3"))
        XCTAssertNil(PodcastDownloadReference(account + "|" + id + "|unknown|0"))
        XCTAssertEqual(PodcastDownloadPart.transcript.maximumBytes, 2 * 1024 * 1024)
        XCTAssertEqual(PodcastDownloadPart.original.suffix, "original")
    }
    func testDownloadValidationHandlesDecodedCompressedJSONAndRefusesTruncationOrWrongAudio() throws {
        let url = URL(string: "https://fixture.test/transcript")!
        let plain = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json", "Content-Length": "100"]))
        XCTAssertNoThrow(try PodcastDownloadPart.transcript.validate(response: plain, fileSize: 100))
        XCTAssertThrowsError(try PodcastDownloadPart.transcript.validate(response: plain, fileSize: 90))
        let gzip = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json", "Content-Length": "100", "Content-Encoding": "gzip"]))
        XCTAssertNoThrow(try PodcastDownloadPart.transcript.validate(response: gzip, fileSize: 300))
        XCTAssertThrowsError(try PodcastDownloadPart.transcript.validate(response: gzip, fileSize: Int64(PodcastTranscript.maximumBytes + 1)))
        XCTAssertThrowsError(try PodcastDownloadPart.original.validate(response: plain, fileSize: 100))
        let audio = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "audio/mpeg", "Content-Length": "100"]))
        XCTAssertNoThrow(try PodcastDownloadPart.original.validate(response: audio, fileSize: 100))
        XCTAssertThrowsError(try PodcastDownloadPart.original.validate(response: audio, fileSize: 0))
    }
    @MainActor func testTranscriptPublishesOnlyAfterOriginalAndCheckpointSurvivesRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let files = PodcastFiles(root: root)
        let staged = root.appendingPathComponent("staged.json")
        try data(document()).write(to: staged)
        try files.stageTranscript(staged, account: account, id: id)
        XCTAssertFalse(files.isTranscriptDownloaded(account: account, id: id))
        XCTAssertNil(files.loadTranscript(account: account, id: id))
        let restarted = PodcastFiles(root: root)
        let audio = root.appendingPathComponent("download.mp3")
        try Data([1, 2, 3]).write(to: audio)
        try restarted.installAudio(audio, account: account, id: id, original: true)
        XCTAssertTrue(restarted.isTranscriptDownloaded(account: account, id: id))
        XCTAssertFalse(restarted.isDownloaded(account: account, id: id), "Original audio must not masquerade as the generated lesson.")
        XCTAssertEqual(restarted.loadTranscript(account: account, id: id), document())
        XCTAssertEqual(try Data(contentsOf: restarted.originalAudio(account: account, id: id)!), Data([1, 2, 3]))
        XCTAssertFalse(restarted.isTranscriptDownloaded(account: other, id: id))
    }
    @MainActor func testInvalidTranscriptNeverPublishesAndOriginalCannotCompleteWithoutCheckpoint() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let files = PodcastFiles(root: root)
        let staged = root.appendingPathComponent("bad.json")
        try data(document(other)).write(to: staged)
        XCTAssertThrowsError(try files.stageTranscript(staged, account: account, id: id))
        let original = root.appendingPathComponent("recording.mp3")
        try Data([1]).write(to: original)
        XCTAssertThrowsError(try files.installAudio(original, account: account, id: id, original: true))
        XCTAssertFalse(files.isTranscriptDownloaded(account: account, id: id))
        XCTAssertNil(files.originalAudio(account: "../escape", id: id))
        XCTAssertNil(files.transcript(account: account, id: "../escape"))
    }
    @MainActor func testOriginalOnlyDownloadRetainsArchivedEpisodeAndIndependentPlaybackPositions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = PodcastFiles(root: root)
        try files.remember(episode(), account: account, shows: [PodcastShow(id: "show", name: "Offline show")])
        let staged = root.appendingPathComponent("text.json")
        try data(document()).write(to: staged)
        try files.stageTranscript(staged, account: account, id: id)
        let original = root.appendingPathComponent("audio.mp3")
        try Data([9]).write(to: original)
        try files.installAudio(original, account: account, id: id, original: true)
        _ = try files.save(PodcastCatalogue(), account: account)
        let restarted = PodcastFiles(root: root)
        XCTAssertEqual(restarted.load(account).episodes.map(\.id), [id])
        XCTAssertEqual(restarted.load(account).shows.first?.name, "Offline show")
        files.savePosition(12, account: account, id: id)
        files.savePosition(4, account: account, id: id, original: true)
        XCTAssertEqual(restarted.position(account: account, id: id), 12)
        XCTAssertEqual(restarted.position(account: account, id: id, original: true), 4)
        XCTAssertEqual(restarted.position(account: other, id: id, original: true), 0)
        files.prune(except: other)
        XCTAssertFalse(restarted.isTranscriptDownloaded(account: account, id: id))
    }
    @MainActor func testCorruptCompletedTranscriptAllowsRetryAndAtomicReplacementRefreshesAvailability() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = PodcastFiles(root: root)
        try files.remember(episode(), account: account, shows: [])
        let text = try XCTUnwrap(files.transcript(account: account, id: id))
        try Data([1]).write(to: files.originalAudio(account: account, id: id)!)
        try data(document()).write(to: text, options: .atomic)
        XCTAssertTrue(files.isTranscriptDownloaded(account: account, id: id))
        let oldDate = try text.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        // Preserve length and mtime: the inode changes when a sidecar is atomically replaced.
        let size = try Data(contentsOf: text).count
        try Data(repeating: 32, count: size).write(to: text, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: text.path)
        XCTAssertFalse(files.isTranscriptDownloaded(account: account, id: id))
        XCTAssertNil(files.loadTranscript(account: account, id: id))
        try data(document()).write(to: text, options: .atomic)
        XCTAssertTrue(files.isTranscriptDownloaded(account: account, id: id))
    }
    @MainActor func testStoreKeepsLessonAndTranscriptProgressAndFailuresSeparateAndRejectsOtherAccount() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = PodcastFiles(root: root)
        let config = HttpSyncConfig(baseURL: "https://fixture.test", token: "fixture")
        let current = PodcastRules.account(baseURL: config.baseURL, token: config.token)
        files.validatedAccount = current
        let store = PodcastStore(files: files, configuration: { config })
        store.downloadProgress(account: current, id: id, fraction: 0.4)
        store.downloadProgress(account: current, id: id, fraction: 0.7, transcript: true)
        store.downloadProgress(account: other, id: id, fraction: 1, transcript: true)
        XCTAssertEqual(store.downloads[id], 0.4)
        XCTAssertEqual(store.transcriptDownloads[id], 0.7)
        store.downloadFinished(account: current, id: id, failure: "transcript failure", transcript: true)
        XCTAssertEqual(store.downloads[id], 0.4)
        XCTAssertNil(store.transcriptDownloads[id])
        XCTAssertNil(store.downloadErrors[id])
        XCTAssertEqual(store.transcriptDownloadErrors[id], "transcript failure")
    }
}
