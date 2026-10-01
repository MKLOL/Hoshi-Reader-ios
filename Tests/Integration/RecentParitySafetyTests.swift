import XCTest
@testable import Hoshi_Reader

nonisolated final class RecentParitySafetyTests: XCTestCase {
    func testAnkiRequiresAnExplicitSuccessfulEnvelopeAndHTTPStatus() throws {
        let url = URL(string: "http://127.0.0.1:8765")!
        let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        for body in ["{}", "[]", "{\"result\":42}", "{\"error\":null}", "{\"result\":42,\"error\":false}", "{\"result\":42,\"error\":\"failed\"}"] {
            XCTAssertThrowsError(try AnkiConnectResponse.result(data: Data(body.utf8), response: ok), body)
        }
        let body = Data("{\"result\":42,\"error\":null}".utf8)
        XCTAssertEqual(try AnkiConnectResponse.noteID(AnkiConnectResponse.result(data: body, response: ok)), 42)
        let failed = HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!
        XCTAssertThrowsError(try AnkiConnectResponse.result(data: body, response: failed))
        let sync = try AnkiConnectResponse.result(data: Data("{\"result\":null,\"error\":null}".utf8), response: ok)
        XCTAssertTrue(sync is NSNull, "Void actions still accept their documented null result.")
    }
    func testAnkiNeverReportsSuccessForMissingNotesOrMedia() throws {
        for value: Any in [NSNull(), true, false, -1, 0, 1.5, "123", 1e25] {
            XCTAssertThrowsError(try AnkiConnectResponse.noteID(value))
        }
        XCTAssertEqual(try AnkiConnectResponse.noteID(1_700_000_000_000 as Int64), 1_700_000_000_000)
        XCTAssertThrowsError(try AnkiConnectResponse.storedFilename(NSNull(), expected: "media.png"))
        XCTAssertThrowsError(try AnkiConnectResponse.storedFilename("other.png", expected: "media.png"))
        XCTAssertNoThrow(try AnkiConnectResponse.storedFilename("media.png", expected: "media.png"))
    }
    func testCancelledRestorePreservesExistingCollection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let live = root.appendingPathComponent("Books"), stage = root.appendingPathComponent("staging")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: live.appendingPathComponent("current"))
        try Data("replacement".utf8).write(to: stage.appendingPathComponent("new"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try replaceRestoredFolder(staging: stage, destination: live, fileManager: .default)
        }
        do { try await task.value; XCTFail("Cancelled restore must not publish staging.") }
        catch is CancellationError { }
        XCTAssertEqual(try String(contentsOf: live.appendingPathComponent("current"), encoding: .utf8), "keep")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.appendingPathComponent("new").path))
    }
    func testFailedRestoreSwapRollsBackExistingCollection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let live = root.appendingPathComponent("Books")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: live.appendingPathComponent("current"))
        XCTAssertThrowsError(try replaceRestoredFolder(staging: root.appendingPathComponent("missing"), destination: live, fileManager: .default))
        XCTAssertEqual(try String(contentsOf: live.appendingPathComponent("current"), encoding: .utf8), "keep")
    }
}
