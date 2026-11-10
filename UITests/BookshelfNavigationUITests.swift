import XCTest

/// Exercise the real shell with all five tabs and sync enabled, including the iPad mini's
/// shared top row. No toolbar overflow or long menu button should hide routine navigation.
final class BookshelfNavigationUITests: XCTestCase {
    @MainActor func testMangaTextEnlargementPresetsAndLivePreview() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["HOSHI_UI_TESTING"] = "1"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        let manga = app.buttons["settings-manga"]
        XCTAssertTrue(manga.waitForExistence(timeout: 10))
        manga.tap()
        let enabled = app.switches["manga-text-enlargement-enabled"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 5))
        if enabled.value as? String == "0" { enabled.switches.firstMatch.tap() }
        app.buttons["manga-text-preset-balanced"].tap()
        XCTAssertTrue(app.otherElements["manga-text-preview-12-21"].exists, app.debugDescription)
        let list = app.collectionViews["manga-settings"]
        list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            .press(forDuration: 0.3, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.64)),
                   withVelocity: .slow, thenHoldForDuration: 0.4)
        capture(app, "ios-small-text-balanced")
        app.buttons["manga-text-preset-strong"].tap()
        XCTAssertTrue(app.otherElements["manga-text-preview-12-33"].exists, app.debugDescription)
        capture(app, "ios-small-text-strong")
        let amount = app.sliders["manga-text-enlargement-amount"]
        amount.adjust(toNormalizedSliderPosition: 0)
        let amountValue = try XCTUnwrap(Int((amount.value as? String ?? "").filter(\.isNumber)))
        XCTAssertLessThan(amountValue, 75)
        let amountResult = 12 + 28 * amountValue / 100
        XCTAssertTrue(app.otherElements["manga-text-preview-12-\(amountResult)"].waitForExistence(timeout: 5))
        app.buttons["manga-text-preset-strong"].tap()
        let threshold = app.sliders["manga-text-enlargement-threshold"]
        threshold.adjust(toNormalizedSliderPosition: 0)
        let thresholdValue = try XCTUnwrap(Int((threshold.value as? String ?? "").filter(\.isNumber)))
        XCTAssertLessThan(thresholdValue, 40)
        let thresholdResult = 12 + max(0, thresholdValue - 12) * 75 / 100
        XCTAssertTrue(app.otherElements["manga-text-preview-12-\(thresholdResult)"].waitForExistence(timeout: 5))
        app.buttons["manga-text-preset-strong"].tap()
        enabled.switches.firstMatch.tap()
        XCTAssertTrue(app.otherElements["manga-text-preview-12-12"].waitForExistence(timeout: 5), app.debugDescription)
        enabled.switches.firstMatch.tap()
        app.terminate()
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        app.buttons["settings-manga"].tap()
        XCTAssertTrue(app.otherElements["manga-text-preview-12-33"].waitForExistence(timeout: 5), app.debugDescription)
    }

    @MainActor private func launch() throws -> XCUIApplication {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["HOSHI_KV_BASE_URL"], let token = environment["HOSHI_KV_TOKEN"] else {
            throw XCTSkip("Run with the local sync test server to enable the Podcasts tab")
        }
        let app = XCUIApplication()
        app.launchEnvironment["HOSHI_UI_TESTING"] = "1"
        app.launchEnvironment["HOSHI_UI_TESTING_SYNC_URL"] = url
        app.launchEnvironment["HOSHI_UI_TESTING_SYNC_TOKEN"] = token
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Podcasts"].waitForExistence(timeout: 15), app.debugDescription)
        return app
    }

    @MainActor func testEveryTabAndAddMangaStayDirectlyAccessibleInBothOrientations() throws {
        let app = try launch()
        let orientations: [UIDeviceOrientation] = app.frame.width > 600 ? [.portrait, .landscapeLeft] : [.portrait]
        for orientation in orientations {
            XCUIDevice.shared.orientation = orientation
            let expectedLandscape = orientation == .landscapeLeft
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                (app.frame.width > app.frame.height) == expectedLandscape
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed)
            for title in ["Books", "News", "Dictionary", "Podcasts", "Settings"] {
                let tab = app.tabBars.buttons[title]
                XCTAssertTrue(tab.isHittable, "\(title) requires overflow: \(app.debugDescription)")
                tab.tap()
                XCTAssertTrue(tab.isSelected, "\(title) did not become the selected tab")
                if title == "Dictionary" {
                    // Dictionary intentionally focuses its search field. Submit the empty
                    // search to dismiss the keyboard before checking tab-bar navigation.
                    let search = app.textFields.firstMatch
                    XCTAssertTrue(search.waitForExistence(timeout: 5))
                    search.typeText("\n")
                }
            }
            app.tabBars.buttons["Settings"].tap()
            XCTAssertTrue(app.buttons["settings-manga"].waitForExistence(timeout: 5))
            app.buttons["settings-manga"].tap()
            XCTAssertTrue(app.navigationBars["Manga"].waitForExistence(timeout: 5), app.debugDescription)
            app.navigationBars["Manga"].buttons.firstMatch.tap()
            XCTAssertTrue(app.buttons["settings-manga"].waitForExistence(timeout: 5), app.debugDescription)
            app.tabBars.buttons["Books"].tap()
            let add = app.buttons["bookshelf-add-manga"]
            XCTAssertTrue(add.isHittable, "Add manga must be on the toolbar: \(app.debugDescription)")
            XCTAssertLessThanOrEqual(add.frame.width, 60, "Add manga is an icon button")
            XCTAssertLessThanOrEqual(add.frame.height, 60)
            capture(app, expectedLandscape ? "bookshelf-landscape" : "bookshelf-portrait")
            add.tap()
            let cancel = app.buttons["Cancel"].firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 10), app.debugDescription)
            cancel.tap()
        }
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor func testAddMangaOpensFilesAndEPUBRemainsInBookshelfOptions() throws {
        let app = try launch()
        app.buttons["bookshelf-add-manga"].tap()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), app.debugDescription)
        capture(app, "manga-file-picker")
        cancel.tap()
        app.buttons["bookshelf-options"].tap()
        XCTAssertTrue(app.buttons["Select books"].exists)
        XCTAssertTrue(app.buttons["Manage shelves"].exists)
        let epub = app.buttons["Import EPUB"]
        XCTAssertTrue(epub.isHittable, app.debugDescription)
        capture(app, "bookshelf-options")
        epub.tap()
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), app.debugDescription)
        capture(app, "epub-file-picker")
        cancel.tap()
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
