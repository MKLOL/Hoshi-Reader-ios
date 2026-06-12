import XCTest

final class ZoomPopupUITests: XCTestCase {
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

        let zoomedFrame = japaneseBox.frame
        XCTAssertGreaterThan(zoomedFrame.width, 0)
        XCTAssertGreaterThan(zoomedFrame.height, 0)
        XCTAssertGreaterThan(initialFrame.height, 0)

        let probe = app.descendants(matching: .any)["manga-selection-probe"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 3))

        let tap = try tapUntilSelectionProbeUpdates(
            app: app,
            boxFrame: zoomedFrame,
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

    private func launchZoomFixture() throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HOSHI_UI_TESTING"] = "1"
        app.launch()

        let fixture = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "IDB Zoom Fixture")).firstMatch
        guard fixture.waitForExistence(timeout: 5) else {
            throw XCTSkip("Requires IDB Zoom Fixture seeded into the app container.")
        }
        fixture.tap()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 6))
        sleep(2)
        return app
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
        probe: XCUIElement
    ) throws -> CGPoint {
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
                x: boxFrame.minX + boxFrame.width * offset.dx,
                y: boxFrame.minY + boxFrame.height * offset.dy
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
}
