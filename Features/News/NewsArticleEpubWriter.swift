//
//  NewsArticleEpubWriter.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Writes one article as an extracted EPUB directory, the same on-disk shape an imported `.epub`
//  has after EPUBKit unzips it, so the parser, reader, sync and sidecars treat it like any book.
//  EPUB 3 with an NCX alongside the navigation document (EPUBKit requires a table of contents).
//  The article body is the single spine item, so the spine count that sentence translations are
//  validated against is exactly one. Byte-compatible with the Android writer.
//

import Foundation

nonisolated enum NewsArticleEpubWriter {
    struct Input {
        let title: String
        let bodyXhtml: String
        let sourceName: String
        let sourceUrl: String
        var language: String = "ja"
        var publishedAt: Int64? = nil
        /// JPEG, PNG or WebP bytes; anything else is ignored.
        var cover: Data? = nil
        var titleXhtml: String? = nil
    }

    struct ImageType { let fileExtension: String; let mediaType: String }

    static func write(to root: URL, input: Input) throws {
        let fm = FileManager.default
        let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? input.sourceUrl : input.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier = "urn:hoshi-news:" + String(sha256Hex(input.sourceUrl).prefix(32))
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let modified = iso.string(from: Date())
        let published: String? = input.publishedAt.map { millis in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: Date(timeIntervalSince1970: Double(millis) / 1000))
        }
        let coverType = input.cover.flatMap(imageType)
        let coverName = "cover.\(coverType?.fileExtension ?? "jpg")"
        let e = NewsArticleXhtml.escape
        let upright = input.language == "ja"
        let heading = input.titleXhtml.flatMap { NewsArticleXhtml.sanitizeTitle($0, fullWidthDigits: upright) }
            ?? e(upright ? NewsArticleXhtml.uprightDigits(title) : title)

        try fm.createDirectory(at: root.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("OEBPS"), withIntermediateDirectories: true)
        try "application/epub+zip".write(to: root.appendingPathComponent("mimetype"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>

        """.write(to: root.appendingPathComponent("META-INF/container.xml"), atomically: true, encoding: .utf8)

        var opf = ""
        opf += "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        opf += "<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"pub-id\" xml:lang=\"\(input.language)\">\n"
        opf += "  <metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\">\n"
        opf += "    <dc:identifier id=\"pub-id\">\(identifier)</dc:identifier>\n"
        opf += "    <dc:title>\(e(title))</dc:title>\n"
        opf += "    <dc:language>\(input.language)</dc:language>\n"
        opf += "    <dc:publisher>\(e(input.sourceName))</dc:publisher>\n"
        opf += "    <dc:source>\(e(input.sourceUrl))</dc:source>\n"
        if let published { opf += "    <dc:date>\(published)</dc:date>\n" }
        opf += "    <meta property=\"dcterms:modified\">\(modified)</meta>\n"
        if coverType != nil { opf += "    <meta name=\"cover\" content=\"cover\"/>\n" }
        opf += "  </metadata>\n"
        opf += "  <manifest>\n"
        opf += "    <item id=\"article\" href=\"article.xhtml\" media-type=\"application/xhtml+xml\"/>\n"
        opf += "    <item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>\n"
        opf += "    <item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>\n"
        opf += "    <item id=\"style\" href=\"style.css\" media-type=\"text/css\"/>\n"
        if let coverType { opf += "    <item id=\"cover\" href=\"\(coverName)\" media-type=\"\(coverType.mediaType)\" properties=\"cover-image\"/>\n" }
        opf += "  </manifest>\n"
        opf += "  <spine toc=\"ncx\">\n    <itemref idref=\"article\"/>\n  </spine>\n</package>\n"
        try opf.write(to: root.appendingPathComponent("OEBPS/content.opf"), atomically: true, encoding: .utf8)

        try """
        body { line-height: 1.8; }
        h1 { font-size: 1.4em; line-height: 1.4; margin: 0 0 0.6em; }
        .hoshi-news-source { font-size: 0.85em; opacity: 0.7; margin-bottom: 1.5em; }
        img { max-width: 100%; height: auto; }
        figcaption { font-size: 0.85em; opacity: 0.8; }

        """.write(to: root.appendingPathComponent("OEBPS/style.css"), atomically: true, encoding: .utf8)

        var chapter = ""
        chapter += "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        chapter += "<html xmlns=\"http://www.w3.org/1999/xhtml\" xml:lang=\"\(input.language)\" lang=\"\(input.language)\">\n"
        chapter += "<head><meta charset=\"utf-8\"/><title>\(e(title))</title><link rel=\"stylesheet\" type=\"text/css\" href=\"style.css\"/></head>\n"
        chapter += "<body>\n<h1>\(heading)</h1>\n"
        let sourceLine = [input.sourceName.trimmingCharacters(in: .whitespaces).isEmpty ? nil : input.sourceName, published].compactMap { $0 }.joined(separator: " · ")
        if !sourceLine.isEmpty { chapter += "<p class=\"hoshi-news-source\">\(e(sourceLine))</p>\n" }
        chapter += input.bodyXhtml.trimmingCharacters(in: .whitespacesAndNewlines) + "\n</body>\n</html>\n"
        try chapter.write(to: root.appendingPathComponent("OEBPS/article.xhtml"), atomically: true, encoding: .utf8)

        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>\(e(title))</title></head>
        <body>
        <nav epub:type="toc"><ol><li><a href="article.xhtml">\(e(title))</a></li></ol></nav>
        </body>
        </html>

        """.write(to: root.appendingPathComponent("OEBPS/nav.xhtml"), atomically: true, encoding: .utf8)

        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <head><meta name="dtb:uid" content="\(identifier)"/><meta name="dtb:depth" content="1"/></head>
          <docTitle><text>\(e(title))</text></docTitle>
          <navMap>
            <navPoint id="article" playOrder="1"><navLabel><text>\(e(title))</text></navLabel><content src="article.xhtml"/></navPoint>
          </navMap>
        </ncx>

        """.write(to: root.appendingPathComponent("OEBPS/toc.ncx"), atomically: true, encoding: .utf8)

        if let cover = input.cover, coverType != nil {
            try cover.write(to: root.appendingPathComponent("OEBPS/\(coverName)"))
        }
    }

    /// Sniffs the container from magic bytes; sites often serve PNG or WebP under a `.jpg` name.
    static func imageType(_ bytes: Data) -> ImageType? {
        guard bytes.count >= 12 else { return nil }
        let b = [UInt8](bytes.prefix(12))
        if b[0] == 0xFF && b[1] == 0xD8 { return ImageType(fileExtension: "jpg", mediaType: "image/jpeg") }
        if b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47 { return ImageType(fileExtension: "png", mediaType: "image/png") }
        if b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 && b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50 {
            return ImageType(fileExtension: "webp", mediaType: "image/webp")
        }
        return nil
    }
}
