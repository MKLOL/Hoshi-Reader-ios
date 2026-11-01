import XCTest
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
