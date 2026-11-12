import XCTest
import CoreGraphics
@testable import Hoshi_Reader

nonisolated final class PopupCardStyleTests: XCTestCase {
    @MainActor func testMangaDictionaryUsesTheOppositeSideFromTheActionRow() {
        let bubble = CGRect(x: 230, y: 280, width: 140, height: 120)
        let cases: [(MangaLookupAction.Side, CGRect, (CGRect) -> Bool)] = [
            (.above, CGRect(x: 270, y: 242, width: 60, height: 26), { $0.minY > bubble.maxY }),
            (.below, CGRect(x: 270, y: 412, width: 60, height: 26), { $0.maxY < bubble.minY }),
            (.left, CGRect(x: 158, y: 315, width: 60, height: 26), { $0.minX > bubble.maxX }),
            (.right, CGRect(x: 382, y: 315, width: 60, height: 26), { $0.maxX < bubble.minX }),
        ]
        for (side, toolbar, onOppositeSide) in cases {
            let layout = PopupLayout(selectionRect: bubble, screenSize: CGSize(width: 600, height: 800),
                                     maxWidth: 240, maxHeight: 230, isVertical: true, isFullWidth: false,
                                     mangaAction: MangaLookupAction(side: side, frame: toolbar))
            XCTAssertTrue(onOppositeSide(layout.frame), "Toolbar is \(side)")
            XCTAssertFalse(layout.frame.intersects(toolbar))
        }
    }

    @MainActor func testMangaFullWidthAndZoomedLayoutsKeepTheActionRowClear() {
        let screen = CGSize(width: 390, height: 390)
        let bubble = CGRect(x: 100, y: 120, width: 180, height: 220)
        let below = MangaLookupAction(side: .below, frame: CGRect(x: 158, y: 350, width: 64, height: 26))
        let full = PopupLayout(selectionRect: bubble, screenSize: screen, maxWidth: 250, maxHeight: 150,
                               isVertical: false, isFullWidth: true, mangaAction: below).frame
        XCTAssertEqual(full.width, screen.width - 12)
        XCTAssertLessThan(full.maxY, bubble.minY)
        XCTAssertFalse(full.intersects(below.frame))

        let edgeBubble = CGRect(x: -12, y: 30, width: 435, height: 360)
        let above = MangaLookupAction(side: .above, frame: CGRect(x: 145, y: 21, width: 95, height: 42))
        let zoomed = PopupLayout(selectionRect: edgeBubble, screenSize: screen, maxWidth: 250, maxHeight: 150,
                                 isVertical: true, isFullWidth: false, topInset: 20, bottomInset: 10,
                                 mangaAction: above).frame
        XCTAssertGreaterThan(zoomed.minY, above.frame.maxY)
        XCTAssertGreaterThanOrEqual(zoomed.height, 96)
        XCTAssertFalse(zoomed.intersects(above.frame))
        XCTAssertTrue(CGRect(x: 6, y: 26, width: 378, height: 348).contains(zoomed))
    }

    @MainActor func testUnsetControlsKeepResponsiveDefaultsAndOverridesStayInsideViewport() throws {
        let style = PopupCardStyle(fontScale: 1.5)
        XCTAssertEqual(style.size(defaults: CGSize(width: 240, height: 330), available: CGSize(width: 1032, height: 1376)), CGSize(width: 240, height: 330))
        XCTAssertNil(style.width)
        let bounded = PopupCardStyle(width: 900, height: 1500).size(defaults: .zero, available: CGSize(width: 402, height: 874), margin: 16)
        XCTAssertEqual(bounded, CGSize(width: 370, height: 842))
        XCTAssertEqual(try JSONDecoder().decode(PopupCardStyle.self, from: JSONEncoder().encode(style)), style)
    }
    @MainActor func testTranslationDefaultsStayResponsiveAcrossPhoneAndTabletViewports() {
        let phone = CGSize(width: 402, height: 874)
        let phoneDefaults = PopupCardGeometry.translationDefaults(in: phone, isPad: false)
        XCTAssertEqual(phoneDefaults.width, 520)
        XCTAssertEqual(phoneDefaults.height, phone.height * 0.78, accuracy: 0.001)
        let phoneCard = PopupCardStyle().size(defaults: phoneDefaults, available: phone, margin: 16)
        XCTAssertEqual(phoneCard.width, 370)
        XCTAssertEqual(phoneCard.height, phoneDefaults.height, accuracy: 0.001)

        let tablet = CGSize(width: 1032, height: 1376)
        let tabletDefaults = PopupCardGeometry.translationDefaults(in: tablet, isPad: true)
        XCTAssertEqual(tabletDefaults.width, 680)
        XCTAssertEqual(tabletDefaults.height, tablet.height * 0.84, accuracy: 0.001)
        let tabletCard = PopupCardStyle().size(defaults: tabletDefaults, available: tablet, margin: 36)
        XCTAssertEqual(tabletCard, tabletDefaults)
    }
    @MainActor func testTranslationCardsClampSmallWindowsAndAllowExplicitSizes() {
        // Landscape and split-view can be smaller than the responsive minimum height.
        for (viewport, isPad, margin) in [(CGSize(width: 300, height: 200), false, CGFloat(16)),
                                          (CGSize(width: 320, height: 400), true, CGFloat(36))] {
            let defaults = PopupCardGeometry.translationDefaults(in: viewport, isPad: isPad)
            let card = PopupCardStyle().size(defaults: defaults, available: viewport, margin: margin)
            XCTAssertGreaterThan(card.width, 0)
            XCTAssertGreaterThan(card.height, 0)
            XCTAssertLessThanOrEqual(card.width, viewport.width - 2 * margin)
            XCTAssertLessThanOrEqual(card.height, viewport.height - 2 * margin)
        }
        let viewport = CGSize(width: 1032, height: 1376)
        let defaults = PopupCardGeometry.translationDefaults(in: viewport, isPad: true)
        let chosen = PopupCardStyle(width: 300, height: 240).size(defaults: defaults, available: viewport, margin: 36)
        XCTAssertEqual(chosen, CGSize(width: 300, height: 240), "An explicit size overrides the responsive floor.")
        let oversized = PopupCardStyle(width: 1600, height: 2000).size(defaults: defaults, available: viewport, margin: 36)
        XCTAssertEqual(oversized, CGSize(width: 960, height: 1304))
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
