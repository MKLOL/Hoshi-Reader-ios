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
    /// Per-line quadrilateral `[[x, y], ...]` in image pixels — the measured extent of each
    /// drawn line. For vertical text the quad's width is the drawn glyph size.
    let linesCoords: [[[Double]]]

    enum CodingKeys: String, CodingKey {
        case box, vertical, lines
        case fontSize = "font_size"
        case linesCoords = "lines_coords"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        box = try c.decodeIfPresent([Double].self, forKey: .box) ?? []
        vertical = try c.decodeIfPresent(Bool.self, forKey: .vertical) ?? false
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 0
        lines = try c.decodeIfPresent([String].self, forKey: .lines) ?? []
        // try? (not decodeIfPresent): a malformed lines_coords anywhere in the file must not
        // fail the whole book parse — sizing falls back to geometry/font_size instead.
        linesCoords = (try? c.decode([[[Double]]].self, forKey: .linesCoords)) ?? []
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
                lines: lines,
                linesCoords: linesCoords
            ),
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

/// Clamp a possibly-NaN / infinite / out-of-range Double (from a corrupt mokuro.json) to a sane
/// pixel Int. `Int(Double)` traps on non-finite or out-of-Int-range input, so decoded mokuro
/// values must never be passed to it raw.
nonisolated func mokuroSafeInt(_ value: Double) -> Int {
    guard value.isFinite else { return 0 }
    return Int(min(max(value, -1_000_000), 1_000_000))
}

/// The art's drawn-glyph size (image pixels) — a pure measurement, deliberately free of any
/// readability boost. Readability is a *rendered-points* property, so the zoom curve lives at
/// page-build time in `MangaPageHtml.textBoxHtml`, where the image-px → rendered-pt scale is
/// known; this function's job is only to defeat mokuro's noise.
///
/// **Measured estimate.** mokuro's reported `font_size` is noisy — for some multi-column
/// bubbles it returns the column *pitch* (spacing included), nearly 2× the drawn glyph, so two
/// bubbles whose art is the same size could reveal wildly differently. But mokuro also ships
/// `lines_coords`, the measured quadrilateral of every drawn line: for vertical text the quad's
/// width IS the drawn glyph size (CJK glyphs are ~square, one per cell); for horizontal text,
/// its height. Per-block estimate = lower-median over the lines, which discards the occasional
/// fat outlier quad (merged furigana / slanted lines — the same quads that fool mokuro's own
/// `font_size`). The measured ink is divided by `glyphInkRatio` so a font at the returned size
/// renders the same ink extent as the art (an em box pads its ink ~10%).
///
/// Fallbacks when `lines_coords` is missing/degenerate: char-count geometry
/// `min(across/lineCount, along/maxLineLen)`, then mokuro's `font_size`.
nonisolated func clampMokuroFontSize(
    mokuroFontSize: Double,
    boxWidth: Int,
    boxHeight: Int,
    vertical: Bool,
    lines: [String],
    linesCoords: [[[Double]]] = []
) -> Int {
    var estimate = max(1, mokuroSafeInt(mokuroFontSize))

    // Primary: measured per-line glyph size from lines_coords (lower-median across lines).
    var measured: [Int] = []
    for quad in linesCoords {
        let xs = quad.compactMap { $0.count >= 2 ? $0[0] : nil }.filter(\.isFinite)
        let ys = quad.compactMap { $0.count >= 2 ? $0[1] : nil }.filter(\.isFinite)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { continue }
        let size = mokuroSafeInt(vertical ? maxX - minX : maxY - minY)
        if size > 0 { measured.append(size) }
    }
    if !measured.isEmpty {
        let sorted = measured.sorted()
        // The quad measures the drawn glyphs' INK extent, but a font's em box pads its ink
        // (a 38px-ink drawn glyph needs ~font-size 42 to render the same ink). Dividing by
        // the ink ratio keeps the reveal from ever looking smaller than the art.
        estimate = max(1, Int(Double(sorted[(sorted.count - 1) / 2]) / MokuroFontTuning.glyphInkRatio))
    } else {
        // Fallback: char-count geometry. Underestimates lines holding sub-cell punctuation
        // (．．． draws as one tight run), so it only applies without measured quads.
        let lineCount = lines.count
        let maxLineLen = lines.map(\.count).max() ?? 0
        if lineCount > 0, maxLineLen > 0, boxWidth > 0, boxHeight > 0 {
            let along = vertical ? boxHeight : boxWidth
            let across = vertical ? boxWidth : boxHeight
            let geometric = min(across / lineCount, along / maxLineLen)
            if geometric > 0 {
                estimate = geometric
            }
        }
    }

    return max(1, estimate)
}

nonisolated enum MokuroFontTuning {
    /// Fraction of a CJK font's em box its ink typically fills. lines_coords quads measure the
    /// art's ink; dividing the measured size by this ratio yields the font-size whose rendered
    /// ink matches the art (font-size == ink would render visibly smaller).
    ///
    /// NOTE: the readability zoom curve intentionally does NOT live here — it operates in
    /// rendered points and lives in `MangaPageHtml` (`MangaFontTuning`), where the rendered
    /// scale is known. This diverges from Android (which boosts in image px at parse time);
    /// image-px targets are meaningless across scan resolutions, so iOS does it right.
    static let glyphInkRatio = 0.9
}
