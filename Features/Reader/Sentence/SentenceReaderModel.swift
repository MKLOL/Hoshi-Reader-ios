//
//  SentenceReaderModel.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  The book as sentence mode sees it, and the rules for moving through it. Ported from Android's
//  features/reader/sentence/SentenceReaderModel.kt so both platforms count sentences and chapters
//  the same way.
//

import Foundation

/// One chapter of a book as sentence mode sees it. An unreadable chapter (a nav document, a
/// missing file) has no sentences but keeps its index, so a reader bookmark still maps onto it.
nonisolated struct SentenceChapter: Sendable {
    /// Index into the spine — the same index the reader's bookmark uses.
    let chapterIndex: Int
    let title: String?
    let sentences: [ReaderSentence]
}

nonisolated struct SentenceBook: Sendable {
    let chapters: [SentenceChapter]

    var totalSentences: Int { chapters.reduce(0) { $0 + $1.sentences.count } }
    var readableChapterCount: Int { chapters.count { !$0.sentences.isEmpty } }

    func sentence(at position: SentencePosition) -> ReaderSentence? {
        guard chapters.indices.contains(position.chapter) else { return nil }
        let sentences = chapters[position.chapter].sentences
        guard sentences.indices.contains(position.sentence) else { return nil }
        return sentences[position.sentence]
    }

    /// 1-based index of `position` across the whole book, for the "12 / 240" counter.
    func ordinal(of position: SentencePosition) -> Int {
        let upTo = min(max(position.chapter, 0), chapters.count)
        let before = chapters.prefix(upTo).reduce(0) { $0 + $1.sentences.count }
        return before + position.sentence + 1
    }

    /// 1-based number of the readable chapter containing `position`, for "Chapter 3 of 12".
    func readableChapterOrdinal(of position: SentencePosition) -> Int {
        chapters.prefix(position.chapter + 1).count { !$0.sentences.isEmpty }
    }
}

nonisolated struct SentencePosition: Codable, Equatable, Sendable {
    let chapter: Int
    let sentence: Int
}

/// The reader's bookmark, reduced to what sentence mode needs. `Bookmark` itself is main-actor
/// isolated by the project default, and this navigation is pure logic that runs off it.
nonisolated struct SentenceBookmarkAnchor: Sendable {
    let chapterIndex: Int
    /// 0…1 through the chapter.
    let progress: Double
}

/// Moves one sentence at a time across chapter boundaries, skipping chapters with no text.
nonisolated enum SentenceNavigation {
    static func next(in book: SentenceBook, from position: SentencePosition) -> SentencePosition? {
        guard book.chapters.indices.contains(position.chapter) else {
            return position.chapter < 0 ? first(in: book) : nil
        }
        let current = book.chapters[position.chapter]
        if position.sentence + 1 < current.sentences.count {
            return SentencePosition(chapter: position.chapter, sentence: position.sentence + 1)
        }
        for index in (position.chapter + 1)..<book.chapters.count where !book.chapters[index].sentences.isEmpty {
            return SentencePosition(chapter: index, sentence: 0)
        }
        return nil
    }

    static func previous(in book: SentenceBook, from position: SentencePosition) -> SentencePosition? {
        if position.sentence > 0, book.chapters.indices.contains(position.chapter) {
            let last = book.chapters[position.chapter].sentences.count - 1
            return SentencePosition(chapter: position.chapter, sentence: min(position.sentence - 1, last))
        }
        var index = min(position.chapter - 1, book.chapters.count - 1)
        while index >= 0 {
            let sentences = book.chapters[index].sentences
            if !sentences.isEmpty {
                return SentencePosition(chapter: index, sentence: sentences.count - 1)
            }
            index -= 1
        }
        return nil
    }

    static func first(in book: SentenceBook) -> SentencePosition? {
        guard let index = book.chapters.firstIndex(where: { !$0.sentences.isEmpty }) else { return nil }
        return SentencePosition(chapter: index, sentence: 0)
    }

    /// A position that exists in `book`, or nil when the book has no text at all.
    static func clamp(_ position: SentencePosition, in book: SentenceBook) -> SentencePosition? {
        if book.chapters.indices.contains(position.chapter), !book.chapters[position.chapter].sentences.isEmpty {
            let last = book.chapters[position.chapter].sentences.count - 1
            return SentencePosition(chapter: position.chapter, sentence: min(max(position.sentence, 0), last))
        }
        // The chapter is empty or gone: take the next chapter with text, else the previous one.
        let probe = SentencePosition(chapter: position.chapter, sentence: Int.max - 1)
        return next(in: book, from: probe) ?? previous(in: book, from: position)
    }

    /// Where to start: the position sentence mode saved, else the reader's bookmark mapped onto
    /// its chapter (progress becomes a sentence index), else the first sentence.
    static func initialPosition(
        in book: SentenceBook,
        saved: SentencePosition?,
        bookmark: SentenceBookmarkAnchor?
    ) -> SentencePosition? {
        if let saved, let clamped = clamp(saved, in: book) { return clamped }
        if let bookmark {
            if book.chapters.indices.contains(bookmark.chapterIndex),
               !book.chapters[bookmark.chapterIndex].sentences.isEmpty {
                let sentences = book.chapters[bookmark.chapterIndex].sentences
                let progress = min(max(bookmark.progress, 0), 1)
                let index = min(Int(progress * Double(sentences.count)), sentences.count - 1)
                return SentencePosition(chapter: bookmark.chapterIndex, sentence: max(index, 0))
            }
            if let clamped = clamp(SentencePosition(chapter: bookmark.chapterIndex, sentence: 0), in: book) {
                return clamped
            }
        }
        return first(in: book)
    }
}
