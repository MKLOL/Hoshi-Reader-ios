import CoreGraphics
import Foundation

@main
struct MangaViewportGestureMathTest {
    private static var failures = 0

    private static func check(_ name: String, _ condition: Bool) {
        print("\(condition ? "PASS" : "FAIL")  \(name)")
        if !condition { failures += 1 }
    }

    private static func close(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
        abs(lhs - rhs) < 0.0001
    }

    static func main() {
        let start = CGPoint(x: 100, y: 80)
        let panned = MangaViewportGestureMath.panOffset(
            currentOffset: start,
            translationDelta: CGPoint(x: 20, y: -10)
        )
        check("trackpad content follows two-finger translation",
              close(panned.x, 80) && close(panned.y, 90))

        var panThenZoom = MangaIndirectPinchTransform(
            currentOffset: start,
            scale: 2,
            anchor: CGPoint(x: 50, y: 40)
        )
        panThenZoom.addPanTranslation(CGPoint(x: 20, y: -10))
        panThenZoom.setScaleFactor(1.5)
        let panThenZoomOffset = panThenZoom.offset(atScale: panThenZoom.unclampedScale)

        var zoomThenPan = MangaIndirectPinchTransform(
            currentOffset: start,
            scale: 2,
            anchor: CGPoint(x: 50, y: 40)
        )
        zoomThenPan.setScaleFactor(1.5)
        zoomThenPan.addPanTranslation(CGPoint(x: 20, y: -10))
        let zoomThenPanOffset = zoomThenPan.offset(atScale: zoomThenPan.unclampedScale)
        check("trackpad scroll-first and transform-first callback order is identical",
              close(panThenZoomOffset.x, zoomThenPanOffset.x) &&
              close(panThenZoomOffset.y, zoomThenPanOffset.y))
        check("combined trackpad transform preserves both scale and movement",
              close(panThenZoomOffset.x, 155) && close(panThenZoomOffset.y, 150))

        var liveLocationTransform = MangaIndirectPinchTransform(
            currentOffset: start,
            scale: 2,
            anchor: CGPoint(x: 50, y: 40)
        )
        liveLocationTransform.setScaleFactor(1.5)
        liveLocationTransform.setCurrentAnchor(CGPoint(x: 70, y: 30))
        let liveLocationOffset = liveLocationTransform.offset(
            atScale: liveLocationTransform.unclampedScale
        )
        check("trackpad pinch location moves viewport without a pan callback",
              close(liveLocationOffset.x, 155) && close(liveLocationOffset.y, 150))

        liveLocationTransform.addPanTranslation(CGPoint(x: 20, y: -10))
        let duplicateSignalsOffset = liveLocationTransform.offset(
            atScale: liveLocationTransform.unclampedScale
        )
        check("duplicate pinch-location and pan signals are not added twice",
              close(duplicateSignalsOffset.x, 155) && close(duplicateSignalsOffset.y, 150))

        var preRecognitionPan = MangaIndirectPinchTransform(
            currentOffset: start,
            scale: 2,
            anchor: CGPoint(x: 50, y: 40),
            initialPanTranslation: CGPoint(x: 20, y: -10)
        )
        preRecognitionPan.setScaleFactor(1.5)
        let preRecognitionOffset = preRecognitionPan.offset(atScale: preRecognitionPan.unclampedScale)
        check("pan arriving before pinch recognition is not dropped",
              close(preRecognitionOffset.x, 155) && close(preRecognitionOffset.y, 150))

        let movedTouchMidpoint = MangaViewportGestureMath.zoomOffset(
            currentOffset: CGPoint(x: 100, y: 100),
            oldScale: 2,
            newScale: 2,
            previousAnchor: CGPoint(x: 50, y: 50),
            currentAnchor: CGPoint(x: 70, y: 80)
        )
        check("touch midpoint movement pans while scale is unchanged",
              close(movedTouchMidpoint.x, 80) && close(movedTouchMidpoint.y, 70))

        let anchored = MangaViewportGestureMath.zoomOffset(
            currentOffset: CGPoint(x: 40, y: 60),
            oldScale: 1,
            newScale: 2,
            previousAnchor: CGPoint(x: 100, y: 120),
            currentAnchor: CGPoint(x: 100, y: 120)
        )
        check("stationary pinch preserves the content point beneath its anchor",
              close((anchored.x + 100) / 2, 140) &&
              close((anchored.y + 120) / 2, 180))

        print(failures == 0 ? "\nALL VIEWPORT GESTURE TESTS PASSED" :
              "\n\(failures) TEST(S) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
