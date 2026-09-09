//
//  NewsPipelineTests.swift
//  HoshiReaderTests
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Unit coverage for the News tab's pure logic: RSS parsing, the XHTML sanitizer, the article
//  EPUB writer (parsed back with the real EPUBKit), the batch prompt parser, the runner and the
//  sentence-translation blob against the reader's own validation and lookup.
//

import EPUBKit
import XCTest
@testable import Hoshi_Reader

nonisolated final class NewsPipelineTests: XCTestCase {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("news-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sentence(_ start: Int, _ text: String) -> ReaderSentence {
        ReaderSentence(spine: 0, start: start, length: text.count, text: text, paragraph: 0)
    }

    // MARK: RSS

    func testRssItemsParseWithCdataEntitiesAndRfc1123Dates() {
        let feed = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/"><channel><title>Watanoc</title>
        <item>
          <title>肉玉そばを食べるなら29日&#8230;(n4)</title>
          <link>https://watanoc.com/post-1610-nikutama</link>
          <pubDate>Mon, 08 Sep 2025 09:15:00 +0000</pubDate>
          <description><![CDATA[<p>東京の<b>お店</b> &amp; 29日</p><img src="https://watanoc.com/a.jpg" />]]></description>
        </item>
        <item><title>No link</title></item>
        </channel></rss>
        """
        let items = RssFeedParser.parse(feed)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "肉玉そばを食べるなら29日…(n4)")
        XCTAssertEqual(items[0].url, "https://watanoc.com/post-1610-nikutama")
        XCTAssertEqual(items[0].publishedAt, 1_757_322_900_000)
        XCTAssertEqual(items[0].summary, "東京の お店 & 29日")
        XCTAssertEqual(items[0].imageUrl, "https://watanoc.com/a.jpg")
    }

    func testAtomEntriesPreferAlternateLinksAndParseIsoDates() {
        let feed = """
        <feed xmlns="http://www.w3.org/2005/Atom"><entry>
          <title type="html">やさしい&lt;ニュース&gt;</title>
          <link rel="replies" href="https://example.jp/a/1#comments"/>
          <link rel="alternate" href="https://example.jp/a/1"/>
          <published>2026-09-08T10:00:00+09:00</published>
          <summary>要約です。</summary>
        </entry></feed>
        """
        let items = RssFeedParser.parse(feed)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].url, "https://example.jp/a/1")
        XCTAssertEqual(items[0].title, "やさしい<ニュース>")
        XCTAssertEqual(items[0].publishedAt, 1_788_829_200_000)
        XCTAssertEqual(items[0].summary, "要約です。")
    }

    func testMediaCaptionsDoNotOverwriteTheArticleTitleOrSummary() {
        let feed = """
        <rss xmlns:media="http://search.yahoo.com/mrss/"><channel><item>
          <title>本物の見出し</title>
          <link>https://example.jp/a</link>
          <description>本文の要約。</description>
          <media:content url="https://example.jp/img.jpg" type="image/jpeg">
            <media:title>写真のキャプション</media:title>
            <media:description>撮影者</media:description>
          </media:content>
        </item></channel></rss>
        """
        let item = RssFeedParser.parse(feed).first
        XCTAssertEqual(item?.title, "本物の見出し")
        XCTAssertEqual(item?.summary, "本文の要約。")
        XCTAssertEqual(item?.imageUrl, "https://example.jp/img.jpg")
    }

    func testMalformedFeedsYieldNoItems() {
        XCTAssertTrue(RssFeedParser.parse("<html><body>not a feed</body></html>").isEmpty)
        XCTAssertTrue(RssFeedParser.parse("<rss><channel><item><title>x").isEmpty)
        XCTAssertTrue(RssFeedParser.parse("").isEmpty)
    }

    // MARK: Sanitizer

    func testSanitizerKeepsRubyAndImagesAndDropsScriptsAttributesAndEmptyBlocks() throws {
        let input = """
        <div xmlns="http://www.w3.org/1999/xhtml" class="article-body" onclick="x()">
          <script>alert(1)</script>
          <p style="color:red"><ruby>東京<rt>とうきょう</rt></ruby>で<a href="https://x">雨</a>が<span>降りました</span>。</p>
          <nav><a href="/">home</a></nav>
          <figure><img src="https://example.jp/a.jpg" alt="写真" width="100"/><figcaption>写真です</figcaption></figure>
          <p></p><div><div></div></div>
          <img src="javascript:alert(1)"/>
        </div>
        """
        let output = try XCTUnwrap(NewsArticleXhtml.sanitize(input))
        XCTAssertTrue(output.contains("<p><ruby>東京<rt>とうきょう</rt></ruby>で雨が降りました。</p>"), output)
        XCTAssertTrue(output.contains("<img alt=\"写真\" src=\"https://example.jp/a.jpg\"/>"), output)
        XCTAssertTrue(output.contains("<figcaption>写真です</figcaption>"), output)
        for forbidden in ["script", "home", "onclick", "href", "width", "javascript", "<p></p>", "<div>"] {
            XCTAssertFalse(output.contains(forbidden), "\(forbidden) leaked: \(output)")
        }
        // Allowed elements inside unwrapped wrappers must survive (NHK/MATCHA wrap ruby in spans).
        let nested = try XCTUnwrap(NewsArticleXhtml.sanitize("<section><p><span><ruby>東京<rt>と</rt></ruby></span>で<a href=\"x\"><strong>雨</strong></a>。</p></section>"))
        XCTAssertEqual(nested, "<p><ruby>東京<rt>と</rt></ruby>で<strong>雨</strong>。</p>")
        // Plain-http images are rewritten to https so the reader (ATS) can load them.
        let upgraded = try XCTUnwrap(NewsArticleXhtml.sanitize("<p><img src=\"http://example.jp/a.jpg\" alt=\"x\"/>本文</p>"))
        XCTAssertTrue(upgraded.contains("src=\"https://example.jp/a.jpg\""), upgraded)
        XCTAssertNil(NewsArticleXhtml.sanitize("<div><p>unclosed"))
        XCTAssertNil(NewsArticleXhtml.sanitize("<div><nav>x</nav><p>  </p></div>"))
        XCTAssertEqual(NewsArticleXhtml.paragraphs(fromText: "一行目 <b>\n\n  二行目 & 三\n"), "<p>一行目 &lt;b&gt;</p>\n<p>二行目 &amp; 三</p>")
    }

    // MARK: EPUB writer + reader consumption

    private func writeArticle(to root: URL, body: String = "<p><ruby>東京<rt>とうきょう</rt></ruby>で雨が降りました。</p><p>二つ目の文です。三つ目！</p>") throws {
        try NewsArticleEpubWriter.write(to: root, input: NewsArticleEpubWriter.Input(
            title: "雨 & <大雨>", bodyXhtml: body, sourceName: "Source", sourceUrl: "https://s/1",
            publishedAt: 1_757_298_000_000, cover: Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 16, 74, 70, 73, 70, 0, 1, 1])
        ))
    }

    func testWrittenArticleParsesAsSingleChapterEpubAndSegmentsLikeAnyChapter() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeArticle(to: root)

        let document = try EPUBParser().parse(documentAt: root)
        XCTAssertEqual(document.title, "雨 & <大雨>")
        XCTAssertEqual(document.spine.items.count, 1)
        XCTAssertTrue(document.manifest.items.values.contains { $0.property?.contains("cover-image") == true })
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("OEBPS/content.opf"), encoding: .utf8).contains("<dc:date>2025-09-08</dc:date>"))

        let html = try String(contentsOf: root.appendingPathComponent("OEBPS/article.xhtml"), encoding: .utf8)
        let sentences = EpubSentenceSegmenter.segment(spine: 0, html: html)
        XCTAssertEqual(sentences.map(\.text), ["雨 & <大雨>", "Source · 2025-09-08", "東京で雨が降りました。", "二つ目の文です。", "三つ目！"])
        XCTAssertEqual(sentences.first?.id, "c0s0")
    }

    func testCoverTypeIsSniffedFromMagicBytes() {
        XCTAssertEqual(NewsArticleEpubWriter.imageType(Data([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0, 0, 0, 0, 0]))?.mediaType, "image/png")
        XCTAssertEqual(NewsArticleEpubWriter.imageType(Data("RIFF....WEBP".utf8))?.fileExtension, "webp")
        XCTAssertNil(NewsArticleEpubWriter.imageType(Data("not an image".utf8)))
    }

    func testSentenceBlobPassesTheReaderValidationAndMatchesTheSegmenterAddresses() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeArticle(to: root)
        let config = PretranslationConfig(engine: .cloud(modelId: "gpt-4o-mini"))
        let plan = try PretranslationPlanner.plan(bookId: UUID(), syncId: "rain-sync", bookRoot: root, config: config)
        XCTAssertEqual(plan.spineCount, 1)
        XCTAssertEqual(plan.sentences.count, 5)
        XCTAssertNotNil(plan.estimate.costUsd)

        let translations = Dictionary(uniqueKeysWithValues: plan.sentences.map { ($0.id, SentenceTranslationResult(sentenceId: $0.id, translation: "EN \($0.text)", explanation: "note")) })
        let blob = SentenceTranslationsWriter.buildBlob(plan: plan, translations: translations, model: "gpt-4o-mini", promptId: SentenceBatchPrompt.promptId(includeExplanations: true))
        XCTAssertNil(SentenceTranslationsWriter.validationError(blob))
        XCTAssertEqual(blob.entries.count, 5)
        for (id, entry) in blob.entries { XCTAssertEqual(id, "c\(entry.spine)s\(entry.start)") }

        let data = try SentenceTranslationsWriter.encode(blob)
        try SentenceTranslationsWriter.write(data, bookRoot: root)
        let decoded = try JSONDecoder().decode(HttpSyncSentencesBlob.self, from: data)
        XCTAssertNil(decoded.validationError(expectedSyncId: "rain-sync", spineCount: 1))

        let rain = try XCTUnwrap(plan.sentences.first { $0.text.hasPrefix("東京") })
        let entry = try XCTUnwrap(decoded.entries[rain.id])
        XCTAssertEqual(entry.hash, EpubTranslationStore.textHash(EpubTranslationStore.normalize(rain.text)))
        XCTAssertEqual(entry.translation, "EN 東京で雨が降りました。")
        XCTAssertEqual(entry.len, EpubTranslationStore.normalize(rain.text).unicodeScalars.count)
        // Wire format shared with the Python tool and the Android app.
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["version", "kind", "syncId", "title", "model", "promptId", "generatedAt", "spineCount", "entries"])
        XCTAssertEqual(Set((try XCTUnwrap((json["entries"] as? [String: Any])?[rain.id] as? [String: Any])).keys), ["spine", "start", "len", "text", "hash", "translation", "explanation"])
        XCTAssertNotNil(blob.generatedAt.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$"#, options: .regularExpression))

        // Reuse honors model + prompt; another configuration counts as foreign.
        XCTAssertEqual(SentenceTranslationsWriter.existingTranslations(bookRoot: root, plan: plan, model: "gpt-4o-mini", promptId: SentenceBatchPrompt.promptId(includeExplanations: true)).count, 5)
        XCTAssertTrue(SentenceTranslationsWriter.existingTranslations(bookRoot: root, plan: plan, model: "other", promptId: "p").isEmpty)
        XCTAssertTrue(SentenceTranslationsWriter.hasSidecarForOtherConfiguration(bookRoot: root, syncId: "rain-sync", model: "other", promptId: "p"))
        XCTAssertFalse(SentenceTranslationsWriter.hasSidecarForOtherConfiguration(bookRoot: root, syncId: "rain-sync", model: "gpt-4o-mini", promptId: SentenceBatchPrompt.promptId(includeExplanations: true)))
    }

    // MARK: Prompt parsing

    func testBatchParsingToleratesFencesTruncationReasoningAndWrappedArrays() {
        let fenced = """
        Sure!
        ```json
        [{"id":"c0s0","translation":"It rained.","explanation":"雨 = rain"},{"id":"c0s0","translation":"dup"},{"id":"c0s99","translation":"x"},{"id":"c0s6","translation":"  "}]
        ```
        """
        let parsed = SentenceBatchPrompt.parseBatch(fenced, expectedIds: ["c0s0", "c0s6"])
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed["c0s0"], SentenceTranslationResult(sentenceId: "c0s0", translation: "It rained.", explanation: "雨 = rain"))

        let truncated = #"[{"id":"c0s0","translation":"One.","explanation":""},{"id":"c0s6","translation":"Two."},{"id":"c0s12","translation":"Thr"#
        XCTAssertEqual(Set(SentenceBatchPrompt.parseBatch(truncated, expectedIds: ["c0s0", "c0s6", "c0s12"]).keys), ["c0s0", "c0s6"])

        let wrapped = #"<think>Let me [consider]</think>{"items":[{"id":" c0s0 ","translation":"One."}]}"#
        XCTAssertEqual(SentenceBatchPrompt.parseBatch(wrapped, expectedIds: ["c0s0"])["c0s0"]?.translation, "One.")
        XCTAssertTrue(SentenceBatchPrompt.parseBatch("I cannot help.", expectedIds: ["c0s0"]).isEmpty)

        XCTAssertNil(SentenceBatchPrompt.parseSingle(#"{"translation": "It rai"#, sentenceId: "c0s0"))
        XCTAssertEqual(SentenceBatchPrompt.parseSingle("<think>hmm</think>It rained.", sentenceId: "c0s0"), SentenceTranslationResult(sentenceId: "c0s0", translation: "It rained."))
        XCTAssertEqual(SentenceBatchPrompt.promptId(includeExplanations: true).count, "sha256:".count + 32)
        XCTAssertNotEqual(SentenceBatchPrompt.promptId(includeExplanations: true), SentenceBatchPrompt.promptId(includeExplanations: false))
    }

    // MARK: Runner

    private struct FakeTranslator: SentenceTranslating {
        var supportsBatches: Bool = true
        var batch: @Sendable ([ReaderSentence]) throws -> [String: SentenceTranslationResult] = { batch in
            Dictionary(uniqueKeysWithValues: batch.map { ($0.id, SentenceTranslationResult(sentenceId: $0.id, translation: "T")) })
        }
        var single: @Sendable (ReaderSentence) throws -> SentenceTranslationResult? = { SentenceTranslationResult(sentenceId: $0.id, translation: "S") }
        let calls = Calls()

        final class Calls: @unchecked Sendable {
            let lock = NSLock()
            var batches: [[String]] = []
            var singles: [String] = []
        }

        func translateBatch(_ sentences: [ReaderSentence], includeExplanations: Bool) async throws -> [String: SentenceTranslationResult] {
            calls.lock.withLock { calls.batches.append(sentences.map(\.id)) }
            return try batch(sentences)
        }

        func translateOne(_ sentence: ReaderSentence, includeExplanations: Bool) async throws -> SentenceTranslationResult? {
            calls.lock.withLock { calls.singles.append(sentence.id) }
            return try single(sentence)
        }
    }

    private struct Boom: Error {}

    func testRunnerChunksBatchesRetriesMissingItemsSinglyAndHalvesEmptyReplies() async throws {
        let sentences = (0..<5).map { sentence($0 * 10, "文\($0)。") }
        let dropFirst = FakeTranslator(batch: { batch in Dictionary(uniqueKeysWithValues: batch.dropFirst().map { ($0.id, SentenceTranslationResult(sentenceId: $0.id, translation: "T")) }) })
        let result = try await PretranslationRunner(translator: dropFirst, config: PretranslationConfig(engine: .cloud(modelId: "m"), sentencesPerRequest: 2)).run(sentences: sentences, sink: PretranslationSink())
        XCTAssertEqual(dropFirst.calls.batches, [["c0s0", "c0s10"], ["c0s20", "c0s30"], ["c0s40"]])
        XCTAssertEqual(dropFirst.calls.singles, ["c0s0", "c0s20", "c0s40"])
        XCTAssertEqual(Set(result.keys), Set(sentences.map(\.id)))

        let emptyLarge = FakeTranslator(batch: { batch in
            batch.count > 2 ? [:] : Dictionary(uniqueKeysWithValues: batch.map { ($0.id, SentenceTranslationResult(sentenceId: $0.id, translation: "T")) })
        })
        let halved = try await PretranslationRunner(translator: emptyLarge, config: PretranslationConfig(engine: .cloud(modelId: "m"), sentencesPerRequest: 4)).run(sentences: Array(sentences.prefix(4)), sink: PretranslationSink())
        XCTAssertEqual(emptyLarge.calls.batches.map(\.count), [4, 2, 2])
        XCTAssertTrue(emptyLarge.calls.singles.isEmpty)
        XCTAssertEqual(halved.count, 4)
    }

    func testRerunWhereEveryNewRequestFailsIsNotReportedAsSuccess() async {
        let sentences = (0..<3).map { sentence($0 * 10, "文\($0)。") }
        let dead = FakeTranslator(supportsBatches: false, single: { _ in throw Boom() })
        let existing = ["c0s0": SentenceTranslationResult(sentenceId: "c0s0", translation: "old")]
        do {
            _ = try await PretranslationRunner(translator: dead, config: PretranslationConfig(engine: .cloud(modelId: "m")), maxFailedRequests: 6).run(sentences: sentences, existing: existing, sink: PretranslationSink())
            XCTFail("two failed requests within budget and no new sentence must not count as success")
        } catch is PretranslationTooManyFailures {
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(PretranslationConfig(engine: .cloud(modelId: "claude-haiku-4-5")).withEffectiveBatchSize().sentencesPerRequest, PretranslationConfig.anthropicSentencesPerRequest)
        XCTAssertEqual(PretranslationConfig(engine: .cloud(modelId: "gpt-4o-mini")).withEffectiveBatchSize().sentencesPerRequest, PretranslationConfig.defaultSentencesPerRequest)
        XCTAssertEqual(PretranslationConfig(engine: .cloud(modelId: "claude-haiku-4-5"), sentencesPerRequest: 3).withEffectiveBatchSize().sentencesPerRequest, 3)
    }

    func testRunnerKeepsPartialResultsInTheSinkWhenItGivesUp() async {
        let sentences = (0..<5).map { sentence($0 * 10, "文\($0)。") }
        let counter = FakeTranslator.Calls()
        let flaky = FakeTranslator(supportsBatches: false, single: { s in
            let n = counter.lock.withLock { counter.singles.count }
            counter.lock.withLock { counter.singles.append(s.id) }
            if n < 2 { return SentenceTranslationResult(sentenceId: s.id, translation: "ok") }
            throw Boom()
        })
        let sink = PretranslationSink()
        do {
            _ = try await PretranslationRunner(translator: flaky, config: PretranslationConfig(engine: .cloud(modelId: "m")), maxFailedRequests: 1).run(sentences: sentences, sink: sink)
            XCTFail("expected failure")
        } catch is PretranslationTooManyFailures {
            XCTAssertEqual(Set(sink.snapshot.keys), ["c0s0", "c0s10"])
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: Shared URLs and settings

    @MainActor
    func testSharedUrlExtractionAndSourceAttribution() {
        XCTAssertEqual(NewsSharedUrl.extract("由布院温泉 https://matcha-jp.com/easy/10505 via MATCHA"), "https://matcha-jp.com/easy/10505")
        XCTAssertEqual(NewsSharedUrl.extract("https://news.web.nhk/news/easy/ne1/ne1.html."), "https://news.web.nhk/news/easy/ne1/ne1.html")
        XCTAssertNil(NewsSharedUrl.extract("ただの文章です。"))
        XCTAssertEqual(NewsSourceCatalog.source(forUrl: "https://matcha-jp.com/easy/10505").id, NewsSourceCatalog.matchaEasyId)
        XCTAssertEqual(NewsSourceCatalog.source(forUrl: "https://example.jp/x").id, NewsSourceCatalog.sharedLinkId)
        let folder = NewsBookImporter.folderName(title: "雨/晴れ: 😀 title", url: "https://s/1")
        XCTAssertTrue(folder.hasSuffix("-\(sha256Hex("https://s/1").prefix(8))"), folder)
        XCTAssertTrue(folder.hasPrefix("雨_晴れ__😀_title-"), folder)
        XCTAssertEqual(NewsBookImporter.folderName(title: String(repeating: "あ", count: 80), url: "u").unicodeScalars.count, 60 + 9)
    }

    @MainActor
    func testGeoRestrictedBuiltInStartsDisabledUntilSwitchedOn() {
        let defaults = UserDefaults(suiteName: "news-tests-\(UUID().uuidString)")!
        let settings = NewsSettingsStore(defaults: defaults)
        XCTAssertFalse(settings.isEnabled(NewsSourceCatalog.nhkEasy))
        XCTAssertTrue(settings.isEnabled(NewsSourceCatalog.watanoc))
        settings.setEnabled(true, source: NewsSourceCatalog.nhkEasy)
        XCTAssertTrue(settings.isEnabled(NewsSourceCatalog.nhkEasy))
        settings.setEnabled(false, source: NewsSourceCatalog.watanoc)
        XCTAssertFalse(settings.isEnabled(NewsSourceCatalog.watanoc))
        let custom = settings.addCustomRss(name: "", url: " https://example.jp/feed ")
        XCTAssertEqual(custom.name, "https://example.jp/feed")
        XCTAssertEqual(settings.customSources.count, 1)
        settings.removeCustomSource(custom)
        XCTAssertTrue(settings.customSources.isEmpty)
    }

    func testFeedStoreReplacesPerSourceAndRoundTripsSavedRecords() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = NewsFeedStore(directory: dir)
        func article(_ source: String, _ url: String, _ published: Int64?) -> NewsArticle {
            NewsArticle(id: NewsArticle.id(for: url), sourceId: source, url: url, title: url, publishedAt: published, fetchedAt: 1000)
        }
        store.replaceSourceArticles(sourceId: "a", articles: [article("a", "https://a/1", 10), article("a", "https://a/2", 30)], refreshedAt: 5)
        store.replaceSourceArticles(sourceId: "b", articles: [article("b", "https://b/1", 20)], refreshedAt: 6)
        XCTAssertEqual(store.loadArticles().map(\.url), ["https://a/2", "https://b/1", "https://a/1"])
        store.replaceSourceArticles(sourceId: "a", articles: [article("a", "https://a/3", 40)], refreshedAt: 7)
        XCTAssertEqual(store.loadArticles().map(\.url), ["https://a/3", "https://b/1"])
        XCTAssertEqual(store.refreshedAt(), ["a": 7, "b": 6])

        let saved = SavedNewsArticle(articleId: "id1", bookId: UUID(), sourceId: "a", url: "https://a/1", title: "T", savedAt: 9)
        store.upsertSaved(saved)
        XCTAssertEqual(store.saved(articleId: "id1"), saved)
        store.updateSaved(articleId: "id1") { var s = $0; s.translation = NewsTranslationRecord(model: "m", sentenceCount: 3, translatedCount: 3, completedAt: 10, uploaded: true); return s }
        XCTAssertEqual(store.saved(articleId: "id1")?.translation?.model, "m")
        store.removeSaved(articleId: "id1")
        XCTAssertNil(store.saved(articleId: "id1"))
    }
}
