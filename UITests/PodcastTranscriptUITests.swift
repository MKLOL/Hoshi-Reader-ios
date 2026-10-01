import XCTest

final class PodcastTranscriptUITests: XCTestCase {
    @MainActor func testTimestampPlaybackWordLookupEnglishAndFollowing() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["HOSHI_UI_TESTING_PODCAST"] = "1"
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        let timestamp = app.buttons["podcast-time-1"]
        XCTAssertTrue(timestamp.waitForExistence(timeout: 15), app.debugDescription)
        let player = app.buttons["podcast-play-pause"]
        XCTAssertEqual(player.label, "Play", "Opening a transcript must be quiet.")
        XCTAssertFalse(app.staticTexts["I read books. I study Japanese."].firstMatch.exists)
        app.buttons["podcast-toggle-english"].tap()
        XCTAssertTrue(app.staticTexts["I read books. I study Japanese."].firstMatch.waitForExistence(timeout: 5))
        app.buttons["podcast-toggle-english"].tap()
        timestamp.tap()
        XCTAssertTrue(wait { player.label == "Pause" })
        let sentence = app.descendants(matching: .any)["podcast-text-1"].firstMatch
        XCTAssertTrue(sentence.waitForExistence(timeout: 5))
        sentence.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.25)).tap()
        XCTAssertTrue(wait { player.label == "Play" }, "A word tap must pause audio.")
        let word = app.webViews.staticTexts["本"].firstMatch
        XCTAssertTrue(word.waitForExistence(timeout: 10), app.debugDescription)
        capture(app, "podcast-word-lookup-pauses-original")
        // Drag the exposed margin, not the dictionary card that overlays the list centre.
        let lines = app.scrollViews["podcast-transcript-lines"]
        lines.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.85)).press(forDuration: 0.1,
            thenDragTo: lines.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.25)))
        let follow = app.buttons["Follow playback"]
        XCTAssertTrue(follow.waitForExistence(timeout: 5))
        follow.tap()
        XCTAssertTrue(wait { !follow.exists })
        XCTAssertEqual(player.label, "Play", "Reading away from the active line must not resume audio.")
        capture(app, "podcast-following-transcript")
    }

    private func wait(_ predicate: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(5)
        while !predicate(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        return predicate()
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
