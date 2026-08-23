//
//  MangaViewportGestureMath.swift
//  Hoshi Reader
//
//  Pure geometry shared by direct-touch and indirect-trackpad reader gestures.
//

import CoreGraphics

/// State for an indirect pinch, rendered from one pinch-start snapshot.
///
/// iPadOS reports trackpad movement through the pinch recognizer's live location on current
/// hardware. Older event paths can also report it through a continuous-pan recognizer. Both
/// signals describe the same physical movement, so use the stronger component rather than adding
/// them and moving the viewport twice.
nonisolated struct MangaIndirectPinchTransform {
    private let startScale: CGFloat
    private let contentPoint: CGPoint
    private let startAnchor: CGPoint
    private(set) var currentAnchor: CGPoint
    private(set) var scaleFactor: CGFloat = 1
    private(set) var panTranslation: CGPoint

    init(
        currentOffset: CGPoint,
        scale: CGFloat,
        anchor: CGPoint,
        initialPanTranslation: CGPoint = .zero
    ) {
        let safeScale = max(scale, 0.001)
        self.startScale = safeScale
        self.contentPoint = CGPoint(
            x: (anchor.x + currentOffset.x) / safeScale,
            y: (anchor.y + currentOffset.y) / safeScale
        )
        self.startAnchor = anchor
        self.currentAnchor = anchor
        self.panTranslation = initialPanTranslation
    }

    var unclampedScale: CGFloat {
        startScale * scaleFactor
    }

    mutating func setScaleFactor(_ scaleFactor: CGFloat) {
        self.scaleFactor = scaleFactor
    }

    mutating func setCurrentAnchor(_ anchor: CGPoint) {
        currentAnchor = anchor
    }

    mutating func addPanTranslation(_ delta: CGPoint) {
        panTranslation = CGPoint(
            x: panTranslation.x + delta.x,
            y: panTranslation.y + delta.y
        )
    }

    func offset(atScale scale: CGFloat) -> CGPoint {
        let locationTranslation = CGPoint(
            x: currentAnchor.x - startAnchor.x,
            y: currentAnchor.y - startAnchor.y
        )
        let effectiveTranslation = CGPoint(
            x: abs(locationTranslation.x) >= abs(panTranslation.x)
                ? locationTranslation.x
                : panTranslation.x,
            y: abs(locationTranslation.y) >= abs(panTranslation.y)
                ? locationTranslation.y
                : panTranslation.y
        )
        let effectiveAnchor = CGPoint(
            x: startAnchor.x + effectiveTranslation.x,
            y: startAnchor.y + effectiveTranslation.y
        )
        return CGPoint(
            x: contentPoint.x * scale - effectiveAnchor.x,
            y: contentPoint.y * scale - effectiveAnchor.y
        )
    }
}

nonisolated enum MangaViewportGestureMath {
    /// Applies one incremental pinch update. `previousAnchor` and `currentAnchor` may differ for a
    /// moving touch midpoint; for a trackpad transform they remain at the pointer while its separate
    /// pan recognizer composes translation against the resulting current offset.
    static func zoomOffset(
        currentOffset: CGPoint,
        oldScale: CGFloat,
        newScale: CGFloat,
        previousAnchor: CGPoint,
        currentAnchor: CGPoint
    ) -> CGPoint {
        let safeOldScale = max(oldScale, 0.001)
        let contentPoint = CGPoint(
            x: (previousAnchor.x + currentOffset.x) / safeOldScale,
            y: (previousAnchor.y + currentOffset.y) / safeOldScale
        )
        return CGPoint(
            x: contentPoint.x * newScale - currentAnchor.x,
            y: contentPoint.y * newScale - currentAnchor.y
        )
    }

    /// UIKit pan translation follows the fingers, while UIScrollView content offset moves in the
    /// opposite direction.
    static func panOffset(currentOffset: CGPoint, translationDelta: CGPoint) -> CGPoint {
        CGPoint(
            x: currentOffset.x - translationDelta.x,
            y: currentOffset.y - translationDelta.y
        )
    }
}
