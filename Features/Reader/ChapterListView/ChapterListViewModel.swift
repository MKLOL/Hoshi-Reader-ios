//
//  ChapterListViewModel.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import EPUBKit

struct ChapterRow: Identifiable {
    let id = UUID()
    let label: String
    let spineIndex: Int
    let fragment: String?
    let characterCount: Int?
    let isCurrent: Bool
    let indentLevel: Int
}

@Observable
@MainActor
class ChapterListViewModel {
    var rows: [ChapterRow] = []
    
    private let document: EPUBDocument
    private let bookInfo: BookInfo
    private let currentIndex: Int
    /// The first spine position of each chapter file. Resolving a path follows symbolic links
    /// on disk, so it is done once per chapter instead of once per contents entry and chapter.
    @ObservationIgnored private lazy var spineIndexByURL: [URL: Int] = {
        var result: [URL: Int] = [:]
        for (index, spineItem) in document.spine.items.enumerated() {
            if let manifestItem = document.manifest.items[spineItem.idref],
               let url = document.resourceURL(for: manifestItem.path), result[url] == nil { result[url] = index }
        }
        return result
    }()
    
    init(document: EPUBDocument, bookInfo: BookInfo, currentIndex: Int) {
        self.document = document
        self.bookInfo = bookInfo
        self.currentIndex = currentIndex
        
        self.rows = generateRows()
    }
    
    private func generateRows() -> [ChapterRow] {
        return flattenTOC(document.tableOfContents.subTable ?? [], indentLevel: 0)
    }
    
    private func flattenTOC(_ items: [EPUBTableOfContents], indentLevel: Int) -> [ChapterRow] {
        items.flatMap { item -> [ChapterRow] in
            let row: [ChapterRow]
            if let index = findSpineIndex(for: item) {
                let fragment = item.item.flatMap { URLComponents(string: $0)?.fragment }
                row = [ChapterRow(
                    label: item.label,
                    spineIndex: index,
                    fragment: fragment,
                    characterCount: getCharacterCount(for: item),
                    isCurrent: index == currentIndex,
                    indentLevel: indentLevel
                )]
            } else {
                row = []
            }
            return row + flattenTOC(item.subTable ?? [], indentLevel: indentLevel + 1)
        }
    }
    
    private func getCharacterCount(for item: EPUBTableOfContents) -> Int? {
        guard let index = findSpineIndex(for: item),
              let manifestItem = document.manifest.items[document.spine.items[index].idref] else {
            return nil
        }
        return bookInfo.chapterInfo[manifestItem.path]?.currentTotal
    }
    
    private func findSpineIndex(for item: EPUBTableOfContents) -> Int? {
        guard let tocPath = item.item, let target = document.resourceURL(for: tocPath) else {
            return nil
        }
        return spineIndexByURL[target]
    }
}
