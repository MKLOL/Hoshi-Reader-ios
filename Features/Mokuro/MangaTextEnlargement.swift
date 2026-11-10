import Foundation

/// Image-pixel settings: page fitting and zoom scale the original and enlarged text together.
nonisolated struct MangaTextEnlargement: Codable, Hashable, Sendable {
    var enabled = true
    /// Percentage of the gap between the original glyph height and the cutoff to fill.
    var amount = 50
    var threshold = 30

    var normalized: Self {
        Self(enabled: enabled, amount: min(100, max(0, amount)), threshold: min(60, max(10, threshold)))
    }

    func fontSize(original: Int) -> Int {
        let original = max(1, original)
        guard enabled else { return original }
        let settings = normalized
        return original + max(0, settings.threshold - original) * settings.amount / 100
    }
}
