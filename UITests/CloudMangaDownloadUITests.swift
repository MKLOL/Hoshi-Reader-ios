import XCTest

/// The cloud manga flow as a reader sees it, against the real local sync server that
/// tools/test_ios_parity.py starts with the Android corpus: the server's manga is listed under
/// Not downloaded, a tap shows its progress at once, it moves onto the shelf when its download
/// finishes, and it opens at the page Android saved.
final class CloudMangaDownloadUITests: XCTestCase {
    @MainActor func testTappedMangaShowsProgressMovesOntoTheShelfAndOpensAtItsPage() async throws {
        let environment = ProcessInfo.processInfo.environment
        let url = try XCTUnwrap(environment["HOSHI_KV_BASE_URL"], "Run tools/test_ios_parity.py, which starts the sync test server")
        let token = try XCTUnwrap(environment["HOSHI_KV_TOKEN"])
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["HOSHI_UI_TESTING"] = "1"
        app.launchEnvironment["HOSHI_UI_TESTING_SYNC_URL"] = url
        app.launchEnvironment["HOSHI_UI_TESTING_SYNC_TOKEN"] = token
        app.launch()
        XCUIDevice.shared.orientation = .portrait

        let section = app.buttons["cloud-manga-section"]
        XCTAssertTrue(section.waitForExistence(timeout: 30), "the server's manga is listed: \(app.debugDescription)")
        capture(app, "cloud-not-downloaded")
        section.tap()
        let cover = app.buttons["cloud-manga-integration_manga"]
        XCTAssertTrue(cover.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(cover.label, "Download Integration Manga")
        // A slow server, so the download is still running while the test looks at it.
        try await slowNextDownload(url: url, token: token, key: "books/integration_manga/payload.zip", seconds: 4)
        cover.tap()

        // The cell changes the moment it is tapped: no tap goes without visible progress.
        let status = app.staticTexts["cloud-manga-status-integration_manga"]
        XCTAssertTrue(status.waitForExistence(timeout: 2), "a tap shows progress at once: \(app.debugDescription)")
        XCTAssertTrue(["Waiting…", "Downloading…"].contains { status.label.hasPrefix($0) }, status.label)
        let downloading = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in status.label.hasPrefix("Downloading…") }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [downloading], timeout: 4), .completed, status.label)
        XCTAssertFalse(cover.isEnabled, "a downloading manga cannot be tapped again")
        XCTAssertTrue(app.buttons["Cancel"].exists)
        capture(app, "cloud-downloading")

        // It leaves Not downloaded and is on its shelf; never missing from both in between.
        let shelfBook = app.staticTexts["Integration Manga"].firstMatch
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !cover.exists && shelfBook.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 60), .completed, app.debugDescription)
        XCTAssertFalse(app.buttons["cloud-manga-section"].exists, "nothing is left to download")
        capture(app, "cloud-on-shelf")

        shelfBook.tap()
        let probe = app.staticTexts["manga-viewport-probe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 15), app.debugDescription)
        let onAndroidsPage = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in probe.label.hasPrefix("page=3;") }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [onAndroidsPage], timeout: 10), .completed, "opens at Android's bookmark: \(probe.label)")
        capture(app, "cloud-opened-at-android-page")
    }

    private func slowNextDownload(url: String, token: String, key: String, seconds: Double) async throws {
        var request = URLRequest(url: try XCTUnwrap(URL(string: url + "/_test/download_next")))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["pathPrefix": "/v1/kv/" + key, "firstByteDelay": seconds])
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
