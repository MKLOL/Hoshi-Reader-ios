import CoreGraphics

/// A visible OCR action row in the same viewport coordinates as the selection.
struct MangaLookupAction {
    enum Side: String, CaseIterable {
        case above, below, left, right

        var opposite: Self {
            switch self {
            case .above: .below
            case .below: .above
            case .left: .right
            case .right: .left
            }
        }

        func space(around anchor: CGRect, within bounds: CGRect) -> CGRect {
            switch self {
            case .above:
                CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width,
                       height: max(0, min(bounds.maxY, anchor.minY) - bounds.minY))
            case .below:
                CGRect(x: bounds.minX, y: max(bounds.minY, anchor.maxY), width: bounds.width,
                       height: max(0, bounds.maxY - max(bounds.minY, anchor.maxY)))
            case .left:
                CGRect(x: bounds.minX, y: bounds.minY, width: max(0, min(bounds.maxX, anchor.minX) - bounds.minX),
                       height: bounds.height)
            case .right:
                CGRect(x: max(bounds.minX, anchor.maxX), y: bounds.minY,
                       width: max(0, bounds.maxX - max(bounds.minX, anchor.maxX)), height: bounds.height)
            }
        }
    }

    let side: Side
    let frame: CGRect

    func popupFrame(around selection: CGRect, within bounds: CGRect, size: CGSize, gap: CGFloat, fullWidth: Bool) -> CGRect? {
        guard !bounds.isEmpty, frame.intersects(bounds) else { return nil }
        let actions = frame.insetBy(dx: -gap, dy: -gap)
        let bubble = selection.insetBy(dx: -gap, dy: -gap)
        let opposite = side.opposite
        let minimumWidth = min(size.width, 120)
        let minimumHeight = min(size.height, 96)

        func popup(on side: Side, around anchor: CGRect) -> CGRect? {
            let space = side.space(around: anchor, within: bounds)
            let width = min(size.width, space.width), height = min(size.height, space.height)
            guard width > 0, height > 0 else { return nil }
            let alignedX = max(space.minX, min(selection.minX, space.maxX - width))
            let alignedY = max(space.minY, min(selection.minY, space.maxY - height))
            return CGRect(x: side == .left ? space.maxX - width : side == .right ? space.minX : alignedX,
                          y: side == .above ? space.maxY - height : side == .below ? space.minY : alignedY,
                          width: width, height: height)
        }

        func readable(_ popup: CGRect) -> Bool { popup.width >= minimumWidth && popup.height >= minimumHeight }
        func area(_ popup: CGRect) -> CGFloat { popup.width * popup.height }

        let protectedBubble = actions.union(bubble)
        // A full-width card beside a left or right toolbar can keep its width in a vertical lane.
        if fullWidth && (side == .left || side == .right),
           let full = [Side.below, .above].compactMap({ popup(on: $0, around: protectedBubble) })
            .first(where: readable) { return full }
        if let preferred = popup(on: opposite, around: protectedBubble), readable(preferred) { return preferred }
        let otherSides = Side.allCases.filter { $0 != side && $0 != opposite }
        if let alternate = otherSides.compactMap({ popup(on: $0, around: protectedBubble) })
            .filter(readable).max(by: { area($0) < area($1) }) { return alternate }

        // A zoomed or edge-to-edge bubble can leave no readable gap around its text.
        // Keep the toolbar clear even when the card must use some of the artwork.
        if let preferred = popup(on: opposite, around: actions), readable(preferred) { return preferred }
        return Side.allCases.compactMap { popup(on: $0, around: actions) }.max { area($0) < area($1) }
    }
}
