import Foundation

/// Nil fields retain the host's responsive defaults; editing one control never freezes the others.
public struct PopupCardStyle: Codable, Equatable, Sendable {
    public var width: Double?
    public var height: Double?
    public var scale: Double?
    public var fontScale: Double?

    public init(width: Double? = nil, height: Double? = nil, scale: Double? = nil, fontScale: Double? = nil) {
        self.width = width; self.height = height; self.scale = scale; self.fontScale = fontScale
    }
    public var normalized: Self {
        func value(_ x: Double?, _ range: ClosedRange<Double>) -> Double? {
            guard let x, x.isFinite else { return nil }
            return min(range.upperBound, max(range.lowerBound, x))
        }
        return Self(width: value(width, 160...1600), height: value(height, 120...2000),
                    scale: value(scale, 0.5...3), fontScale: value(fontScale, 0.5...3))
    }
    public func size(defaults: CGSize, available: CGSize, margin: CGFloat = 0) -> CGSize {
        let safe = normalized
        return CGSize(width: max(1, min(safe.width ?? defaults.width, available.width - margin * 2)),
                      height: max(1, min(safe.height ?? defaults.height, available.height - margin * 2)))
    }
}
