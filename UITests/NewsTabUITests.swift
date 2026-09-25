import XCTest

/// Drives the real News tab against the live sources: lists articles, saves one as a book, opens
/// the pre-translate sheet and the reader. Network-dependent by nature; screenshots are attached
/// at each step so a failure can be diagnosed from the result bundle.
final class NewsTabUITests: XCTestCase {
    override func setUpWithError() throws {
        // A failed step must not cascade into later taps that save and pre-translate other articles.
        continueAfterFailure = false
    }

    func testNewsTabListsSavesPretranslatesAndOpens() throws {
        let app = XCUIApplication()
        app.launch()

        let newsTab = app.tabBars.buttons["News"]
        XCTAssertTrue(newsTab.waitForExistence(timeout: 10))
        newsTab.tap()
        attach(app, "1-news-tab")

        // Sources finish loading at different times and the merged list re-sorts as they arrive,
        // which can scroll the row that was tapped out of the accessibility tree. Filtering to one
        // source keeps the row in place.
        let source = app.buttons["NHK Easier"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10), "no NHK Easier source chip")
        source.tap()

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
        // The reader shows a spinner until the book is laid out; the screenshot is only useful
        // once it is gone, and a spinner that never goes away means the article does not render.
        let spinner = app.activityIndicators.firstMatch
        let deadline = Date().addingTimeInterval(60)
        while spinner.exists && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        attach(app, "5-reader")
        XCTAssertFalse(spinner.exists, "the reader kept loading the article")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
