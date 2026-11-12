import XCTest

final class StatisticsSyncUITests: XCTestCase {
    @MainActor func testSyncedActivityStreakControlsRetainedHistoryAndTrends() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["HOSHI_UI_TESTING_STATISTICS"] = "1"
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.staticTexts["猫"].firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        let readingTime = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "9m 17s")).firstMatch
        XCTAssertTrue(readingTime.waitForExistence(timeout: 5), app.debugDescription)
        capture(app, "statistics-synced-today")
        let reset = app.buttons["statistics-day-reset"]
        for _ in 0..<6 { if reset.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(reset.isHittable, app.debugDescription)
        reset.tap()
        let hour = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@", "4:00", "AM")).firstMatch
        XCTAssertTrue(hour.waitForExistence(timeout: 5), app.debugDescription)
        hour.tap()
        XCTAssertTrue(reset.label.contains("4:00") || (reset.value as? String)?.contains("4:00") == true, reset.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any)["statistics-time-zone"].exists)
        capture(app, "statistics-streak-settings")
        let history = app.staticTexts["Retained reading history"].firstMatch
        for _ in 0..<12 { if history.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(history.isHittable, app.debugDescription)
        history.tap()
        XCTAssertTrue(app.staticTexts["Not on this device"].waitForExistence(timeout: 5))
        capture(app, "statistics-retained-history")
        if app.frame.width > 600 {
            XCUIDevice.shared.orientation = .landscapeLeft
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.width > app.frame.height }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed)
            XCTAssertTrue(app.staticTexts["Not on this device"].isHittable)
            capture(app, "statistics-retained-history-landscape")
            XCUIDevice.shared.orientation = .portrait
        }
        app.navigationBars.buttons.firstMatch.tap()
        let trends = app.segmentedControls.buttons["Trends"]
        for _ in 0..<12 { if trends.isHittable { break }; app.swipeDown() }
        XCTAssertTrue(trends.isHittable, app.debugDescription)
        trends.tap()
        XCTAssertTrue(app.staticTexts["Daily reading time"].waitForExistence(timeout: 5))
        XCTAssertTrue(readingTime.waitForExistence(timeout: 5), app.debugDescription)
        capture(app, "statistics-trends")
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
