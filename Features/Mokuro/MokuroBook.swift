//
//  MokuroBook.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Parsed representation of a mokuro manga volume. Produced by `MokuroBookParser` from the
/// `mokuro.json` sidecar in a book directory and consumed by the manga reader.
///
/// The manga counterpart of an EPUB document. It deliberately stays a plain, reader-agnostic
/// model so the manga reader can render it however it likes (currently a `WKWebView` of
/// absolutely-positioned, selectable OCR text boxes).
nonisolated struct MokuroBook: Equatable {
    let title: String
    let pages: [MokuroPage]
    /// Book-root-relative path of the image used as the bookshelf cover, if any.
    let coverImagePath: String?
}

/// A single manga page: one background image plus its OCR text-box overlays.
nonisolated struct MokuroPage: Codable, Equatable {
    /// Zero-based page index within the volume. Doubles as the reader's bookmark position.
    let index: Int
    /// Book-root-relative path to the page image.
    let imagePath: String
    let imageWidth: Int
    let imageHeight: Int
    let textBoxes: [MokuroTextBox]
}

/// One OCR text region, positioned in image-pixel coordinates relative to the page image.
/// The manga reader scales these to the rendered page size.
nonisolated struct MokuroTextBox: Codable, Equatable {
    let left: Int
    let top: Int
    let width: Int
    let height: Int
    let fontSize: Int
    /// True for vertical (top-to-bottom, right-to-left) Japanese text; false for horizontal.
    let vertical: Bool
    /// OCR lines; for vertical text each entry is one column, ordered right-to-left.
    let lines: [String]
    /// This block's index in the source `mokuro.json` page, NOT its position in `textBoxes`.
    /// Blocks with an unusable box are dropped during parsing, so the two diverge — and the
    /// offline pre-translation cache addresses bubbles by the mokuro index, which every platform
    /// and the desktop tool agree on. Defaults to 0 for older decoded data.
    var blockIndex: Int = 0

    enum CodingKeys: String, CodingKey {
        case left, top, width, height, fontSize, vertical, lines, blockIndex
    }

    init(left: Int, top: Int, width: Int, height: Int, fontSize: Int, vertical: Bool,
         lines: [String], blockIndex: Int = 0) {
        self.left = left
        self.top = top
        self.width = width
        self.height = height
        self.fontSize = fontSize
        self.vertical = vertical
        self.lines = lines
        self.blockIndex = blockIndex
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        left = try c.decode(Int.self, forKey: .left)
        top = try c.decode(Int.self, forKey: .top)
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height)
        fontSize = try c.decode(Int.self, forKey: .fontSize)
        vertical = try c.decode(Bool.self, forKey: .vertical)
        lines = try c.decodeIfPresent([String].self, forKey: .lines) ?? []
        blockIndex = try c.decodeIfPresent(Int.self, forKey: .blockIndex) ?? 0
    }
}
