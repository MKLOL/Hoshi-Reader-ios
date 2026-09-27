import XCTest
@testable import Hoshi_Reader

nonisolated final class PopupCardStyleTests: XCTestCase {
    @MainActor func testUnsetControlsKeepResponsiveDefaultsAndOverridesStayInsideViewport() throws {
        let style = PopupCardStyle(fontScale: 1.5)
        XCTAssertEqual(style.size(defaults: CGSize(width: 240, height: 330), available: CGSize(width: 1032, height: 1376)), CGSize(width: 240, height: 330))
        XCTAssertNil(style.width)
        let bounded = PopupCardStyle(width: 900, height: 1500).size(defaults: .zero, available: CGSize(width: 402, height: 874), margin: 16)
        XCTAssertEqual(bounded, CGSize(width: 370, height: 842))
        XCTAssertEqual(try JSONDecoder().decode(PopupCardStyle.self, from: JSONEncoder().encode(style)), style)
    }
    @MainActor func testExplicitHeightOverridesLegacyFloorWithoutChangingDefaults() {
        let base = PopupLayout(selectionRect: CGRect(x: 10, y: 10, width: 40, height: 20), screenSize: CGSize(width: 1032, height: 1376), maxWidth: 240, maxHeight: 170, isVertical: false, isFullWidth: false, preferTallPopup: true)
        XCTAssertEqual(base.width, 240)
        XCTAssertEqual(base.height, 1376 * 0.32, accuracy: 0.001)
        var explicit = base
        explicit.customHeight = true
        XCTAssertEqual(explicit.height, 170)
        XCTAssertEqual(PopupCardStyle(scale: .infinity, fontScale: 99).normalized, PopupCardStyle(fontScale: 3))
    }
}
