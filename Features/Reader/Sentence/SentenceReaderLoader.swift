//
//  SentenceReaderLoader.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Turns an open EPUB into the sentence list sentence mode reads, and resolves each sentence's
//  stored pre-translation.
//
//  Split in two on purpose: the main actor walks the `EPUBDocument` (EPUBKit's model is not
//  Sendable) into plain value descriptions, and the file reads plus segmentation then happen off
//  the main actor, where a novel takes tens of milliseconds.
//

import EPUBKit
import Foundation

/// One spine slot, reduced to what segmentation needs.
nonisolated struct SentenceChapterSource: Sendable {
    let spineIndex: Int
    /// Nil for a slot with no readable document — it still occupies its index.
    let url: URL?
    /// Title from the table of contents, when the TOC names this document.
    let tocTitle: String?
}

/// Resolves a sentence's stored pre-translation, when the book has a translation blob.
nonisolated struct SentenceTranslationSource: Sendable {
    let folder: String
    let syncId: String
    let spineCount: Int

    func translation(for sentence: ReaderSentence) -> SentenceTranslation? {
        let hash = EpubTranslationStore.textHash(EpubTranslationStore.normalize(sentence.text))
        return EpubTranslationStore.shared.lookup(
            id: "\(sentence.id)#\(hash)",
            folder: folder,
            expectedSyncId: syncId,
            spineCount: spineCount
        )
    }
}

nonisolated enum SentenceReaderLoader {
    /// Every spine slot keeps its index so a reader bookmark maps onto it; a navigation document
    /// or a non-linear item is simply left empty.
    static func chapterSources(document: EPUBDocument) -> [SentenceChapterSource] {
        let titles = tocTitles(document.tableOfContents.subTable ?? [])
        let guideTocHrefs = Set(
            document.guide?.references
                .filter { $0.type.lowercased() == "toc" }
                .map { $0.href.components(separatedBy: "#").first ?? $0.href } ?? []
        )
        return document.spine.items.enumerated().map { index, item in
            guard let manifestItem = document.manifest.items[item.idref] else {
                return SentenceChapterSource(spineIndex: index, url: nil, tocTitle: nil)
            }
            let path = manifestItem.path
            let isNavigation = (manifestItem.property ?? "")
                .split(separator: " ")
                .contains("nav")
            let readable = item.linear && !isNavigation && !guideTocHrefs.contains(path)
            return SentenceChapterSource(
                spineIndex: index,
                url: readable ? document.contentDirectory.appendingPathComponent(path) : nil,
                tocTitle: tocTitle(for: path, in: titles)
            )
        }
    }

    /// Reads and segments every readable chapter. Safe to call off the main actor. Stops early
    /// once the surrounding task is cancelled; the caller discards the partial book.
    static func segment(sources: [SentenceChapterSource]) -> SentenceBook {
        SentenceBook(chapters: sources.map { source in
            guard !Task.isCancelled,
                  let url = source.url,
                  let html = try? String(contentsOf: url, encoding: .utf8) else {
                return SentenceChapter(chapterIndex: source.spineIndex, title: source.tocTitle, sentences: [])
            }
            let chapter = EpubSentenceSegmenter.chapter(spine: source.spineIndex, html: html)
            let title = source.tocTitle ?? (chapter.heading.isEmpty ? nil : chapter.heading)
            return SentenceChapter(
                chapterIndex: source.spineIndex,
                title: title,
                sentences: chapter.sentences
            )
        })
    }

    /// Flattened `(href, label)` in document order, first label wins.
    private static func tocTitles(_ items: [EPUBTableOfContents]) -> [(href: String, label: String)] {
        var out: [(href: String, label: String)] = []
        var seen: Set<String> = []
        func walk(_ item: EPUBTableOfContents) {
            if let href = item.item?.components(separatedBy: "#").first, seen.insert(href).inserted {
                out.append((href, item.label))
            }
            for child in item.subTable ?? [] { walk(child) }
        }
        for item in items { walk(item) }
        return out
    }

    /// The Chapters sheet's rule (`ChapterListViewModel.findSpineIndex`): an exact match first,
    /// otherwise the TOC path and the manifest path may differ by a leading folder.
    private static func tocTitle(for path: String, in titles: [(href: String, label: String)]) -> String? {
        if let exact = titles.first(where: { $0.href == path }) { return exact.label }
        return titles.first(where: { path.hasSuffix($0.href) || $0.href.hasSuffix(path) })?.label
    }
}
