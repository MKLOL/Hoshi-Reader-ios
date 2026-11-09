import XCTest
import CHoshiDicts
import CxxStdlib
@testable import Hoshi_Reader

nonisolated final class FirstLaunchSetupTests: XCTestCase {
    func testNewReturningAndRestoredInstallSeeds() {
        XCTAssertEqual(FirstLaunchState.seed(fresh: true, restored: false, hasToken: false, hasTermDictionary: false),
                       .init(tokenCompleted: false, dictionariesCompleted: false))
        XCTAssertEqual(FirstLaunchState.seed(fresh: false, restored: false, hasToken: false, hasTermDictionary: false),
                       .init(tokenCompleted: true, dictionariesCompleted: true))
        XCTAssertEqual(FirstLaunchState.seed(fresh: false, restored: true, hasToken: false, hasTermDictionary: true),
                       .init(tokenCompleted: false, dictionariesCompleted: true))
        XCTAssertEqual(FirstLaunchState.seed(fresh: false, restored: true, hasToken: true, hasTermDictionary: false),
                       .init(tokenCompleted: true, dictionariesCompleted: false))
    }

    @MainActor func testSkippingBothStepsSurvivesRelaunch() throws {
        try withSetup { defaults, directory in
            @MainActor func launch() -> FirstLaunchSetup {
                FirstLaunchSetup(defaults: defaults, directory: directory, priorUse: false,
                    hasToken: { false }, hasTermDictionary: { false }, saveToken: { _ in XCTFail("No token requested"); return false },
                    startSync: { XCTFail("No sync requested") }, install: { _ in XCTFail("No download requested") })
            }
            let setup = launch()
            XCTAssertEqual(setup.step, .token)
            setup.withoutToken()
            XCTAssertEqual(setup.step, .later)
            setup.finishLater()
            XCTAssertEqual(setup.step, .dictionaries)
            setup.skipDictionaries()
            XCTAssertEqual(setup.step, .hidden)
            XCTAssertEqual(launch().step, .hidden)
        }
    }

    @MainActor func testTokenIsSavedBeforeSyncAndDictionaryRetryStaysInSetup() throws {
        try withSetup { defaults, directory in
            var saved = ""
            var syncs = 0
            var completion: (@MainActor (Bool) -> Void)?
            let setup = FirstLaunchSetup(defaults: defaults, directory: directory, priorUse: false,
                hasToken: { !saved.isEmpty }, hasTermDictionary: { false }, saveToken: { saved = $0; return true },
                startSync: { XCTAssertEqual(saved, "token"); syncs += 1 }, install: { completion = $0 })
            setup.useToken("  token\n")
            XCTAssertEqual(syncs, 1)
            XCTAssertEqual(setup.step, .dictionaries)
            setup.downloadDictionaries()
            XCTAssertTrue(setup.installing)
            setup.skipDictionaries()
            XCTAssertEqual(setup.step, .dictionaries)
            completion?(false)
            XCTAssertTrue(setup.installFailed)
            setup.downloadDictionaries()
            completion?(true)
            XCTAssertEqual(setup.step, .status)
            setup.dismissStatus()
            XCTAssertEqual(setup.step, .hidden)
            let relaunched = FirstLaunchSetup(defaults: defaults, directory: directory, priorUse: false,
                hasToken: { true }, hasTermDictionary: { true }, startSync: { XCTFail("Must not sync again") })
            XCTAssertEqual(relaunched.step, .hidden)
        }
    }

    @MainActor func testFailedCredentialSaveDoesNotCompleteOrStartSync() throws {
        try withSetup { defaults, directory in
            let setup = FirstLaunchSetup(defaults: defaults, directory: directory, priorUse: false,
                hasToken: { false }, hasTermDictionary: { false }, saveToken: { _ in false },
                startSync: { XCTFail("Credentials were not saved") })
            setup.useToken("token")
            XCTAssertEqual(setup.step, .token)
            XCTAssertTrue(setup.saveFailed)
        }
    }

    @MainActor func testRestoredInstallOffersOnlyMissingSteps() throws {
        try withSetup { defaults, directory in
            let first = FirstLaunchSetup(defaults: defaults, directory: directory, priorUse: true,
                hasToken: { false }, hasTermDictionary: { false })
            XCTAssertEqual(first.step, .hidden)
            try FileManager.default.removeItem(at: directory)
            let restored = FirstLaunchSetup(defaults: defaults, directory: directory, priorUse: true,
                hasToken: { false }, hasTermDictionary: { true })
            XCTAssertEqual(restored.step, .token)
            restored.withoutToken()
            restored.finishLater()
            XCTAssertEqual(restored.step, .hidden)
        }
    }

    @MainActor private func withSetup(_ test: @MainActor (UserDefaults, URL) throws -> Void) throws {
        let suite = "FirstLaunchSetupTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        try test(defaults, directory)
    }
}

nonisolated final class DictionaryDownloadTests: XCTestCase {
    func testGitHubArchiveTimeoutFallsBackToOfficialAssetAPIAndCleansErrorFiles() async throws {
        let stub = DictionaryDownloadStub([
            .init(status: 504, body: Data("Gateway timeout".utf8)),
            .init(status: 504, body: Data("Gateway timeout".utf8)),
            .init(status: 200, body: Data(#"{"assets":[{"name":"dictionary.zip","url":"https://api.github.com/repos/example/dictionary/releases/assets/42"}]}"#.utf8)),
            .init(status: 200, body: Self.fixtureArchive)
        ])
        let source = URL(string: "https://github.com/example/dictionary/releases/latest/download/dictionary.zip")!
        let file = try await DictionaryDownloads.archive(from: source, resolveFallback: { url in
            try await DictionaryDownloads.githubReleaseAsset(for: url, load: { try await stub.data($0) })
        }, load: { try await stub.download($0) })
        defer { try? FileManager.default.removeItem(at: file) }
        let requests = await stub.requests, files = await stub.files
        XCTAssertEqual(requests.count, 4, "One browser retry, one metadata request, one API asset request")
        XCTAssertEqual(requests[2].url?.absoluteString, "https://api.github.com/repos/example/dictionary/releases/latest")
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(requests[3].url?.absoluteString, "https://api.github.com/repos/example/dictionary/releases/assets/42")
        XCTAssertEqual(requests[3].value(forHTTPHeaderField: "Accept"), "application/octet-stream")
        XCTAssertFalse(FileManager.default.fileExists(atPath: files[0].path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: files[1].path))
        XCTAssertEqual(try Data(contentsOf: file), Self.fixtureArchive)
    }

    func testGitHubIndexFallbackUsesTaggedReleaseAndDecodesDictionaryMetadata() async throws {
        let index = Data(#"{"title":"Starter","format":3,"revision":"1","isUpdatable":false,"indexUrl":"","downloadUrl":""}"#.utf8)
        let stub = DictionaryDownloadStub([
            .init(status: 404, body: Data()),
            .init(status: 200, body: Data(#"{"assets":[{"name":"dictionary.json","url":"https://api.github.com/repos/example/dictionary/releases/assets/43"}]}"#.utf8)),
            .init(status: 200, body: index)
        ])
        let source = URL(string: "https://github.com/example/dictionary/releases/download/v1/dictionary.json")!
        let data = try await DictionaryDownloads.fetch(from: source, resolveFallback: { url in
            try await DictionaryDownloads.githubReleaseAsset(for: url, load: { try await stub.data($0) })
        }, load: { try await stub.data($0) })
        XCTAssertEqual(try JSONDecoder().decode(DictionaryIndex.self, from: data).title, "Starter")
        let requests = await stub.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[1].url?.path, "/repos/example/dictionary/releases/tags/v1")
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "Accept"), "application/octet-stream")
    }

    func testGitHubFallbackDoesNotRewriteUnrecognizedOrUnrelatedURLs() async throws {
        let stub = DictionaryDownloadStub([])
        for source in ["https://example.test/owner/repo/releases/latest/download/index.json",
                       "https://github.com/owner/repo/blob/main/index.json",
                       "https://github.com/owner/repo/issues/1",
                       "http://github.com/owner/repo/releases/latest/download/index.json"] {
            let result = try await DictionaryDownloads.githubReleaseAsset(for: URL(string: source)!, load: { try await stub.data($0) })
            XCTAssertNil(result)
        }
        let requests = await stub.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testExpiredReleaseRedirectRetriesWithoutCacheAndCleansUpErrorPage() async throws {
        let stub = DictionaryDownloadStub([
            .init(status: 618, body: Data("jwt:expired".utf8)),
            .init(status: 200, body: Self.fixtureArchive)
        ])
        let source = URL(string: "https://github.com/example/dictionary/releases/latest/download/dict.zip")!
        let file = try await DictionaryDownloads.archive(from: source, load: { try await stub.download($0) })
        defer { try? FileManager.default.removeItem(at: file) }
        let requests = await stub.requests, files = await stub.files
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].cachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
        XCTAssertEqual(requests[1].cachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
        XCTAssertNotNil(URLComponents(url: try XCTUnwrap(requests[1].url), resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "hoshi_retry" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: files[0].path))
        XCTAssertEqual(try Data(contentsOf: file), Self.fixtureArchive)
    }

    func testHTTPErrorDoesNotReachImporterOrLeaveATemporaryFile() async throws {
        let stub = DictionaryDownloadStub([.init(status: 404, body: Data("Not found".utf8))])
        do {
            _ = try await DictionaryDownloads.archive(from: Self.source, load: { try await stub.download($0) })
            XCTFail("An HTTP error page must never reach the native importer")
        } catch DictionaryDownloadError.httpStatus(let status) { XCTAssertEqual(status, 404) }
        let requests = await stub.requests, files = await stub.files
        XCTAssertEqual(requests.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(files.first).path))
    }

    func testHTMLSuccessResponseDoesNotReachImporterOrLeaveATemporaryFile() async throws {
        let stub = DictionaryDownloadStub([.init(status: 200, body: Data("<!doctype html>Unavailable".utf8))])
        do {
            _ = try await DictionaryDownloads.archive(from: Self.source, load: { try await stub.download($0) })
            XCTFail("An HTML page must never reach the native importer")
        } catch DictionaryDownloadError.invalidArchive { }
        let files = await stub.files
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(files.first).path))
    }

    func testDownloadedTemporaryFileImportsWithNativeBackendAndSupportsLookup() async throws {
        let stub = DictionaryDownloadStub([.init(status: 200, body: Self.fixtureArchive)])
        let file = try await DictionaryDownloads.archive(from: Self.source, load: { try await stub.download($0) })
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: destination)
        }
        XCTAssertEqual(file.pathExtension, "tmp", "URLSession temporary files have no .zip extension")
        let title = try DictionaryDownloads.importArchive(at: file, to: destination)
        XCTAssertEqual(title, "Starter fixture")
        let installed = destination.appendingPathComponent(title)
        XCTAssertTrue(DictionaryDownloads.isImportedDictionary(at: installed))
        let index = try JSONDecoder().decode(DictionaryIndex.self, from: Data(contentsOf: installed.appendingPathComponent("index.json")))
        XCTAssertEqual(index.title, title)
        var query = DictionaryQuery()
        query.add_term_dict(std.string(installed.path(percentEncoded: false)))
        XCTAssertFalse(Array(query.query(std.string("猫"))).isEmpty)
    }

    func testInterruptedImportIsNotMistakenForAnInstalledDictionary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{\"title\":\"Interrupted\",\"format\":3,\"revision\":\"1\"}".utf8).write(to: root.appendingPathComponent("index.json"))
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("blobs.bin"))
        XCTAssertFalse(DictionaryDownloads.isImportedDictionary(at: root), "Index metadata is written before import finishes")
        try Data().write(to: root.appendingPathComponent(".hoshidicts_1"))
        XCTAssertFalse(DictionaryDownloads.isImportedDictionary(at: root), "Missing native indexes are not usable")
    }

    func testNativeUpdatePublishesCompletedDictionaryAndPreservesOldFilesOnFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("dictionary.tmp")
        try Self.fixtureArchive.write(to: archive)
        let directory = root.appendingPathComponent("dictionaries")
        let title = try DictionaryDownloads.importArchive(at: archive, to: directory)
        let installed = directory.appendingPathComponent(title)
        let oldIndex = try Data(contentsOf: installed.appendingPathComponent("index.json"))
        let oldBlobs = try Data(contentsOf: installed.appendingPathComponent("blobs.bin"))
        // Same title, but no banks: native import writes index metadata and then fails.
        try Data(base64Encoded: "UEsDBBQAAAAIAGwHaV2VCZOkWQAAAGgAAAAKAAAAaW5kZXguanNvbi3LQQqAMAxE0atI1q5012tIDxBpCoHaSBq1IN7dCG7/vLnB2ApBgMVQjXTI3O1QghGy6IYGYR5B6eTGUt1NvnCLe0LD9XtmLI281UQ9anHiIslVi2D6w/MCUEsBAhQDFAAAAAgAbAdpXZUJk6RZAAAAaAAAAAoAAAAAAAAAAAAAAIABAAAAAGluZGV4Lmpzb25QSwUGAAAAAAEAAQA4AAAAgQAAAAAA")!.write(to: archive)
        XCTAssertThrowsError(try DictionaryDownloads.importArchive(at: archive, to: directory))
        XCTAssertTrue(DictionaryDownloads.isImportedDictionary(at: installed))
        XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent("index.json")), oldIndex)
        XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent("blobs.bin")), oldBlobs)

        // Replacing a complete same-title dictionary must also succeed on the native filesystem.
        try Self.fixtureArchive.write(to: archive)
        XCTAssertEqual(try DictionaryDownloads.importArchive(at: archive, to: directory), title)
        XCTAssertTrue(DictionaryDownloads.isImportedDictionary(at: installed))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [title])
        var query = DictionaryQuery()
        query.add_term_dict(std.string(installed.path(percentEncoded: false)))
        XCTAssertFalse(Array(query.query(std.string("猫"))).isEmpty)
    }

    func testNativeImportFailurePreservesItsDiagnostic() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("invalid.tmp")
        try Data("Invalid archive".utf8).write(to: file)
        XCTAssertThrowsError(try DictionaryDownloads.importArchive(at: file, to: root.appendingPathComponent("output"))) { error in
            XCTAssertTrue(error.localizedDescription.contains("failed to open zip"), error.localizedDescription)
        }
    }

    private static let source = URL(string: "https://example.test/dictionary.zip")!
    // A generated Yomitan fixture containing one term (猫 → cat), not third-party dictionary data.
    private static let fixtureArchive = Data(base64Encoded: "UEsDBBQAAAAIAJ0GaV1P832mWQAAAGgAAAAKAAAAaW5kZXguanNvbi3LQQqAMAxE0atI1m7EXa8hPUCkKQRqI2nUgnh3I7j98+YGYysEARZDNdIhc7dDCUbIohsahHkEpZMbS3U3+cIt7gkN1++ZsTTyVhP1qMWJiyRXLYLpD88LUEsDBBQAAAAIAJ0GaV0ddlWSIwAAACcAAAAQAAAAdGVybV9iYW5rXzEuanNvbouOVnres1pJR+lx49rHjZOBDDAy0IlWSk4sUYrVMQRyY2MBUEsBAhQDFAAAAAgAnQZpXU/zfaZZAAAAaAAAAAoAAAAAAAAAAAAAAIABAAAAAGluZGV4Lmpzb25QSwECFAMUAAAACACdBmldHXZVkiMAAAAnAAAAEAAAAAAAAAAAAAAAgAGBAAAAdGVybV9iYW5rXzEuanNvblBLBQYAAAAAAgACAHYAAADSAAAAAAA=")!
}

/// Explicitly enabled on a disposable simulator; ordinary unit tests never require the internet.
nonisolated final class DefaultDictionaryLiveTests: XCTestCase {
    @MainActor func testPublicManagerRecoversInterruptedDefaultInstallationAndCompletesUsableSetup() async throws {
        guard ProcessInfo.processInfo.environment["HOSHI_TEST_LIVE_DICTIONARIES"] == "1" else {
            throw XCTSkip("Set HOSHI_TEST_LIVE_DICTIONARIES=1 on a disposable simulator to verify public setup")
        }
        let manager = DictionaryManager.shared
        guard !manager.isImporting, !manager.isUpdating, manager.termDictionaries.isEmpty,
              manager.frequencyDictionaries.isEmpty, manager.pitchDictionaries.isEmpty else {
            throw XCTSkip("Public setup verification requires an empty disposable simulator dictionary library")
        }
        let root = try BookStorage.getAppDirectory().appendingPathComponent("Dictionaries")
        let config = root.appendingPathComponent("config.json")
        let previousConfig = try? Data(contentsOf: config)
        defer {
            if !manager.isImporting {
                for index in manager.termDictionaries.indices.reversed() {
                    manager.deleteDictionary(indexSet: IndexSet(integer: index), type: .term)
                }
                for index in manager.frequencyDictionaries.indices.reversed() {
                    manager.deleteDictionary(indexSet: IndexSet(integer: index), type: .frequency)
                }
                if let previousConfig { try? previousConfig.write(to: config, options: .atomic) }
                else if FileManager.default.fileExists(atPath: config.path) { try? FileManager.default.removeItem(at: config) }
                manager.loadDictionaries()
                manager.rebuildLookupQuery()
            }
        }

        var stage = "fetching JMdict index before interrupted-install fixture"
        do {
        let index = try await DictionaryDownloads.index(from: URL(string: "https://github.com/yomidevs/jmdict-yomitan/releases/latest/download/JMdict_english.json")!)
        stage = "seeding interrupted-install fixture"
        let interrupted = root.appendingPathComponent("Term").appendingPathComponent(index.title)
        try FileManager.default.createDirectory(at: interrupted, withIntermediateDirectories: true)
        try JSONEncoder().encode(index).write(to: interrupted.appendingPathComponent("index.json"))
        manager.loadDictionaries()
        XCTAssertTrue(manager.termDictionaries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: interrupted.path), "Interrupted native output must not suppress a retry")

        let completed = expectation(description: "Recommended dictionaries installed")
        completed.assertForOverFulfill = true
        var succeeded = false
        stage = "public recommended dictionary install"
        manager.importRecommendedDictionaries { success in succeeded = success; completed.fulfill() }
        await fulfillment(of: [completed], timeout: 300)
        XCTAssertFalse(manager.isImporting)
        guard !manager.isImporting else { return }
        XCTAssertTrue(succeeded, manager.errorMessage)
        XCTAssertEqual(manager.termDictionaries.count, 1)
        XCTAssertEqual(manager.frequencyDictionaries.count, 1)
        let results = LookupEngine.shared.lookup("猫")
        XCTAssertTrue(results.contains { !Array($0.term.glossaries).isEmpty }, "Public setup must rebuild the usable shared query")
        XCTAssertTrue(results.contains { !Array($0.term.frequencies).isEmpty }, "Public setup must include frequency data")

        let paths = manager.termDictionaries.map(\.path) + manager.frequencyDictionaries.map(\.path)
        let retried = expectation(description: "Recommended dictionary retry completed")
        stage = "public recommended dictionary retry"
        manager.importRecommendedDictionaries { success in XCTAssertTrue(success, manager.errorMessage); retried.fulfill() }
        await fulfillment(of: [retried], timeout: 300)
        XCTAssertEqual(manager.termDictionaries.map(\.path) + manager.frequencyDictionaries.map(\.path), paths)
        } catch {
            Self.report(error, stage: stage)
        }
    }

    func testPublishedDefaultDictionariesDownloadImportAndLookup() async throws {
        guard ProcessInfo.processInfo.environment["HOSHI_TEST_LIVE_DICTIONARIES"] == "1" else {
            throw XCTSkip("Set HOSHI_TEST_LIVE_DICTIONARIES=1 on a disposable simulator to verify published dictionaries")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DictionaryLive.\(UUID())")
        defer {
            if FileManager.default.fileExists(atPath: root.path) { try? FileManager.default.removeItem(at: root) }
        }
        var installed: [(String, URL)] = []
        var stage = "starting published dictionary install"
        do {
        for (name, source) in [
            ("JMdict", "https://github.com/yomidevs/jmdict-yomitan/releases/latest/download/JMdict_english.json"),
            ("Jiten", "https://api.jiten.moe/api/frequency-list/index")
        ] {
            stage = "fetching \(name) index"
            let index = try await DictionaryDownloads.index(from: URL(string: source)!)
            stage = "downloading \(name) archive"
            let file = try await DictionaryDownloads.archive(from: try XCTUnwrap(URL(string: index.downloadUrl)))
            defer {
                if FileManager.default.fileExists(atPath: file.path) { try? FileManager.default.removeItem(at: file) }
            }
            let directory = root.appendingPathComponent(name)
            stage = "importing \(name) archive"
            let title = try DictionaryDownloads.importArchive(at: file, to: directory)
            XCTAssertEqual(title, index.title)
            installed.append((name, directory.appendingPathComponent(title)))
        }
        var query = DictionaryQuery()
        query.add_term_dict(std.string(try XCTUnwrap(installed.first { $0.0 == "JMdict" }).1.path(percentEncoded: false)))
        query.add_freq_dict(std.string(try XCTUnwrap(installed.first { $0.0 == "Jiten" }).1.path(percentEncoded: false)))
        let results = Array(query.query(std.string("猫")))
        XCTAssertTrue(results.contains { !Array($0.glossaries).isEmpty }, "JMdict must provide definitions for a real word")
        XCTAssertTrue(results.contains { !Array($0.frequencies).isEmpty }, "Jiten must provide frequency data for a real word")
        } catch {
            Self.report(error, stage: stage)
        }
    }

    private static func report(_ error: Error, stage: String, file: StaticString = #filePath, line: UInt = #line) {
        let cocoa = error as NSError
        var detail = "\(type(of: error)) \(cocoa.domain) code \(cocoa.code): \(cocoa.localizedDescription)"
        switch error {
        case DecodingError.keyNotFound(let key, _): detail += " Missing key: \(key.stringValue)."
        case DecodingError.typeMismatch(let type, let context):
            detail += " Expected \(type) at \(context.codingPath.map(\.stringValue).joined(separator: "."))."
        case DecodingError.dataCorrupted(let context): detail += " \(context.debugDescription)"
        default: break
        }
        // Exclude NSError.userInfo: URLSession may put expiring signed release URLs there.
        let message = "Dictionary live failure while \(stage): \(detail)"
        print(message)
        XCTFail(message, file: file, line: line)
    }
}

private actor DictionaryDownloadStub {
    struct Reply: Sendable { let status: Int; let body: Data }
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []
    private(set) var files: [URL] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func data(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.badServerResponse) }
        let reply = replies.removeFirst()
        return (reply.body, HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
    func download(_ request: URLRequest) throws -> (URL, URLResponse) {
        let (body, response) = try data(request)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("CFNetworkDownload_\(UUID()).tmp")
        try body.write(to: file)
        files.append(file)
        return (file, response)
    }
}
