import XCTest

final class ZoomPopupUITests: XCTestCase {
    func testUltraThinActionButtonsStayVisibleAndTappable() throws {
        let app = try launchZoomFixture(aiStub: true)
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
        let app = try launchZoomFixture()

        let japaneseBox = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "日本語")).firstMatch
        XCTAssertTrue(japaneseBox.waitForExistence(timeout: 5))
        let initialFrame = japaneseBox.frame
        japaneseBox.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(1)

        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 3))
        webView.pinch(withScale: 1.6, velocity: 1.0)
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
            probe: probe
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

    /// Attaches a full-screen screenshot to the test result (kept even when the test passes).
    private func saveScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launchZoomFixture(aiStub: Bool = false) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HOSHI_UI_TESTING"] = "1"
        if aiStub {
            app.launchEnvironment["HOSHI_UI_TESTING_AI_STUB"] = "1"
        }
        app.launch()

        let fixture = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "IDB Zoom Fixture")).firstMatch
        guard fixture.waitForExistence(timeout: 5) else {
            throw ProbeError("Requires IDB Zoom Fixture seeded into the app container.")
        }
        fixture.tap()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 6))
        sleep(2)
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
            let label = element.label
            if label.hasPrefix("[") { return true }
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
        probe: XCUIElement
    ) throws -> CGPoint {
        let tappableFrame = boxFrame.intersection(visibleBounds.insetBy(dx: 8, dy: 8))
        guard !tappableFrame.isNull, tappableFrame.width > 1, tappableFrame.height > 1 else {
            throw ProbeError("Zoomed OCR box is not visible enough to tap: box=\(boxFrame), visible=\(visibleBounds)")
        }
        let offsets = [
            CGVector(dx: 0.75, dy: 0.18),
            CGVector(dx: 0.75, dy: 0.32),
            CGVector(dx: 0.75, dy: 0.46),
            CGVector(dx: 0.50, dy: 0.24),
            CGVector(dx: 0.50, dy: 0.40),
            CGVector(dx: 0.25, dy: 0.24),
            CGVector(dx: 0.25, dy: 0.40),
        ]

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
