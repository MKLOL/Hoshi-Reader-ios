import XCTest

final class PodcastTranscriptUITests: XCTestCase {
    @MainActor func testReaderAppearanceIsAvailableInsideTranscript() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["HOSHI_UI_TESTING_PODCAST"] = "1"
        app.launch()
        let appearance = app.buttons["podcast-appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 15))
        capture(app, "podcast-furigana-visible")
        appearance.tap()
        let hide = app.switches["Hide Furigana"]
        XCTAssertTrue(hide.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Text Orientation"].exists)
        XCTAssertFalse(app.staticTexts["Paginated"].exists)
        let initial = try XCTUnwrap(hide.value as? String, hide.debugDescription)
        XCTAssertTrue(["0", "1"].contains(initial), hide.debugDescription)
        // SwiftUI exposes the whole labeled row as the switch. Tap the visible trailing
        // control; a center tap lands in empty space between its label and the knob.
        func toggle() {
            hide.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: hide.frame.width - min(26, hide.frame.width / 2), dy: hide.frame.height / 2)).tap()
        }
        toggle()
        XCTAssertTrue(wait { hide.value as? String != initial })
        toggle()
        XCTAssertTrue(wait { hide.value as? String == initial })
        app.buttons["close-reader-settings"].tap()
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["podcast-play-pause"].label, "Play")
    }

    @MainActor func testTimestampPlaybackWordLookupEnglishAndFollowing() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["HOSHI_UI_TESTING_PODCAST"] = "1"
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        let transcript = app.webViews["podcast-transcript-lines"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 15), app.debugDescription)
        let timestamp = transcript.buttons["Play from 0m 10s"]
        XCTAssertTrue(timestamp.waitForExistence(timeout: 15), app.debugDescription)
        let player = app.buttons["podcast-play-pause"]
        XCTAssertEqual(player.label, "Play", "Opening a transcript must be quiet.")
        XCTAssertFalse(app.staticTexts["I read books. I study Japanese."].firstMatch.exists)
        app.buttons["podcast-toggle-english"].tap()
        XCTAssertTrue(app.staticTexts["I read books. I study Japanese."].firstMatch.waitForExistence(timeout: 5))
        app.buttons["podcast-toggle-english"].tap()
        timestamp.tap()
        XCTAssertTrue(wait { player.label == "Pause" })
        let sentence = transcript.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "本")).firstMatch
        XCTAssertTrue(sentence.waitForExistence(timeout: 5))
        // WebKit exposes the ruby plus following kana as one accessibility text element
        // ("本ほんを"). Its upper third is the reading; the lower left is the 本 base glyph.
        sentence.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.75)).tap()
        XCTAssertTrue(wait { player.label == "Play" }, "A word tap must pause audio.")
        // A WKWebView exposes nested WebViews without identifiers. Exclude the entire
        // transcript viewport, not just its named outer node, when checking the dictionary card.
        XCTAssertTrue(wait {
            app.webViews.allElementsBoundByIndex.contains { web in
                web.frame != transcript.frame && web.staticTexts["本"].firstMatch.exists
            }
        }, app.debugDescription)
        capture(app, "podcast-word-lookup-pauses-original")
        // Drag the exposed margin, not the dictionary card that overlays the list centre.
        let lines = transcript
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
