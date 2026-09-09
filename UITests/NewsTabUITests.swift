import XCTest

/// Drives the real News tab against the live sources: lists articles, saves one as a book, opens
/// the pre-translate sheet and the reader. Network-dependent by nature; screenshots are attached
/// at each step so a failure can be diagnosed from the result bundle.
final class NewsTabUITests: XCTestCase {
    func testNewsTabListsSavesPretranslatesAndOpens() throws {
        let app = XCUIApplication()
        app.launch()

        let newsTab = app.tabBars.buttons["News"]
        XCTAssertTrue(newsTab.waitForExistence(timeout: 10))
        newsTab.tap()
        attach(app, "1-news-tab")

        let wantToRead = app.buttons["Want to read"].firstMatch
        XCTAssertTrue(wantToRead.waitForExistence(timeout: 90), "no article appeared in the News tab")
        attach(app, "2-news-list")

        wantToRead.tap()
        let open = app.buttons["Open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 180), "the article was not saved")
        attach(app, "3-saved")

        let pretranslate = app.buttons["Pre-translate"].firstMatch
        XCTAssertTrue(pretranslate.waitForExistence(timeout: 5))
        pretranslate.tap()
        let sheetTitle = app.navigationBars["Pre-translate article"]
        XCTAssertTrue(sheetTitle.waitForExistence(timeout: 30))
        let estimate = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "sentences ·")).firstMatch
        XCTAssertTrue(estimate.waitForExistence(timeout: 30), "no sentence estimate shown")
        attach(app, "4-pretranslate-sheet")
        app.buttons["Cancel"].firstMatch.tap()

        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        let reader = app.webViews.firstMatch
        XCTAssertTrue(reader.waitForExistence(timeout: 30), "the reader did not open")
        attach(app, "5-reader")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
