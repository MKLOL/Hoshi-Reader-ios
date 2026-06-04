//
//  MokuroRaw.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Raw mokuro tool schema (mokuro >= 0.2.x) + the mapping into the reader-facing domain
//  types in MokuroBook.swift. Ported from the Android MokuroBookParser. Pure value logic
//  (no file IO) so it is unit-testable and shared by the parser and importer.
//

import Foundation

/// Top-level `mokuro.json` document. Unknown fields are ignored (Codable drops them) so newer
/// mokuro versions keep parsing; only the fields the reader needs are modelled here.
nonisolated struct RawMokuro: Decodable {
    let title: String?
    let volume: String?
    let pages: [RawMokuroPage]

    enum CodingKeys: String, CodingKey {
        case title, volume, pages
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        volume = try c.decodeIfPresent(String.self, forKey: .volume)
        pages = try c.decodeIfPresent([RawMokuroPage].self, forKey: .pages) ?? []
    }
}

nonisolated struct RawMokuroPage: Decodable {
    let imgWidth: Int
    let imgHeight: Int
    let imgPath: String
    let blocks: [RawMokuroBlock]

    enum CodingKeys: String, CodingKey {
        case imgWidth = "img_width"
        case imgHeight = "img_height"
        case imgPath = "img_path"
        case blocks
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        imgWidth = try c.decodeIfPresent(Int.self, forKey: .imgWidth) ?? 0
        imgHeight = try c.decodeIfPresent(Int.self, forKey: .imgHeight) ?? 0
        imgPath = try c.decodeIfPresent(String.self, forKey: .imgPath) ?? ""
        blocks = try c.decodeIfPresent([RawMokuroBlock].self, forKey: .blocks) ?? []
    }
}

nonisolated struct RawMokuroBlock: Decodable {
    /// `[xMin, yMin, xMax, yMax]` in image pixels.
    let box: [Double]
    let vertical: Bool
    let fontSize: Double
    let lines: [String]

    enum CodingKeys: String, CodingKey {
        case box, vertical, lines
        case fontSize = "font_size"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        box = try c.decodeIfPresent([Double].self, forKey: .box) ?? []
        vertical = try c.decodeIfPresent(Bool.self, forKey: .vertical) ?? false
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 0
        lines = try c.decodeIfPresent([String].self, forKey: .lines) ?? []
    }
}

// MARK: - Raw -> domain mapping

extension RawMokuro {
    /// Builds a `MokuroBook`. `fallbackTitle` is used when the document has no `volume`/`title`
    /// (the importer passes the book directory name). Returns `nil` if there are no pages.
    nonisolated func toMokuroBook(fallbackTitle: String) -> MokuroBook? {
        let mapped = pages.enumerated().map { index, page in page.toMokuroPage(index: index) }
        guard !mapped.isEmpty else { return nil }
        let resolvedTitle = volume?.nonBlank
            ?? title?.nonBlank
            ?? fallbackTitle
        return MokuroBook(
            title: resolvedTitle,
            pages: mapped,
            coverImagePath: mapped.first?.imagePath
        )
    }
}

extension RawMokuroPage {
    nonisolated func toMokuroPage(index: Int) -> MokuroPage {
        MokuroPage(
            index: index,
            imagePath: imgPath,
            imageWidth: imgWidth,
            imageHeight: imgHeight,
            textBoxes: blocks.compactMap { $0.toMokuroTextBox() }
        )
    }
}

extension RawMokuroBlock {
    nonisolated func toMokuroTextBox() -> MokuroTextBox? {
        guard box.count >= 4 else { return nil }
        // mokuro stores box as [xMin, yMin, xMax, yMax] in image-pixel coordinates.
        let xMin = box[0], yMin = box[1], xMax = box[2], yMax = box[3]
        let width = max(0, Int(xMax - xMin))
        let height = max(0, Int(yMax - yMin))
        return MokuroTextBox(
            left: Int(xMin),
            top: Int(yMin),
            width: width,
            height: height,
            fontSize: clampMokuroFontSize(mokuroFontSize: fontSize),
            vertical: vertical,
            lines: lines
        )
    }
}

private extension String {
    /// Kotlin `String.ifBlank { null }`: nil if empty or all-whitespace.
    nonisolated var nonBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}

// MARK: - Font-size boost curve

/// Continuous boost curve over mokuro's reported drawn-glyph height (image pixels) so the
/// OCR-text reveal stays tappable for tiny chars without ballooning the plate for already-big
/// chars:
///
///  - `result = mokuroFs + max(0, READABLE_TARGET_PX - mokuroFs) × BOOST_STRENGTH`
///  - at `mokuroFs = 30` the boost is zero (bubbles already big reveal at mokuro's size)
///  - at `mokuroFs >= 30` the boost stays zero
///
/// The result depends only on `mokuroFs` — not box size, orientation, or line count — so two
/// bubbles with the same mokuro-reported glyph height reveal at the same OCR text size. Ported
/// verbatim from the Android `clampMokuroFontSize` (READABLE_TARGET_PX = 30, BOOST_STRENGTH = 0.5).
nonisolated func clampMokuroFontSize(mokuroFontSize: Double) -> Int {
    let mokuroFs = max(1, Int(mokuroFontSize))
    let headroom = max(0.0, MokuroFontTuning.readableTargetPx - Double(mokuroFs))
    return max(1, Int(Double(mokuroFs) + headroom * MokuroFontTuning.boostStrength))
}

nonisolated enum MokuroFontTuning {
    /// Target drawn-glyph height (image pixels) considered comfortably tappable.
    static let readableTargetPx = 30.0
    static let boostStrength = 0.5
}
