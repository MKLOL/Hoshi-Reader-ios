import XCTest
import UIKit
@testable import Hoshi_Reader

nonisolated final class LookupOutsideTouchTests: XCTestCase {
    @MainActor func testPopupTouchesPassThroughAndOutsideTouchConsumesUntilEnd() {
        let view = LookupOutsideTouchView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        view.lookupIsActive = true
        view.popupBounds = [CGRect(x: 30, y: 200, width: 300, height: 250)]
        XCTAssertNil(view.hitTest(CGPoint(x: 100, y: 250), with: nil), "definition controls and scrolling stay interactive")
        XCTAssertTrue(view.hitTest(CGPoint(x: 100, y: 60), with: nil) === view, "reader chrome is protected")
        var dismissed = 0
        view.dismissLookup = { dismissed += 1; view.lookupIsActive = false }
        view.beginOutsideTouch()
        XCTAssertEqual(dismissed, 1)
        XCTAssertTrue(view.consumesStream)
        XCTAssertTrue(view.hitTest(CGPoint(x: 100, y: 250), with: nil) === view, "removing a popup cannot expose controls during the original stream")
        view.beginOutsideTouch()
        XCTAssertEqual(dismissed, 1, "additional fingers do not dismiss again")
        view.endOutsideTouch()
        XCTAssertNil(view.hitTest(CGPoint(x: 100, y: 60), with: nil), "the next tap can act normally")
    }

    @MainActor func testBoundsAccountForReaderChromeAndRecursiveCards() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 900))
        let view = LookupOutsideTouchView(frame: CGRect(x: 0, y: 70, width: 400, height: 800))
        window.addSubview(view)
        view.lookupIsActive = true
        view.popupBounds = [CGRect(x: 20, y: 270, width: 150, height: 200), CGRect(x: 180, y: 400, width: 200, height: 200)]
        XCTAssertNil(view.hitTest(CGPoint(x: 30, y: 210), with: nil))
        XCTAssertNil(view.hitTest(CGPoint(x: 190, y: 340), with: nil))
        XCTAssertTrue(view.hitTest(CGPoint(x: 190, y: 210), with: nil) === view)
    }

    @MainActor func testPendingLookupWithoutCardConsumesOutsideTouch() {
        let view = LookupOutsideTouchView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        view.lookupIsActive = true
        XCTAssertTrue(view.hitTest(CGPoint(x: 5, y: 5), with: nil) === view)
        XCTAssertNil(view.hitTest(CGPoint(x: -5, y: 5), with: nil))
        view.lookupIsActive = false
        XCTAssertNil(view.hitTest(CGPoint(x: 5, y: 5), with: nil))
    }
}
