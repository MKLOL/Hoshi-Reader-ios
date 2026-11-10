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
        // Android's image-space font curve needs only font_size. Leave lines_coords as an
        // unknown key so opening a volume does not allocate unused per-line quadrilaterals.
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
            // enumerated() so each box remembers its ORIGINAL mokuro block index; compactMap drops
            // unusable blocks, which would otherwise silently renumber every later bubble and
            // break the offline pre-translation addresses (`p{page}b{block}`).
            textBoxes: blocks.enumerated().compactMap { $1.toMokuroTextBox(blockIndex: $0) }
        )
    }
}

extension RawMokuroBlock {
    nonisolated func toMokuroTextBox(blockIndex: Int = 0) -> MokuroTextBox? {
        guard box.count >= 4 else { return nil }
        // mokuro stores box as [xMin, yMin, xMax, yMax] in image-pixel coordinates. Corrupt files
        // can carry NaN / infinite / out-of-Int-range values, and Int(Double) traps on those, so
        // route every conversion through mokuroSafeInt (clamps to a sane pixel range).
        let xMin = mokuroSafeInt(box[0]), yMin = mokuroSafeInt(box[1])
        let xMax = mokuroSafeInt(box[2]), yMax = mokuroSafeInt(box[3])
        let width = max(0, xMax - xMin)
        let height = max(0, yMax - yMin)
        return MokuroTextBox(
            left: xMin,
            top: yMin,
            width: width,
            height: height,
            fontSize: clampMokuroFontSize(
                mokuroFontSize: fontSize,
                boxWidth: width,
                boxHeight: height,
                vertical: vertical,
                lines: lines
            ),
            vertical: vertical,
            lines: lines,
            blockIndex: blockIndex,
            originalFontSize: max(1, mokuroSafeInt(fontSize))
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

/// Clamp a possibly-NaN / infinite / out-of-range Double (from a corrupt mokuro.json) to a sane
/// pixel Int. `Int(Double)` traps on non-finite or out-of-Int-range input, so decoded mokuro
/// values must never be passed to it raw.
nonisolated func mokuroSafeInt(_ value: Double) -> Int {
    guard value.isFinite else { return 0 }
    return Int(min(max(value, -1_000_000), 1_000_000))
}

/// Match Android's image-space OCR size: small glyphs receive half the remaining headroom
/// to 30 image pixels, while glyphs at or above 30 retain their reported size. The result
/// depends only on the source glyph height, so devices, bubble geometry, and line counts
/// cannot introduce different enlargement. The original height is retained separately for
/// the Enlarge Small Text preference. Geometry arguments remain for existing callers.
nonisolated func clampMokuroFontSize(
    mokuroFontSize: Double,
    boxWidth: Int,
    boxHeight: Int,
    vertical: Bool,
    lines: [String],
    linesCoords: [[[Double]]] = []
) -> Int {
    let original = max(1, mokuroSafeInt(mokuroFontSize))
    return MangaTextEnlargement().fontSize(original: original)
}
