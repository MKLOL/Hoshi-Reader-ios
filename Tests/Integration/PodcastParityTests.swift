import XCTest
@testable import Hoshi_Reader

nonisolated final class PodcastParityTests: XCTestCase {
    private let id = String(repeating: "a", count: 64)
    private let account = String(repeating: "b", count: 64)
    private func episode(duration: Int = 0, status: String = "ready") -> PodcastEpisode {
        PodcastEpisode(id: id, title: "Fixture", publishedAt: "2026-09-24", durationSeconds: duration, status: status, show: "show")
    }
    func testOlderCatalogueWithoutShowsOrLengthsDecodes() throws {
        let data = Data("{\"episodes\":[{\"id\":\"\(id)\",\"title\":\"Fixture\",\"published_at\":\"2026-09-24\",\"status\":\"ready\"}]}".utf8)
        let value = try PodcastRules.decoder().decode(PodcastCatalogue.self, from: data)
        XCTAssertTrue(value.shows.isEmpty)
        XCTAssertEqual(value.episodes.first?.durationSeconds, 0)
        XCTAssertTrue(value.episodes.first!.retryable)
    }
    func testLengthBoundariesAndUnknownLengths() {
        XCTAssertTrue(PodcastLength.short.includes(episode(duration: 600)))
        XCTAssertFalse(PodcastLength.short.includes(episode(duration: 601)))
        XCTAssertTrue(PodcastLength.medium.includes(episode(duration: 1200)))
        XCTAssertTrue(PodcastLength.long.includes(episode(duration: 7200)))
        XCTAssertFalse(PodcastLength.long.includes(episode(duration: 0)))
        XCTAssertTrue(PodcastLength.all.includes(episode(duration: 0)))
    }
    func testGenerationExpiresUsingBothServerAgeAndReceiptAge() {
        let generation = PodcastGeneration(episode: id, stage: "speech", done: 2, total: 4, percent: 50, ageSeconds: 20)
        XCTAssertEqual(generation.progress(for: id, worker: nil, elapsed: 69), 0.5)
        XCTAssertNil(generation.progress(for: id, worker: nil, elapsed: 70))
        XCTAssertNil(generation.progress(for: id, worker: PodcastWorker(alive: false), elapsed: 0))
        XCTAssertNil(generation.progress(for: "other", worker: nil, elapsed: 0))
    }
    func testServerRetryabilityAndTextSanitizing() {
        var episode = episode(status: "failed")
        XCTAssertFalse(episode.needsAdministrator(maxFailures: nil))
        episode.retryable = false
        XCTAssertTrue(episode.needsAdministrator(maxFailures: nil))
        XCTAssertEqual(PodcastRules.display("  one\u{202e}\n\u{3000}two  "), "one two")
        XCTAssertEqual(PodcastRules.display(String(repeating: "x", count: 1000))?.count, 300)
    }
    func testPartialProgressFromOlderServerDoesNotRejectCatalogue() throws {
        let value = try PodcastRules.decoder().decode(PodcastCatalogue.self, from: Data("{\"episodes\":[],\"generating\":{}}".utf8))
        XCTAssertNil(value.generating?.progress(for: id, worker: nil, elapsed: 0))
    }
    func testLocalFailuresNeverDisplayFilesystemPaths() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError, userInfo: [NSFilePathErrorKey: "/private/user/secret/lesson.mp3"])
        XCTAssertEqual(PodcastRules.failureMessage(error), "Could not save the lesson. Check the available storage and try again.")
        XCTAssertEqual(PodcastRules.failureMessage(PodcastHTTPError(status: 503, message: "Worker unavailable")), "Worker unavailable")
    }
    func testCancelledTransfersCannotReplaceRestartedSameAccountTransfer() {
        var epochs = PodcastDownloadEpochs()
        epochs.record(1)
        epochs.retire(accounts: [account])
        epochs.record(2)
        XCTAssertFalse(epochs.accepts(1, account: account, currentTaskID: 2))
        XCTAssertTrue(epochs.accepts(2, account: account, currentTaskID: 2))
        XCTAssertFalse(epochs.isRetired(2, account: account))
        XCTAssertTrue(epochs.isRetired(99, account: account), "An old transfer not yet restored is also cancelled.")
        XCTAssertFalse(epochs.accepts(2, account: account, currentTaskID: nil), "A duplicate completion cannot revive a finished transfer.")
        XCTAssertTrue(PodcastDownloadEpochs().accepts(99, account: account, currentTaskID: nil), "Cold-launch queued completions remain eligible.")
    }
    @MainActor func testColdBackgroundStartupRestoresOnlyTheValidatedCurrentAccount() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = PodcastFiles(root: root)
        let config = HttpSyncConfig(baseURL: "https://fixture.test", token: "fixture")
        let current = PodcastRules.account(baseURL: config.baseURL, token: config.token)
        files.validatedAccount = current
        _ = try files.save(PodcastCatalogue(episodes: [episode()]), account: current)
        let restored = PodcastStore(files: files, configuration: { config })
        XCTAssertTrue(restored.enabled, "Background delegate delivery cannot depend on a SwiftUI scene task.")
        XCTAssertEqual(restored.account, current)
        XCTAssertEqual(restored.catalogue.episodes.map(\.id), [id])
        let edited = PodcastStore(files: files, configuration: { HttpSyncConfig(baseURL: config.baseURL, token: "edited") })
        XCTAssertFalse(edited.enabled)
        XCTAssertTrue(edited.catalogue.episodes.isEmpty)
        XCTAssertEqual(files.validatedAccount, current, "An unvalidated edit must not remove the old account's marker or files.")
    }
    @MainActor func testHiddenScreenRejectsLateCatalogueTelemetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = PodcastFiles(root: root)
        let config = HttpSyncConfig(baseURL: "https://fixture.test", token: "fixture")
        files.validatedAccount = PodcastRules.account(baseURL: config.baseURL, token: config.token)
        let api = SuspendedPodcastAPI()
        let store = PodcastStore(files: files, api: api, configuration: { config })
        store.setVisible(true)
        let refresh = Task { await store.refresh() }
        await api.waitUntilRequested()
        store.setVisible(false)
        await api.complete(PodcastCatalogue(episodes: [episode()], worker: PodcastWorker(alive: true), generating: PodcastGeneration(episode: id, stage: "speech", done: 1, total: 2, percent: 50)))
        await refresh.value
        XCTAssertNil(store.catalogue.worker)
        XCTAssertNil(store.catalogue.generating)
        XCTAssertNil(store.receivedUptime)
        XCTAssertFalse(store.loading)
    }
    @MainActor func testLongFormAudioHandoffPreservesNewOwner() {
        let coordinator = LongFormAudioCoordinator()
        let first = UUID(), second = UUID()
        var firstPaused = false
        coordinator.begin(owner: first) { firstPaused = true; coordinator.end(owner: first) }
        coordinator.begin(owner: second) { }
        XCTAssertTrue(firstPaused)
        XCTAssertTrue(coordinator.isActive)
        XCTAssertTrue(LongFormAudioCoordinator.isAudioActive)
        coordinator.end(owner: first)
        XCTAssertTrue(coordinator.isActive)
        coordinator.end(owner: second)
        XCTAssertFalse(coordinator.isActive)
        XCTAssertFalse(LongFormAudioCoordinator.isAudioActive)
    }
    func testRequestsUseBearerHeadersAndRejectCredentialURLs() throws {
        let request = try PodcastAPI.request(config: HttpSyncConfig(baseURL: "https://example.test/api/book_sync", token: "secret"), suffix: "/access")
        XCTAssertEqual(request.url?.absoluteString, "https://example.test/api/book_sync/v1/podcasts/access")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertThrowsError(try PodcastAPI.request(config: HttpSyncConfig(baseURL: "https://user:password@example.test/api", token: "secret"), suffix: ""))
        XCTAssertThrowsError(try PodcastAPI.request(config: HttpSyncConfig(baseURL: "https://example.test/api?token=bad", token: "secret"), suffix: ""))
    }
    @MainActor func testDownloadedLessonsAndShowNamesSurviveArchivedFeedAndRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = PodcastFiles(root: root)
        let show = PodcastShow(id: "show", name: "Saved show")
        let old = PodcastCatalogue(episodes: [episode()], shows: [show], worker: PodcastWorker(alive: true), generating: PodcastGeneration(episode: id, stage: "speech", done: 1, total: 2, percent: 50))
        _ = try files.save(old, account: account)
        try files.remember(episode(), account: account, shows: [show])
        try Data([1, 2, 3]).write(to: files.audio(account: account, id: id)!)
        let updated = try files.save(PodcastCatalogue(), account: account)
        XCTAssertEqual(updated.episodes.map(\.id), [id])
        let restarted = PodcastFiles(root: root).load(account)
        XCTAssertEqual(restarted.shows.first?.name, "Saved show")
        XCTAssertNil(restarted.worker); XCTAssertNil(restarted.generating)
        XCTAssertEqual(restarted.episodes.count, 1)
        XCTAssertNil(files.audio(account: "../escape", id: id))
        files.validatedAccount = account
        XCTAssertEqual(files.validatedAccount, account)
        files.validatedAccount = nil
        XCTAssertTrue(files.isDownloaded(account: account, id: id))
    }
    @MainActor func testDownloadCompletingAfterArchiveKeepsMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = PodcastFiles(root: root)
        try files.remember(episode(), account: account, shows: [PodcastShow(id: "show", name: "Saved")])
        _ = try files.save(PodcastCatalogue(), account: account)
        try Data([1]).write(to: files.audio(account: account, id: id)!)
        XCTAssertEqual(files.load(account).episodes.first?.id, id)
    }
}

private actor SuspendedPodcastAPI: PodcastServing {
    private var requested = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var response: CheckedContinuation<PodcastCatalogue, Never>?
    func access(config: HttpSyncConfig) async throws -> Bool { true }
    func prepare(config: HttpSyncConfig, id: String) async throws -> PodcastEpisode { throw URLError(.unsupportedURL) }
    func catalogue(config: HttpSyncConfig) async throws -> PodcastCatalogue {
        requested = true
        for waiter in waiters { waiter.resume() }; waiters = []
        return await withCheckedContinuation { response = $0 }
    }
    func waitUntilRequested() async {
        if requested { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func complete(_ value: PodcastCatalogue) { response?.resume(returning: value); response = nil }
}
