//
//  MangaReaderView.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  PHASE 0 CONTRACT STUB — replaced by Agent BE with the real manga reader (WKWebView OCR overlay,
//  RTL paging, zoom, screenshot crop, stats). Keep the `init(metadata:)` entry point so the
//  bookshelf routing call site stays stable.
//

import SwiftUI

struct MangaReaderView: View {
    let metadata: BookMetadata

    init(metadata: BookMetadata) {
        self.metadata = metadata
    }

    var body: some View {
        Text("Manga reader placeholder for \(metadata.title ?? "Untitled")")
            .padding()
    }
}
