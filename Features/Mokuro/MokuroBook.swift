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
struct MokuroBook: Equatable {
    let title: String
    let pages: [MokuroPage]
    /// Book-root-relative path of the image used as the bookshelf cover, if any.
    let coverImagePath: String?
}

/// A single manga page: one background image plus its OCR text-box overlays.
struct MokuroPage: Codable, Equatable {
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
struct MokuroTextBox: Codable, Equatable {
    let left: Int
    let top: Int
    let width: Int
    let height: Int
    let fontSize: Int
    /// True for vertical (top-to-bottom, right-to-left) Japanese text; false for horizontal.
    let vertical: Bool
    /// OCR lines; for vertical text each entry is one column, ordered right-to-left.
    let lines: [String]
}
