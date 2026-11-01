import XCTest
@testable import Hoshi_Reader

nonisolated final class AnonymousStatsTests: XCTestCase {
    @MainActor func testFirstReportWaitsAndSentReportsShareOneRandomIdentity() async throws {
        try await withReporter { defaults, directory in
            var now = Date(timeIntervalSince1970: 1_000_000)
            var reports: [[String: Any]] = []
            let reporter = AnonymousStatsReporter(defaults: defaults, directory: directory, now: { now }, automated: { false },
                collect: { AnonymousStatsPayload(installId: $0, epubCount: 2) },
                post: { reports.append(try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any])); return 204 })
            expect(await reporter.reportIfDue(), .notDue)
            XCTAssertNil(reporter.readState()?.installId)
            now += AnonymousStatsReporter.sendInterval - 1
            expect(await reporter.reportIfDue(), .notDue)
            now += 1
            expect(await reporter.reportIfDue(), .sent)
            expect(await reporter.reportIfDue(), .notDue)
            now += AnonymousStatsReporter.sendInterval
            expect(await reporter.reportIfDue(), .sent)
            XCTAssertEqual(reports.count, 2)
            XCTAssertEqual(reports[0]["platform"] as? String, "ios")
            XCTAssertEqual(reports[0]["installId"] as? String, reports[1]["installId"] as? String)
            XCTAssertEqual(Set(reports[0].keys), ["installId", "platform", "epubCount"])
            XCTAssertTrue(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        }
    }

    @MainActor func testOptOutDeletesIdentityAndOptInStartsWithAnotherDelay() async throws {
        try await withReporter { defaults, directory in
            var now = Date(timeIntervalSince1970: 1_000_000)
            var sends = 0
            let reporter = AnonymousStatsReporter(defaults: defaults, directory: directory, now: { now }, automated: { false },
                collect: { AnonymousStatsPayload(installId: $0) }, post: { _ in sends += 1; return 200 })
            _ = await reporter.reportIfDue()
            now += AnonymousStatsReporter.sendInterval
            _ = await reporter.reportIfDue()
            let firstID = try XCTUnwrap(reporter.readState()?.installId)
            reporter.setEnabled(false)
            XCTAssertNil(reporter.readState())
            expect(await reporter.reportIfDue(), .disabled)
            reporter.setEnabled(true)
            expect(await reporter.reportIfDue(), .notDue)
            now += AnonymousStatsReporter.sendInterval
            expect(await reporter.reportIfDue(), .sent)
            XCTAssertNotEqual(reporter.readState()?.installId, firstID)
            XCTAssertEqual(sends, 2)
        }
    }

    @MainActor func testRetryBackoffAndPermanentRejection() async throws {
        try await withReporter { defaults, directory in
            var now = Date(timeIntervalSince1970: 1_000_000)
            var response = 503
            let reporter = AnonymousStatsReporter(defaults: defaults, directory: directory, now: { now }, automated: { false },
                collect: { AnonymousStatsPayload(installId: $0) }, post: { _ in response })
            _ = await reporter.reportIfDue()
            now += AnonymousStatsReporter.sendInterval
            expect(await reporter.reportIfDue(), .failed)
            now += AnonymousStatsReporter.retryInterval - 1
            expect(await reporter.reportIfDue(), .notDue)
            now += 1
            response = 400
            expect(await reporter.reportIfDue(), .rejected)
            now += AnonymousStatsReporter.retryInterval
            expect(await reporter.reportIfDue(), .notDue)
        }
    }

    @MainActor func testAutomationNeverCreatesAStateOrSends() async throws {
        try await withReporter { defaults, directory in
            let reporter = AnonymousStatsReporter(defaults: defaults, directory: directory, automated: { true },
                collect: { _ in XCTFail("Must not collect"); return AnonymousStatsPayload(installId: "") },
                post: { _ in XCTFail("Must not report"); return 200 })
            expect(await reporter.reportIfDue(), .automatedRun)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
    }

    @MainActor private func expect(_ outcome: AnonymousStatsReporter.Outcome, _ expected: AnonymousStatsReporter.Outcome,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(outcome, expected, file: file, line: line)
    }

    @MainActor private func withReporter(_ test: @MainActor (UserDefaults, URL) async throws -> Void) async throws {
        let suite = "AnonymousStatsTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        try await test(defaults, directory)
    }
}
