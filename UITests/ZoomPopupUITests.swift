import XCTest
import UIKit

final class ZoomPopupUITests: XCTestCase {
    /// Explicitly selected physical-device diagnosis. It uses an existing library book and
    /// its saved position; it never seeds a fixture, changes preferences or turns a page.
    func testPhysicalLibraryMangaStartupOpensSavedPageThreeTimes() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let targetIdentifier = environment["HOSHI_REAL_MANGA_TARGET_ID"],
              targetIdentifier.hasPrefix("manga-book-"), !targetIdentifier.dropFirst("manga-book-".count).isEmpty else {
            throw XCTSkip("Set HOSHI_REAL_MANGA_TARGET_ID to the explicitly selected existing manga button identifier.")
        }
#if targetEnvironment(simulator)
        throw XCTSkip("This opt-in diagnosis measures an existing book on the physical iPad.")
#endif
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["HOSHI_MANGA_STARTUP_TRACE"] = "1"
        app.terminate()
        app.launch()
        defer { app.terminate() }

        let booksTab = app.tabBars.buttons["Books"].firstMatch
        if booksTab.waitForExistence(timeout: 3), booksTab.isHittable { booksTab.tap() }
        let expectedDiskPage = environment["HOSHI_REAL_MANGA_EXPECTED_PAGE"].flatMap(Int.init)
        var preservedPage: Int?
        for opening in 0..<3 {
            let target = app.buttons[targetIdentifier].firstMatch
            try revealPhysicalManga(target, in: app)
            var tappedAt = ProcessInfo.processInfo.systemUptime
            target.tap()
            let visible = app.descendants(matching: .any)["manga-first-image-probe"].firstMatch
            // A compact shelf cover expands its shelf first. The same identifier on its
            // expanded BookCell makes the second tap open the selected book without titles.
            if !visible.waitForExistence(timeout: 2) {
                XCTAssertTrue(target.exists && target.isHittable, "selected manga did not open or expand its shelf")
                tappedAt = ProcessInfo.processInfo.systemUptime
                target.tap()
            }
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "first_image_ms="), object: visible)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed,
                           "the selected real manga never reported decoded artwork")
            let viewport = app.descendants(matching: .any)["manga-viewport-probe"].firstMatch
            var matched: (label: String, page: Int, pages: [Int], token: Int)?
            let pageMatchesImage = NSPredicate { [self] _, _ in
                let imageLabel = visible.label, modelLabel = viewport.label
                guard let token = startupValue("load_token", in: imageLabel).flatMap(Int.init),
                      let paintedToken = startupValue("painted_token", in: imageLabel).flatMap(Int.init),
                      token == paintedToken,
                      let page = startupValue("page", in: modelLabel).flatMap(Int.init),
                      let decoded = startupValue("decoded_pages", in: imageLabel) else { return false }
                let fields = decoded.split(separator: ","), pages = fields.compactMap { Int($0) }
                guard (1...2).contains(pages.count), pages.count == fields.count,
                      pages.allSatisfy({ $0 >= 0 }), pages.contains(page - 1),
                      visible.label == imageLabel else { return false }
                matched = (imageLabel, page, pages, token)
                return true
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: pageMatchesImage, object: viewport)], timeout: 10), .completed,
                           "the current document's decoded page must match the reader bookmark after any live sync update")
            let observed = try XCTUnwrap(matched, "no decoded current-page observation was captured")
            let milliseconds = try XCTUnwrap(Double(try startupField("first_image_ms", in: observed.label)))
            let stablePage = preservedPage.map { $0 == observed.page } ?? true
            if preservedPage == nil { preservedPage = observed.page }
            // A live remote winner may legitimately differ from the earlier read-only disk
            // snapshot; record that comparison without treating the snapshot as authoritative.
            print("PHYSICAL_MANGA_STARTUP opening=\(opening + 1) native_ms=\(milliseconds) ui_tap_elapsed_ms=\((ProcessInfo.processInfo.systemUptime - tappedAt) * 1000) load_token=\(observed.token) page=\(observed.page) decoded_pages=\(observed.pages) prior_disk_page=\(expectedDiskPage ?? -1) stable_page=\(stablePage) no_initial_reload=\(observed.token == 1)")
            saveScreenshot(app, name: "physical-manga-startup-opening-\(opening + 1)")
            XCTAssertTrue(milliseconds.isFinite && milliseconds > 0, "first-image latency must be finite and positive")

            let back = app.descendants(matching: .any)["manga-back"].firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 3))
            back.tap()
            let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: visible)
            XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 10), .completed)
        }
    }

    private func startupField(_ key: String, in label: String) throws -> String {
        try XCTUnwrap(startupValue(key, in: label), "startup probe is missing \(key)")
    }

    private func startupValue(_ key: String, in label: String) -> String? {
        let prefix = key + "="
        guard let field = label.split(separator: ";").first(where: { $0.hasPrefix(prefix) }) else { return nil }
        return String(field.dropFirst(prefix.count))
    }

    private func revealPhysicalManga(_ target: XCUIElement, in app: XCUIApplication) throws {
        if target.waitForExistence(timeout: 10), target.isHittable { return }
        let shelf = app.scrollViews.firstMatch
        XCTAssertTrue(shelf.exists, "the library shelf is unavailable")
        for _ in 0..<10 {
            if target.exists && target.isHittable { return }
            shelf.swipeUp()
        }
        for _ in 0..<10 {
            if target.exists && target.isHittable { return }
            shelf.swipeDown()
        }
        throw ProbeError("The explicitly selected real manga is not accessible on the current bookshelf.")
    }

    /// Measures the full production manga route on a disposable simulator. The fixture is
    /// generated only by its explicit DEBUG launch flag; this test must never run on a device
    /// containing the user's library. Readiness is image decode + two frames, not DOM/navigation.
    func testMangaStartupShowsDecodedImagePromptlyAndReopensAtSavedPage() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("The generated startup fixture is restricted to a disposable simulator.")
#endif
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["HOSHI_UI_TESTING"] = "1"
        app.launchEnvironment["HOSHI_UI_TESTING_ZOOM"] = "1"
        app.launchEnvironment["HOSHI_MANGA_STARTUP_TRACE"] = "1"
        app.launchArguments += ["-mangaSingleTapLookup", "NO", "-mangaShowFurigana", "NO"]
        XCUIDevice.shared.orientation = .portrait
        // A fail-fast XCTest assertion can bypass deferred teardown. Explicitly replace the
        // preceding process so the first measurement cannot reuse its completed controller.
        app.terminate()
        app.launch()
        defer { app.terminate() }

        for opening in 0..<3 {
            let fixture = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "IDB Zoom Fixture")).firstMatch
            XCTAssertTrue(fixture.waitForExistence(timeout: 5))
            let tappedAt = ProcessInfo.processInfo.systemUptime
            fixture.tap()
            let visible = app.descendants(matching: .any)["manga-first-image-probe"].firstMatch
            let imageReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "first_image_ms="), object: visible)
            XCTAssertEqual(XCTWaiter.wait(for: [imageReady], timeout: 5), .completed,
                           "the manga image never decoded and reached two rendering frames: \(visible.label)")
            let firstImageLabel = visible.label
            print("Manga first-image probe opening=\(opening + 1) label=\(firstImageLabel.debugDescription)")
            let timingField = try XCTUnwrap(firstImageLabel.split(separator: ";").first,
                                           "first-image label has no timing field: \(firstImageLabel.debugDescription)")
            let milliseconds = try XCTUnwrap(Double(timingField.replacingOccurrences(of: "first_image_ms=", with: "")),
                                            "first-image timing is not a machine-readable number: \(firstImageLabel.debugDescription)")
            XCTAssertGreaterThan(milliseconds, 0)
            print("Manga first visible image opening=\(opening + 1) native_ms=\(milliseconds) ui_tap_elapsed_ms=\((ProcessInfo.processInfo.systemUptime - tappedAt) * 1000)")

            let viewport = app.descendants(matching: .any)["manga-viewport-probe"].firstMatch
            let expectedPage = opening == 0 ? 1 : 2
            let paintedPages = try XCTUnwrap(firstImageLabel.split(separator: ";").first { $0.hasPrefix("painted_pages=") },
                                            "decoded image identity is missing: \(firstImageLabel.debugDescription)")
            XCTAssertEqual(String(paintedPages), "painted_pages=\(expectedPage - 1)",
                           "the decoded HTML image must match the restored bookmark, not just the model page")
            XCTAssertTrue(waitForViewport(viewport, containing: "page=\(expectedPage);"),
                          "reopening must restore the saved nonzero page: \(viewport.label)")
            XCTAssertTrue(visible.label.split(separator: ";").contains("load_token=1"),
                          "initial bookmark restoration must load one document: \(visible.label)")
            let duplicateInitialLoad = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == true AND NOT (label MATCHES %@)", ".*;load_token=1(;.*)?"), object: visible)
            duplicateInitialLoad.isInverted = true
            XCTAssertEqual(XCTWaiter.wait(for: [duplicateInitialLoad], timeout: 0.5), .completed,
                           "a late initial-page change must not replace the first document")
            try assertFixtureArtworkIsVisible(name: "manga-first-image-opening-\(opening + 1)")
            XCTAssertLessThan(milliseconds, 1500,
                              "a local three-page book must not regress to a three-second black screen")

            if opening == 0 {
                app.buttons["manga-options-menu"].tap()
                app.buttons["Go to page"].tap()
                let field = app.textFields["manga-go-to-page-field"]
                XCTAssertTrue(field.waitForExistence(timeout: 3))
                field.tap()
                let oldValue = field.value as? String ?? ""
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: oldValue.count) + "2")
                app.buttons["manga-go-to-page-confirm"].tap()
                XCTAssertTrue(waitForViewport(viewport, containing: "page=2;"), viewport.label)
            }
            let back = app.descendants(matching: .any)["manga-back"].firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 3))
            back.tap()
            let readerClosed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: visible)
            XCTAssertEqual(XCTWaiter.wait(for: [readerClosed], timeout: 5), .completed)
        }
    }

    /// Check the fixture's white paper and two gray artwork blocks. White alone could be the
    /// bookshelf behind an invisible reader; the image-relative blocks prove the artwork shows.
    private func assertFixtureArtworkIsVisible(name: String) throws {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let image = try XCTUnwrap(screenshot.image.cgImage)
        let sourceWidth: CGFloat = 1179, sourceHeight: CGFloat = 2556
        let scale = min(CGFloat(image.width) / sourceWidth, CGFloat(image.height) / sourceHeight)
        let origin = CGPoint(x: (CGFloat(image.width) - sourceWidth * scale) / 2,
                             y: (CGFloat(image.height) - sourceHeight * scale) / 2)
        let samples: [(String, CGPoint, ClosedRange<UInt8>)] = [
            ("white paper", CGPoint(x: 590, y: 1280), 221...255),
            ("upper gray artwork", CGPoint(x: 480, y: 975), 150...190),
            ("lower gray artwork", CGPoint(x: 450, y: 1775), 150...190)
        ]
        for (label, sourcePoint, expected) in samples {
            let point = CGPoint(x: (origin.x + sourcePoint.x * scale).rounded(.down),
                                y: (origin.y + sourcePoint.y * scale).rounded(.down))
            let pixelImage = try XCTUnwrap(image.cropping(to: CGRect(origin: point, size: CGSize(width: 1, height: 1))))
            var pixel = [UInt8](repeating: 0, count: 4)
            try pixel.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                    bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(pixelImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            XCTAssertTrue(pixel.prefix(3).allSatisfy { expected.contains($0) },
                          "first-image readiness must show \(label), not a blank/hidden reader; pixel=\(pixel), point=\(point)")
        }
    }

    @MainActor func testMangaTextSizePreviewStartsAtCurrentPageAndDoesNotMoveBookmark() throws {
        continueAfterFailure = false
        let app = try launchZoomFixture(syntheticFixture: true, textSizePreview: true)
        app.buttons["manga-options-menu"].tap()
        app.buttons["Go to page"].tap()
        let field = app.textFields["manga-go-to-page-field"]
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (field.value as? String ?? "").count) + "2")
        app.buttons["manga-go-to-page-confirm"].tap()
        let probe = app.descendants(matching: .any)["manga-viewport-probe"].firstMatch
        XCTAssertTrue(waitForViewport(probe, containing: "page=2;"))
        let readerFrame = app.webViews.firstMatch.frame
        app.buttons["manga-options-menu"].tap()
        app.buttons["manga-preview-text-size"].tap()
        let page = app.staticTexts["manga-preview-page"]
        XCTAssertTrue(page.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(page.label.contains("Page 2"), page.label)
        func assertReaderViewport() {
            let frame = app.webViews.firstMatch.frame
            XCTAssertEqual(frame.width, readerFrame.width, accuracy: 0.5)
            XCTAssertEqual(frame.height, readerFrame.height, accuracy: 0.5)
            XCTAssertEqual(frame.minX, readerFrame.minX, accuracy: 0.5)
            XCTAssertEqual(frame.minY, readerFrame.minY, accuracy: 0.5)
        }
        assertReaderViewport()
        app.buttons["Hide controls"].tap()
        assertReaderViewport()
        app.buttons["Show controls"].tap()
        assertReaderViewport()
        app.buttons["Previous page"].tap()
        app.buttons["Strong"].tap()
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
            object: app.descendants(matching: .any)["manga-preview-loading"].firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        XCTAssertTrue(app.sliders["Enlargement amount"].isHittable)
        XCTAssertTrue(app.sliders["Small-text cutoff"].isHittable)
        saveScreenshot(app, name: "ios-manga-page-adjusted")
        app.buttons["Hide controls"].tap()
        assertReaderViewport()
        saveScreenshot(app, name: "ios-manga-page-fullscreen")
        app.buttons["Show controls"].tap()
        app.buttons["Original size"].tap()
        let originalReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
            object: app.descendants(matching: .any)["manga-preview-loading"].firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [originalReady], timeout: 10), .completed)
        saveScreenshot(app, name: "ios-manga-page-original")
        app.buttons["Next page"].tap()
        app.buttons["Next page"].tap()
        XCTAssertTrue(page.label.contains("Page 3"), page.label)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(waitForViewport(probe, containing: "page=2;"), probe.label)
        app.buttons["manga-options-menu"].tap()
        app.buttons["manga-preview-text-size"].tap()
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        XCTAssertTrue(page.label.contains("Page 2"))
        app.buttons["Subtle"].tap()
        app.buttons["manga-preview-apply"].tap()
        XCTAssertTrue(waitForViewport(probe, containing: "page=2;"), probe.label)
    }

    func testPageJumpSubmitsWithKeyboardGo() throws {
        continueAfterFailure = false
        let app = try launchZoomFixture(syntheticFixture: true)
        let probe = app.descendants(matching: .any)["manga-viewport-probe"].firstMatch
        app.buttons["manga-options-menu"].tap()
        app.buttons["Go to page"].tap()
        let field = app.textFields["manga-go-to-page-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        let oldValue = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: oldValue.count) + "2")
        XCTAssertEqual(field.value as? String, "2")
        XCTAssertTrue(app.buttons["manga-go-to-page-confirm"].isEnabled)
        field.typeText("\n")
        XCTAssertTrue(waitForViewport(probe, containing: "page=2;"), probe.label)
        XCTAssertFalse(field.exists)
    }

    func testScreenshotCropClearsRevealedOCRBeforeSelecting() throws {
        continueAfterFailure = false
        let app = try launchZoomFixture(syntheticFixture: true)
        let box = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "日本語")).firstMatch
        XCTAssertTrue(box.waitForExistence(timeout: 5))
        box.tap()
        let translate = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Ask about this bubble")).firstMatch
        XCTAssertTrue(translate.waitForExistence(timeout: 3))
        app.buttons["manga-options-menu"].tap()
        app.buttons["Screenshot translate"].tap()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        let cleared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: translate)
        XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 3), .completed)
        cancel.tap()
        // The action stays cleared after removing the crop overlay; it was not merely covered.
        XCTAssertFalse(translate.exists)
        box.tap()
        XCTAssertTrue(translate.waitForExistence(timeout: 3))
    }

    func testTranslationAndHistoryBlockHardwarePageTurns() throws {
        continueAfterFailure = false
        let app = try launchZoomFixture(aiStub: true, syntheticFixture: true)
        let probe = app.descendants(matching: .any)["manga-viewport-probe"].firstMatch
        XCTAssertTrue(waitForViewport(probe, containing: "page=1;"), probe.label)
        try askAboutBubble(app: app, textContains: "日本語")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "UI1OK")).firstMatch.waitForExistence(timeout: 3))
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [])
        let hiddenTurn = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "page=2;"), object: probe)
        hiddenTurn.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [hiddenTurn], timeout: 1), .completed)
        dismissAiPopup(app)
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [])
        XCTAssertTrue(waitForViewport(probe, containing: "page=2;"), probe.label)

        app.buttons["manga-options-menu"].tap()
        app.buttons["Chat history"].tap()
        XCTAssertTrue(app.staticTexts["Translation history"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["translation-history-toggle"].exists, "history-only mode must not offer a dead Back to chat action")
        XCTAssertFalse(app.staticTexts["translation-history-empty"].exists)
        let copyReply = app.buttons["translation-history-copy-reply"].firstMatch
        XCTAssertTrue(copyReply.waitForExistence(timeout: 3))
        XCTAssertTrue(copyReply.isHittable)
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [])
        let historyTurn = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "page=3;"), object: probe)
        historyTurn.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [historyTurn], timeout: 1), .completed)
        dismissAiPopup(app)
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [])
        XCTAssertTrue(waitForViewport(probe, containing: "page=3;"), probe.label)
    }

    func testRepeatedOCRTapKeepsTranslateButtonInPlace() throws {
        continueAfterFailure = false
        for showCopy in [false, true] {
            let app = try launchZoomFixture(showCopy: showCopy, syntheticFixture: true, chromeFixture: true)
            for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
                XCUIDevice.shared.orientation = orientation
                let box = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "日本語")).firstMatch
                XCTAssertTrue(box.waitForExistence(timeout: 5))
                let tap = box.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                tap.tap()
                let translate = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Ask about this bubble")).firstMatch
                XCTAssertTrue(translate.waitForExistence(timeout: 5))
                let first = translate.frame
                XCTAssertGreaterThan(first.width, 20)
                XCTAssertGreaterThan(first.height, 20)
                for _ in 0..<3 {
                    tap.tap()
                    XCTAssertTrue(translate.exists)
                    let repeated = translate.frame
                    XCTAssertEqual(repeated.minX, first.minX, accuracy: 1, "repeated OCR tap shifted translate horizontally")
                    XCTAssertEqual(repeated.minY, first.minY, accuracy: 1, "repeated OCR tap shifted translate vertically")
                    XCTAssertEqual(repeated.width, first.width, accuracy: 1)
                    XCTAssertEqual(repeated.height, first.height, accuracy: 1)
                }
                saveScreenshot(app, name: "ocr-repeat-\(showCopy ? "copy" : "solo")-\(orientation.rawValue)")
            }
            app.terminate()
        }
    }

    func testLowMangaLookupKeepsDictionaryReadableAndMovesTranslate() throws {
        continueAfterFailure = false
        let app = try launchZoomFixture(aiStub: true, syntheticFixture: true, chromeFixture: true, lookupFixture: true)
        let page = app.webViews.firstMatch
        let bubble = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "猫")).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(bubble.frame.minY, page.frame.midY)
        bubble.tap()

        let translate = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Ask about this bubble")).firstMatch
        let copy = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Copy bubble text")).firstMatch
        XCTAssertTrue(translate.waitForExistence(timeout: 5))
        let original = translate.frame
        XCTAssertLessThan(original.maxY, bubble.frame.minY)

        let boxFrame = bubble.frame
        let selection = app.descendants(matching: .any)["manga-selection-probe"].firstMatch
        _ = try tapUntilSelectionProbeUpdates(app: app, boxFrame: boxFrame, visibleBounds: page.frame,
            probe: selection, offsets: [CGVector(dx: 0.06, dy: 0.3), CGVector(dx: 0.09, dy: 0.42)])
        let definition = app.staticTexts["Fixture cat definition"].firstMatch
        XCTAssertTrue(definition.waitForExistence(timeout: 5), selection.label)
        let card = app.webViews.containing(.staticText, identifier: "Fixture cat definition").firstMatch
        XCTAssertTrue(card.exists)
        let cardFrame = card.frame
        XCTAssertGreaterThan(cardFrame.height, page.frame.height * 0.28)
        XCTAssertLessThan(cardFrame.maxY, boxFrame.minY)
        XCTAssertTrue(cardFrame.intersects(original), "The fixture must cover Translate’s original position.")
        let relocated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            translate.exists && copy.exists && !cardFrame.intersects(translate.frame) &&
                !cardFrame.intersects(copy.frame) && !translate.frame.isEmpty && translate.frame != original
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [relocated], timeout: 5), .completed)
        XCTAssertEqual(card.frame, cardFrame)
        XCTAssertTrue(translate.isHittable)
        saveScreenshot(app, name: "manga-dictionary-relocated-translate")
        translate.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "UI1OK")).firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor func testPopupCardsLivePreview() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["HOSHI_UI_TESTING"] = "1"
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        app.buttons["Settings"].firstMatch.tap()
        let editor = app.buttons["settings-popup-cards"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        let dictionary = app.segmentedControls["card-type"].buttons["Dictionary"]
        let translation = app.segmentedControls["card-type"].buttons["Translation"]
        let reset = app.buttons["card-reset"]
        func reveal(_ element: XCUIElement) {
            let controls = app.descendants(matching: .any)["card-controls"].firstMatch
            controls.swipeUp()
            for _ in 0..<3 where !element.isHittable { controls.swipeUp() }
        }
        reveal(reset); reset.tap()
        let word = app.webViews.staticTexts["本"].firstMatch
        XCTAssertTrue(app.webViews.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "book; volume")).firstMatch.waitForExistence(timeout: 10))
        let originalHeight = word.frame.height
        saveScreenshot(app, name: "reader-dictionary-default")
        app.buttons["card-full-preview"].tap()
        XCTAssertTrue(word.waitForExistence(timeout: 10)); XCTAssertTrue(word.isHittable)
        saveScreenshot(app, name: "reader-dictionary-default-full")
        app.navigationBars["Card preview"].buttons["Done"].tap()
        let font = app.sliders["card-font"]
        reveal(font); font.adjust(toNormalizedSliderPosition: 0.4)
        XCTAssertGreaterThan(word.frame.height, originalHeight * 1.3, app.debugDescription)
        saveScreenshot(app, name: "reader-dictionary-adjusted")
        app.buttons["card-full-preview"].tap()
        XCTAssertTrue(word.waitForExistence(timeout: 10))
        XCTAssertTrue(word.isHittable)
        saveScreenshot(app, name: "reader-dictionary-adjusted-full")
        app.navigationBars["Card preview"].buttons["Done"].tap()
        translation.tap()
        reveal(reset); reset.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "I like reading books.")).firstMatch.waitForExistence(timeout: 5))
        saveScreenshot(app, name: "reader-translation-default")
        app.buttons["card-full-preview"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "I like reading books.")).firstMatch.waitForExistence(timeout: 5))
        saveScreenshot(app, name: "reader-translation-default-full")
        app.navigationBars["Card preview"].buttons["Done"].tap()
        reveal(font); font.adjust(toNormalizedSliderPosition: 0.4)
        app.buttons["card-full-preview"].tap()
        XCTAssertTrue(app.navigationBars["Card preview"].waitForExistence(timeout: 5))
        saveScreenshot(app, name: "reader-translation-adjusted-full")
        app.navigationBars["Card preview"].buttons["Done"].tap()
        reveal(reset); reset.tap()
        dictionary.tap()
        XCTAssertGreaterThan(word.frame.height, originalHeight * 1.3)
        app.terminate(); app.launch()
        app.buttons["Settings"].firstMatch.tap()
        app.buttons["settings-popup-cards"].tap()
        XCTAssertTrue(word.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(word.frame.height, originalHeight * 1.3, "Dictionary overrides survive relaunch")
        reveal(reset); reset.tap()
    }

    func testPageJumpResetsZoomAndAllowsTheNextSwipe() throws {
        continueAfterFailure = false
        let app = try launchZoomFixture(syntheticFixture: true)
        let webView = app.webViews.firstMatch
        let probe = app.descendants(matching: .any)["manga-viewport-probe"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForViewport(probe, containing: "zoom=1.000;offsetX=0.0;offsetY=0.0"), probe.label)
        webView.pinch(withScale: 2, velocity: 1)
        XCTAssertFalse(probe.label.contains("zoom=1.000"), probe.label)

        app.buttons["manga-options-menu"].tap()
        app.buttons["Go to page"].tap()
        let field = app.textFields.firstMatch
        field.tap()
        let oldValue = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: oldValue.count) + "2")
        app.buttons["manga-go-to-page-confirm"].tap()
        XCTAssertTrue(waitForViewport(probe, containing: "page=2;zoom=1.000;offsetX=0.0;offsetY=0.0"), probe.label)
        webView.swipeRight()
        XCTAssertTrue(waitForViewport(probe, containing: "page=3;zoom=1.000;offsetX=0.0;offsetY=0.0"), probe.label)
        webView.swipeLeft()
        XCTAssertTrue(waitForViewport(probe, containing: "page=2;zoom=1.000;offsetX=0.0;offsetY=0.0"), probe.label)
        saveScreenshot(app, name: "page-turn-at-fit-scale")
    }

    func testTranslateOnlyBubbleAndStatisticsTabs() throws {
        continueAfterFailure = false
        let app = try launchZoomFixture(aiStub: true, showCopy: false)
        let box = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "日本語")).firstMatch
        XCTAssertTrue(box.waitForExistence(timeout: 5))
        box.tap()
        let translate = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Ask about this bubble")).firstMatch
        XCTAssertTrue(translate.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Copy bubble text")).firstMatch.exists)
        translate.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "UI1OK")).firstMatch.waitForExistence(timeout: 5))
        saveScreenshot(app, name: "translate-only-bubble")
        app.terminate()
        app.launch()
        let statistics = app.buttons["Statistics"].firstMatch
        XCTAssertTrue(statistics.waitForExistence(timeout: 5))
        statistics.tap()
        XCTAssertTrue(app.navigationBars["Statistics"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Today"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Trends"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Daily reading time"].firstMatch.waitForExistence(timeout: 5))
        saveScreenshot(app, name: "statistics-trends")
    }

    private func waitForViewport(_ probe: XCUIElement, containing value: String) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", value), object: probe
        )], timeout: 10) == .completed
    }

    /// Run on an empty simulator with tools/sync-test-server listening on loopback port 18795.
    func testBookshelfCloudSyncShowsCompletionAndErrors() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        app.buttons["Advanced"].tap()
        app.buttons["Sync (HTTP)"].tap()
        let url = app.textFields["Base URL"]
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        url.tap()
        url.press(forDuration: 1.2)
        let selectAll = app.menuItems["Select All"]
        if selectAll.waitForExistence(timeout: 3) { selectAll.tap() }
        url.typeText("http://127.0.0.1:18795")
        XCTAssertEqual(url.value as? String, "http://127.0.0.1:18795")
        let token = app.secureTextFields["Bearer token"]
        token.tap()
        token.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 80))
        token.typeText("bookshelf-ui-test\n")
        app.tabBars.buttons["Books"].tap()
        let cloud = app.buttons["bookshelf-http-sync"]
        XCTAssertTrue(cloud.waitForExistence(timeout: 5))
        cloud.tap()
        XCTAssertTrue(app.staticTexts["Sync complete"].waitForExistence(timeout: 60))
        saveScreenshot(app, name: "bookshelf-sync-complete")
        app.buttons["Done"].tap()
        app.tabBars.buttons["Settings"].tap()
        token.tap()
        token.typeText("-invalid\n")
        app.tabBars.buttons["Books"].tap()
        cloud.tap()
        let error = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "401")).firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 20), app.debugDescription)
        saveScreenshot(app, name: "bookshelf-sync-error")
    }

    func testUltraThinActionButtonsStayVisibleAndTappable() throws {
        continueAfterFailure = false
        let app = try launchZoomFixture(aiStub: true, syntheticFixture: true)
        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 5))

        let probeElement = app.descendants(matching: .any)["manga-action-layout-probe"].firstMatch
        XCTAssertTrue(probeElement.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForActionProbe(probeElement, timeout: 5), probeElement.label)
        let probes = try parseActionProbe(probeElement.label)
        XCTAssertGreaterThanOrEqual(probes.count, 6, probeElement.label)

        for probe in probes {
            XCTAssertNotEqual(probe.placement, "hidden", "\(probe.id) toolbar should have a clean visible placement")
            assertVisible(probe.ai, id: "\(probe.id)-ai", webViewFrame: webView.frame, topInset: probe.topInset)
            assertVisible(probe.copy, id: "\(probe.id)-copy", webViewFrame: webView.frame, topInset: probe.topInset)
            let renderedRects = probe.textRects.isEmpty ? [probe.textRect] : probe.textRects
            for textRect in renderedRects {
                assertDoesNotOverlap(probe.ai, textRect, id: "\(probe.id)-ai-line-text")
                assertDoesNotOverlap(probe.copy, textRect, id: "\(probe.id)-copy-line-text")
            }
            if probe.placement == "below" {
                let renderedBottom = renderedRects
                    .map { $0.y + $0.height }
                    .max() ?? (probe.textRect.y + probe.textRect.height)
                XCTAssertGreaterThanOrEqual(
                    probe.ai.y,
                    renderedBottom - 1,
                    "\(probe.id)-ai should sit below rendered text"
                )
                XCTAssertGreaterThanOrEqual(
                    probe.copy.y,
                    renderedBottom - 1,
                    "\(probe.id)-copy should sit below rendered text"
                )
            }
        }

        try tapActionButton(
            app: app,
            textContains: "UI_THIN_RIGHT",
            accessibilityLabel: "Ask about this bubble",
            probe: actionProbe(probes, containing: "UI_THIN_RIGHT")
        )
        let thinAnswer = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "UI1OK")).firstMatch
        XCTAssertTrue(thinAnswer.waitForExistence(timeout: 3))
        dismissAiPopup(app)

        try tapActionButton(
            app: app,
            textContains: "UI_THIN_TOP_RIGHT",
            accessibilityLabel: "Ask about this bubble",
            probe: actionProbe(probes, containing: "UI_THIN_TOP_RIGHT")
        )
        let topAnswer = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "UI1OK")).firstMatch
        XCTAssertTrue(topAnswer.waitForExistence(timeout: 3))
        dismissAiPopup(app)

        try tapActionButton(
            app: app,
            textContains: "UI_THIN_LEFT",
            accessibilityLabel: "Copy bubble text",
            probe: actionProbe(probes, containing: "UI_THIN_LEFT")
        )
        let copyProbe = app.descendants(matching: .any)["manga-copy-probe"].firstMatch
        XCTAssertTrue(copyProbe.waitForExistence(timeout: 3))
        XCTAssertTrue(waitForCopyProbe(copyProbe, expected: "copy=UI_THIN_LEFT copy target", timeout: 3), copyProbe.label)

        try tapActionButton(
            app: app,
            textContains: "UI_THIN_TOP_RIGHT",
            accessibilityLabel: "Copy bubble text",
            probe: actionProbe(probes, containing: "UI_THIN_TOP_RIGHT")
        )
        XCTAssertTrue(waitForCopyProbe(copyProbe, expected: "copy=UI_THIN_TOP_RIGHT", timeout: 3), copyProbe.label)
    }

    func testSelectionRectStaysNearZoomedMangaTap() throws {
        continueAfterFailure = false
        let app = try launchZoomFixture(syntheticFixture: true)

        let japaneseBox = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "日本語")).firstMatch
        XCTAssertTrue(japaneseBox.waitForExistence(timeout: 5))
        let initialFrame = japaneseBox.frame

        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 3))
        let viewport = app.descendants(matching: .any)["manga-viewport-probe"].firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 3))
        // Establish zoom on the artwork before revealing selectable OCR text, then verify the
        // native viewport before testing where a lookup selection anchors its popup.
        webView.pinch(withScale: 1.6, velocity: 1.0)
        let didZoom = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let zoom = self.labelParts(viewport.label)["zoom"].flatMap(Double.init) else { return false }
            return zoom > 1.01
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [didZoom], timeout: 5), .completed, viewport.label)
        let nativeZoom = try XCTUnwrap(labelParts(viewport.label)["zoom"].flatMap(Double.init), viewport.label)
        XCTAssertGreaterThan(nativeZoom, 1.01, viewport.label)

        let revealFrame = try visibleSwitchFrame(app: app, textContains: "日本語", in: webView)
        let revealPoint = hitSlopPoint(for: revealFrame, in: webView.frame)
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: revealPoint.x, dy: revealPoint.y))
            .tap()
        sleep(1)

        let zoomedFrame = try visibleSwitchFrame(app: app, textContains: "日本語", in: webView)
        XCTAssertGreaterThan(zoomedFrame.width, 0)
        XCTAssertGreaterThan(zoomedFrame.height, 0)
        XCTAssertGreaterThan(initialFrame.height, 0)

        let probe = app.descendants(matching: .any)["manga-selection-probe"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 3))

        let tap = try tapUntilSelectionProbeUpdates(
            app: app,
            boxFrame: zoomedFrame,
            visibleBounds: webView.frame,
            probe: probe,
            // The fixture has one horizontal line. Target its first glyph, not an arbitrary
            // suffix near the right edge, so the selected text has a deterministic meaning.
            offsets: [CGVector(dx: 0.06, dy: 0.30), CGVector(dx: 0.10, dy: 0.30)]
        )
        let selection = try parseSelectionProbe(probe.label)
        XCTAssertTrue(
            selection.text.contains("日本語") || selection.text.contains("本語") || selection.text.contains("テスト"),
            "Unexpected selected text: \(selection.text)"
        )
        XCTAssertGreaterThan(selection.zoom, 1.01, probe.label)
        XCTAssertLessThan(selection.width, 130, probe.label)
        XCTAssertLessThan(selection.height, 130, probe.label)

        let distance = hypot(selection.midX - Double(tap.x), selection.midY - Double(tap.y))
        let allowedDistance = max(
            80.0,
            min(160.0, max(Double(zoomedFrame.width), Double(zoomedFrame.height)) * 0.45)
        )
        XCTAssertLessThan(distance, allowedDistance, "selection=\(probe.label), tap=\(tap)")

        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "zoomed-selection"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testLowerRevealedMangaTextCanBeSelected() throws {
        let app = try launchZoomFixture()
        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 5))

        let lowerBox = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "下段選択")).firstMatch
        XCTAssertTrue(lowerBox.waitForExistence(timeout: 5))

        let actionProbeElement = app.descendants(matching: .any)["manga-action-layout-probe"].firstMatch
        XCTAssertTrue(actionProbeElement.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForActionProbe(actionProbeElement, timeout: 5), actionProbeElement.label)
        let probes = try parseActionProbe(actionProbeElement.label)
        guard let lowerProbe = probes.first(where: { $0.id == "lower-select" }) else {
            throw ProbeError("No lower-select probe in \(actionProbeElement.label)")
        }

        let probe = app.descendants(matching: .any)["manga-selection-probe"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 3))

        lowerBox.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let lowerLinePoint = CGPoint(
            x: min(
                webView.frame.maxX - 6,
                max(webView.frame.minX + 6, webView.frame.minX + lowerProbe.textRect.x + min(30, lowerProbe.textRect.width * 0.35))
            ),
            y: min(
                webView.frame.maxY - 6,
                max(webView.frame.minY + 6, webView.frame.minY + lowerProbe.textRect.y + lowerProbe.textRect.height * 0.75)
            )
        )
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: lowerLinePoint.x, dy: lowerLinePoint.y))
            .tap()

        XCTAssertTrue(waitForSelectionProbe(probe, containing: "段選択", timeout: 3), probe.label)
        let selection = try parseSelectionProbe(probe.label)
        XCTAssertTrue(selection.text.contains("段選択"), probe.label)
        XCTAssertFalse(selection.text.contains("上段"), probe.label)
    }

    func testScreenshotCropProducesPngAfterZoomedPan() throws {
        let app = try launchZoomFixture()

        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 5))
        webView.pinch(withScale: 1.6, velocity: 1.0)
        sleep(1)

        let panStart = webView.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.70))
        let panEnd = webView.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.38))
        panStart.press(forDuration: 0.1, thenDragTo: panEnd)
        sleep(1)

        let menu = app.buttons["manga-options-menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 3))
        menu.tap()

        let screenshotTranslate = app.buttons["Screenshot translate"].firstMatch
        XCTAssertTrue(screenshotTranslate.waitForExistence(timeout: 3))
        screenshotTranslate.tap()

        let cropStart = webView.coordinate(withNormalizedOffset: CGVector(dx: 0.28, dy: 0.28))
        let cropEnd = webView.coordinate(withNormalizedOffset: CGVector(dx: 0.74, dy: 0.62))
        cropStart.press(forDuration: 0.1, thenDragTo: cropEnd)

        let translate = app.buttons["Translate"].firstMatch
        XCTAssertTrue(translate.waitForExistence(timeout: 3))
        translate.tap()

        let cropProbe = app.descendants(matching: .any)["manga-crop-probe"].firstMatch
        XCTAssertTrue(cropProbe.waitForExistence(timeout: 3))
        XCTAssertTrue(waitForCropProbe(cropProbe, timeout: 5), cropProbe.label)

        let crop = try parseCropProbe(cropProbe.label)
        XCTAssertEqual(crop.mime, "image/png", cropProbe.label)
        XCTAssertGreaterThan(crop.base64Length, 100, cropProbe.label)
        XCTAssertEqual(crop.page, 0, cropProbe.label)
        XCTAssertGreaterThanOrEqual(crop.left, 0, cropProbe.label)
        XCTAssertGreaterThanOrEqual(crop.top, 0, cropProbe.label)
        XCTAssertGreaterThanOrEqual(crop.width, 32, cropProbe.label)
        XCTAssertGreaterThanOrEqual(crop.height, 32, cropProbe.label)
        XCTAssertLessThanOrEqual(crop.left + crop.width, 1179, cropProbe.label)
        XCTAssertLessThanOrEqual(crop.top + crop.height, 2556, cropProbe.label)
        XCTAssertGreaterThan(crop.zoom, 1.01, cropProbe.label)
        XCTAssertTrue(abs(crop.offsetX) > 1 || abs(crop.offsetY) > 1, cropProbe.label)
    }

    func testNearTopAiButtonRespondsAndSecondTapDoesNotCrash() throws {
        let app = try launchZoomFixture(aiStub: true)

        try askAboutBubble(app: app, textContains: "日本語")
        let firstAnswer = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "UI1OK")).firstMatch
        XCTAssertTrue(firstAnswer.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "bold")).firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "**bold**")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Meaning")).firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Japanese")).firstMatch.waitForExistence(timeout: 3))
        dismissAiPopup(app)

        try askAboutBubble(app: app, textContains: "二回目")
        let secondAnswer = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "UI2OK")).firstMatch
        XCTAssertTrue(secondAnswer.waitForExistence(timeout: 3))
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Regression: long-pressing a word in the AI reply (the natural "select / look this up"
    /// gesture) must not crash the app. Textual's own selection bridge trapped with "Index out
    /// of range" under UIKit's edit menu (gonzalezreal/textual#87), so selection is off and the
    /// header offers "Copy reply" instead.
    func testLongPressOnTranslationWordDoesNotCrash() throws {
        let app = try launchZoomFixture(aiStub: true)

        try askAboutBubble(app: app, textContains: "日本語")
        let answer = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "UI1OK")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 3))

        // Long-press inside the first paragraph of the reply.
        answer.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).press(forDuration: 1.5)
        sleep(2)
        XCTAssertEqual(app.state, .runningForeground, "app crashed after long-pressing the reply paragraph")

        // And inside a table cell (a different Textual block).
        let cell = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Japanese")).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 3))
        cell.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).press(forDuration: 1.5)
        sleep(2)
        XCTAssertEqual(app.state, .runningForeground, "app crashed after long-pressing a table cell")

        // The popup is still up with its reply and offers "Copy reply" in place of selection.
        // (The pasteboard itself isn't read back here: doing so from the runner trips iOS's
        // paste-permission prompt and stalls the run.)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "UI1OK")).firstMatch.exists)
        let copy = app.buttons["Copy reply"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 3))
        XCTAssertTrue(copy.isHittable)
        copy.tap()
        XCTAssertEqual(app.state, .runningForeground)
        saveScreenshot(app, name: "ai-popup-after-long-press")
    }

    /// Regression: browsing a large chat history (many screenshot entries, plus one entry with a
    /// corrupt out-of-range timestamp as a hostile sync writer could produce) must neither trap in
    /// `AiChatEntry.id` (Int64 conversion, SyncCore) nor balloon memory by decoding every
    /// screenshot at full resolution. Requires the stress log:
    /// `python3 tools/seed_zoom_fixture.py <container> --stress-chat-log --poison-timestamp`.
    func testHistoryWithManyScreenshotsAndPoisonedTimestampSurvives() throws {
        let app = try launchZoomFixture(aiStub: true)

        app.buttons["manga-options-menu"].firstMatch.tap()
        let historyItem = app.buttons["Chat history"].firstMatch
        XCTAssertTrue(historyItem.waitForExistence(timeout: 3))
        historyItem.tap()

        let marker = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "STRESS_LOG")).firstMatch
        guard marker.waitForExistence(timeout: 5) else {
            XCTAssertEqual(app.state, .runningForeground, "app crashed opening chat history")
            throw ProbeError("Requires the stress chat log — seed with tools/seed_zoom_fixture.py --stress-chat-log --poison-timestamp")
        }

        // Scroll through the list so many screenshot rows come on screen, then linger so the
        // driving script can sample the app's memory footprint.
        let card = app.scrollViews.firstMatch
        for _ in 0..<6 {
            card.swipeUp()
        }
        sleep(6)
        XCTAssertEqual(app.state, .runningForeground, "app crashed while browsing screenshot-heavy history")
        saveScreenshot(app, name: "ai-history-stress")
    }

    /// Attaches a full-screen screenshot to the test result (kept even when the test passes).
    private func saveScreenshot(_ app: XCUIApplication, name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        if name.hasPrefix("reader-") {
            let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("build/cards-screenshots/" + UIDevice.current.name.replacingOccurrences(of: " ", with: "-"))
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: directory.appendingPathComponent(name + ".png"))
        }
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launchZoomFixture(aiStub: Bool = false, showCopy: Bool = true, syntheticFixture: Bool = false, chromeFixture: Bool = false, textSizePreview: Bool = false, lookupFixture: Bool = false) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HOSHI_UI_TESTING"] = "1"
        app.launchArguments += ["-mangaShowCopyButton", showCopy ? "YES" : "NO"]
        if syntheticFixture {
            app.launchEnvironment["HOSHI_UI_TESTING_ZOOM"] = "1"
            app.launchArguments += ["-mangaSingleTapLookup", "NO", "-mangaShowFurigana", textSizePreview ? "YES" : "NO"]
        }
        if chromeFixture { app.launchEnvironment["HOSHI_UI_TESTING_CHROME"] = "1" }
        if textSizePreview { app.launchEnvironment["HOSHI_UI_TESTING_TEXT_SIZE"] = "1" }
        if lookupFixture { app.launchEnvironment["HOSHI_UI_TESTING_MANGA_LOOKUP"] = "1" }
        if aiStub {
            app.launchEnvironment["HOSHI_UI_TESTING_AI_STUB"] = "1"
        }
        app.launch()
        XCUIDevice.shared.orientation = .portrait

        let fixture = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "IDB Zoom Fixture")).firstMatch
        guard fixture.waitForExistence(timeout: 5) else {
            throw ProbeError("Requires IDB Zoom Fixture seeded into the app container.")
        }
        let openingStarted = ProcessInfo.processInfo.systemUptime
        fixture.tap()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.exists)
        let ready = app.descendants(matching: .any)["manga-action-layout-probe"].firstMatch
        XCTAssertTrue(waitForActionProbe(ready, timeout: 10), ready.label)
        print("Synthetic manga tap-to-page-ready through UI automation: \(ProcessInfo.processInfo.systemUptime - openingStarted) seconds")
        let probe = app.descendants(matching: .any)["manga-viewport-probe"].firstMatch
        if probe.waitForExistence(timeout: 5), !probe.label.contains("page=1;") {
            app.buttons["manga-options-menu"].tap()
            app.buttons["Go to page"].tap()
            let field = app.textFields.firstMatch
            field.tap()
            let oldValue = field.value as? String ?? ""
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: oldValue.count) + "1")
            app.buttons["manga-go-to-page-confirm"].tap()
            XCTAssertTrue(waitForViewport(probe, containing: "page=1;zoom=1.000"), probe.label)
        }
        return app
    }

    private func askAboutBubble(app: XCUIApplication, textContains: String) throws {
        let box = app.switches.matching(NSPredicate(format: "label CONTAINS %@", textContains)).firstMatch
        XCTAssertTrue(box.waitForExistence(timeout: 5))
        box.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        tapAiButton(app: app, boxFrame: box.frame)
    }

    private func tapActionButton(
        app: XCUIApplication,
        textContains: String,
        accessibilityLabel: String,
        probe: ActionProbe? = nil
    ) throws {
        let box = app.switches.matching(NSPredicate(format: "label CONTAINS %@", textContains)).firstMatch
        XCTAssertTrue(box.waitForExistence(timeout: 5))
        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 3))
        let boxFrame = probe?.box.screenRect(in: webView.frame) ?? box.frame
        let tapPoint = hitSlopPoint(for: boxFrame, in: webView.frame)
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: tapPoint.x, dy: tapPoint.y))
            .tap()

        if let probe {
            let actionRect = accessibilityLabel.contains("Copy") ? probe.copy : probe.ai
            let actionFrame = actionRect.screenRect(in: webView.frame)
            let actionPoint = CGPoint(x: actionFrame.midX, y: actionFrame.midY)
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: actionPoint.x, dy: actionPoint.y))
                .tap()
            return
        }

        let button = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", accessibilityLabel, textContains)
        ).firstMatch
        let didFindButton = button.waitForExistence(timeout: 3)
        XCTAssertTrue(
            didFindButton,
            "\(accessibilityLabel) for \(textContains) not found; tap=\(tapPoint), boxFrame=\(boxFrame), probe=\(String(describing: probe))"
        )
        XCTAssertTrue(button.isHittable, "\(accessibilityLabel) is not hittable for \(textContains), frame=\(button.frame)")
        button.tap()
    }

    private func hitSlopPoint(for boxFrame: CGRect, in webViewFrame: CGRect) -> CGPoint {
        let horizontalNudge: CGFloat
        if boxFrame.width < 8 {
            horizontalNudge = boxFrame.midX > webViewFrame.midX ? -6 : 6
        } else {
            horizontalNudge = 0
        }
        let verticalNudge: CGFloat
        if boxFrame.height < 8 {
            verticalNudge = boxFrame.midY > webViewFrame.midY ? -6 : 6
        } else {
            verticalNudge = 0
        }
        let x = min(webViewFrame.maxX - 2, max(webViewFrame.minX + 2, boxFrame.midX + horizontalNudge))
        let y = min(webViewFrame.maxY - 2, max(webViewFrame.minY + 2, boxFrame.midY + verticalNudge))
        return CGPoint(x: x, y: y)
    }

    private func tapAiButton(app: XCUIApplication, boxFrame: CGRect) {
        let aiButton = app.buttons["Ask about this bubble"].firstMatch
        if aiButton.waitForExistence(timeout: 1) {
            XCTAssertGreaterThanOrEqual(aiButton.frame.minY, 64)
            XCTAssertLessThanOrEqual(aiButton.frame.maxX, app.frame.maxX)
            aiButton.tap()
            return
        }

        let x: CGFloat
        if boxFrame.minY < 128 {
            x = min(app.frame.maxX - 12, boxFrame.maxX - 12)
        } else {
            x = min(app.frame.maxX - 12, boxFrame.minX + min(82, max(44, boxFrame.width * 0.24)))
        }
        let y: CGFloat
        if boxFrame.minY < 128 {
            y = min(app.frame.maxY - 12, max(96, boxFrame.maxY + 28))
        } else {
            y = max(64, boxFrame.minY - 12)
        }
        XCTAssertGreaterThanOrEqual(y, 64)
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: x, dy: y))
            .tap()
    }

    private func dismissAiPopup(_ app: XCUIApplication) {
        let close = app.buttons["Close translation"].firstMatch
        if close.waitForExistence(timeout: 1) {
            close.tap()
            XCTAssertTrue(close.waitForNonExistence(timeout: 3))
            return
        }
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 20, dy: app.frame.midY))
            .tap()
    }

    private func parseSelectionProbe(_ label: String) throws -> SelectionProbe {
        let parts = labelParts(label)
        guard let text = parts["text"],
              let x = parts["x"].flatMap(Double.init),
              let y = parts["y"].flatMap(Double.init),
              let width = parts["width"].flatMap(Double.init),
              let height = parts["height"].flatMap(Double.init),
              let zoom = parts["zoom"].flatMap(Double.init) else {
            throw ProbeError("Malformed selection probe: \(label)")
        }
        return SelectionProbe(text: text, x: x, y: y, width: width, height: height, zoom: zoom)
    }

    private func parseCropProbe(_ label: String) throws -> CropProbe {
        let parts = labelParts(label)
        guard let mime = parts["mime"],
              let base64Length = parts["base64"].flatMap(Int.init),
              let left = parts["left"].flatMap(Int.init),
              let top = parts["top"].flatMap(Int.init),
              let width = parts["width"].flatMap(Int.init),
              let height = parts["height"].flatMap(Int.init),
              let page = parts["page"].flatMap(Int.init),
              let zoom = parts["zoom"].flatMap(Double.init),
              let offsetX = parts["offsetX"].flatMap(Double.init),
              let offsetY = parts["offsetY"].flatMap(Double.init) else {
            throw ProbeError("Malformed crop probe: \(label)")
        }
        return CropProbe(
            mime: mime,
            base64Length: base64Length,
            left: left,
            top: top,
            width: width,
            height: height,
            page: page,
            zoom: zoom,
            offsetX: offsetX,
            offsetY: offsetY
        )
    }

    private func waitForActionProbe(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.label.hasPrefix("[") { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    private func waitForCopyProbe(_ element: XCUIElement, expected: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.label == expected { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    private func parseActionProbe(_ label: String) throws -> [ActionProbe] {
        guard let data = label.data(using: .utf8) else {
            throw ProbeError("Malformed action probe: \(label)")
        }
        do {
            return try JSONDecoder().decode([ActionProbe].self, from: data)
        } catch {
            throw ProbeError("Malformed action probe: \(label), error=\(error)")
        }
    }

    private func actionProbe(_ probes: [ActionProbe], containing text: String) throws -> ActionProbe {
        guard let probe = probes.first(where: { $0.text.contains(text) }) else {
            throw ProbeError("Missing action probe containing \(text)")
        }
        return probe
    }

    private func assertVisible(_ rect: ActionRect, id: String, webViewFrame: CGRect, topInset: Double) {
        XCTAssertGreaterThan(rect.width, 0, id)
        XCTAssertGreaterThan(rect.height, 0, id)
        XCTAssertGreaterThanOrEqual(rect.x, 0, id)
        XCTAssertGreaterThanOrEqual(rect.y, topInset, id)
        XCTAssertLessThanOrEqual(rect.x + rect.width, Double(webViewFrame.width), id)
        XCTAssertLessThanOrEqual(rect.y + rect.height, Double(webViewFrame.height), id)
    }

    private func assertDoesNotOverlap(_ lhs: ActionRect, _ rhs: ActionRect, id: String) {
        let tolerance = 1.0
        let overlaps = lhs.x < rhs.x + rhs.width - tolerance &&
            lhs.x + lhs.width > rhs.x + tolerance &&
            lhs.y < rhs.y + rhs.height - tolerance &&
            lhs.y + lhs.height > rhs.y + tolerance
        XCTAssertFalse(overlaps, "\(id) overlaps text: action=\(lhs), text=\(rhs)")
    }

    private func labelParts(_ label: String) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: label.split(separator: ";").compactMap { part -> (String, String)? in
                guard let equals = part.firstIndex(of: "=") else { return nil }
                return (
                    String(part[..<equals]),
                    String(part[part.index(after: equals)...])
                )
            }
        )
    }

    private func tapUntilSelectionProbeUpdates(
        app: XCUIApplication,
        boxFrame: CGRect,
        visibleBounds: CGRect,
        probe: XCUIElement,
        offsets: [CGVector] = [
            CGVector(dx: 0.75, dy: 0.18), CGVector(dx: 0.75, dy: 0.32),
            CGVector(dx: 0.75, dy: 0.46), CGVector(dx: 0.50, dy: 0.24),
            CGVector(dx: 0.50, dy: 0.40), CGVector(dx: 0.25, dy: 0.24),
            CGVector(dx: 0.25, dy: 0.40)
        ]
    ) throws -> CGPoint {
        let tappableFrame = boxFrame.intersection(visibleBounds.insetBy(dx: 8, dy: 8))
        guard !tappableFrame.isNull, tappableFrame.width > 1, tappableFrame.height > 1 else {
            throw ProbeError("Zoomed OCR box is not visible enough to tap: box=\(boxFrame), visible=\(visibleBounds)")
        }
        for offset in offsets {
            let point = CGPoint(
                x: tappableFrame.minX + tappableFrame.width * offset.dx,
                y: tappableFrame.minY + tappableFrame.height * offset.dy
            )
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: point.x, dy: point.y))
                .tap()
            if waitForSelectionProbe(probe, timeout: 0.8) {
                return point
            }
        }
        throw ProbeError("Selection probe did not update after tapping zoomed OCR box: \(probe.label)")
    }

    private func visibleSwitchFrame(app: XCUIApplication, textContains: String, in webView: XCUIElement) throws -> CGRect {
        let visibleBounds = webView.frame.insetBy(dx: 8, dy: 8)
        for _ in 0..<4 {
            if let frame = app.switches
                .matching(NSPredicate(format: "label CONTAINS %@", textContains))
                .allElementsBoundByIndex
                .map(\.frame)
                .first(where: { frame in
                    frame.width > 1 && frame.height > 1 && frame.intersects(visibleBounds)
                }) {
                return frame
            }

            let panStart = webView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.32))
            let panEnd = webView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
            panStart.press(forDuration: 0.1, thenDragTo: panEnd)
            sleep(1)
        }
        throw ProbeError("No visible zoomed OCR box containing \(textContains)")
    }

    private func waitForCropProbe(_ probe: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if probe.label.contains("mime=image/png") {
                return true
            }
            usleep(100_000)
        }
        return false
    }

    private func waitForSelectionProbe(_ probe: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if probe.label.contains("text=") {
                return true
            }
            usleep(100_000)
        }
        return false
    }

    private func waitForSelectionProbe(_ probe: XCUIElement, containing text: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if probe.label.contains("text=\(text)") || probe.label.contains(text) {
                return true
            }
            usleep(100_000)
        }
        return false
    }

    private struct ProbeError: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) {
            self.description = description
        }
    }

    private struct SelectionProbe {
        let text: String
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        let zoom: Double

        var midX: Double { x + width / 2 }
        var midY: Double { y + height / 2 }
    }

    private struct CropProbe {
        let mime: String
        let base64Length: Int
        let left: Int
        let top: Int
        let width: Int
        let height: Int
        let page: Int
        let zoom: Double
        let offsetX: Double
        let offsetY: Double
    }

    private struct ActionProbe: Decodable {
        let id: String
        let text: String
        let box: ActionRect
        let textRect: ActionRect
        let textRects: [ActionRect]
        let ai: ActionRect
        let copy: ActionRect
        let placement: String
        let topInset: Double
    }

    private struct ActionRect: Decodable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        func screenRect(in webViewFrame: CGRect) -> CGRect {
            CGRect(
                x: webViewFrame.minX + x,
                y: webViewFrame.minY + y,
                width: width,
                height: height
            )
        }
    }
}
