import Foundation

nonisolated struct MangaTextSlider: Decodable, Sendable {
    let min: Int
    let max: Int
    let step: Int

    var sliderRange: ClosedRange<Double> { Double(min)...Double(max) }

    func clamp(_ value: Int) -> Int {
        Swift.min(max, Swift.max(min, value))
    }
}

nonisolated struct MangaTextPreset: Decodable, Sendable {
    let id: String
    let amount: Int
    let threshold: Int
}

nonisolated struct MangaTextConfiguration: Decodable, Sendable {
    let amount: MangaTextSlider
    let threshold: MangaTextSlider
    let presets: [MangaTextPreset]
}

/// Image-pixel settings: page fitting and zoom scale the original and enlarged text together.
nonisolated struct MangaTextEnlargement: Codable, Hashable, Sendable {
    static let configuration: MangaTextConfiguration = {
        do {
            let response = try HoshiCore.call("manga.text-config", payload: [:])
            let data = try JSONSerialization.data(withJSONObject: response)
            return try JSONDecoder().decode(MangaTextConfiguration.self, from: data)
        } catch {
            preconditionFailure("Could not read shared manga text configuration: \(error)")
        }
    }()
    static let defaults = configuration.presets.first { $0.id == "balanced" }!

    var enabled = true
    /// Percentage of the gap between the original glyph height and the cutoff to fill.
    var amount = Self.defaults.amount
    var threshold = Self.defaults.threshold

    var normalized: Self {
        Self(enabled: enabled, amount: Self.configuration.amount.clamp(amount),
             threshold: Self.configuration.threshold.clamp(threshold))
    }

    func fontSizes(originals: [Int]) -> [Int] {
        guard !originals.isEmpty else { return [] }
        let payload: [String: Any] = [
            "originals": originals, "enabled": enabled, "amount": amount, "threshold": threshold,
        ]
        let sizes = (try? HoshiCore.call("manga.text-sizes", payload: payload)) as? [Int]
        return sizes.flatMap { $0.count == originals.count ? $0 : nil } ?? originals.map { max(1, $0) }
    }

    func fontSize(original: Int) -> Int {
        fontSizes(originals: [original])[0]
    }
}
