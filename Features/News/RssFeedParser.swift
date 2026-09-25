//
//  RssFeedParser.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  RSS 2.0 / Atom listing parser on Foundation's XMLParser. Feeds that are not well-formed XML
//  yield no items rather than an error; the News tab shows that as "no articles found".
//

import Foundation

nonisolated enum RssFeedParser {
    static func parse(_ data: Data) -> [NewsListingItem] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.items
    }

    static func parse(_ text: String) -> [NewsListingItem] { parse(Data(text.utf8)) }

    /// Accepts RFC 1123 / RFC 822 (RSS `pubDate`) and ISO 8601 (Atom, Dublin Core) timestamps.
    static func parseDate(_ raw: String) -> Int64? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return millis(date) }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: text) { return millis(date) }
        for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm Z", "d MMM yyyy HH:mm:ss Z", "yyyy-MM-dd HH:mm:ss Z"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return millis(date) }
        }
        return nil
    }

    private static func millis(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

    /// Strips markup from HTML that feeds put into titles and descriptions.
    static func plainText(_ html: String) -> String {
        var text = decodeEntities(html)
        // XMLParser has already decoded entities, so only ASCII-named tags count as markup; a
        // literal "<ニュース>" in a title survives.
        text = text.replacingOccurrences(of: #"</?[A-Za-z][A-Za-z0-9:-]*(\s[^<>]*)?/?>"#, with: " ", options: .regularExpression)
        text = decodeEntities(text)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ text: String) -> String {
        var result = text
        for (entity, replacement) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " ")] {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        if let regex = try? NSRegularExpression(pattern: #"&#(x?[0-9a-fA-F]+);"#) {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
            for match in matches {
                guard let valueRange = Range(match.range(at: 1), in: result), let fullRange = Range(match.range, in: result) else { continue }
                let value = String(result[valueRange])
                let scalar = value.hasPrefix("x") || value.hasPrefix("X") ? UInt32(value.dropFirst(), radix: 16) : UInt32(value)
                if let scalar, let unicode = Unicode.Scalar(scalar) {
                    result.replaceSubrange(fullRange, with: String(Character(unicode)))
                }
            }
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }

    private static let imageSourcePattern = try! NSRegularExpression(pattern: #"<img\b[^>]*\ssrc\s*=\s*["']([^"']+)["']"#, options: .caseInsensitive)

    static func firstImageSource(inHtml html: String) -> String? {
        guard let match = imageSourcePattern.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[range])
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var items: [NewsListingItem] = []
        private var inItem = false
        private var currentElement: String?
        private var text = ""
        private var title = ""
        private var link = ""
        private var alternateLink: String?
        private var anyHrefLink: String?
        private var date = ""
        private var updated = ""
        private var summary = ""
        private var content = ""
        private var image: String?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
            let name = elementName.lowercased()
            if name == "item" || name == "entry" {
                inItem = true
                title = ""; link = ""; alternateLink = nil; anyHrefLink = nil; date = ""; updated = ""; summary = ""; content = ""; image = nil
                return
            }
            guard inItem else { return }
            let isMedia = namespaceURI?.contains("mrss") == true || namespaceURI?.contains("media") == true
            // Elements nested inside a captured one (Atom type="xhtml" content) keep accumulating
            // into that capture instead of restarting it.
            if currentElement == nil, !isMedia {
                currentElement = name
                text = ""
            }
            switch name {
            case "link":
                if let href = attributes["href"] {
                    let rel = attributes["rel"]?.lowercased()
                    if rel == nil || rel == "alternate" { alternateLink = alternateLink ?? href }
                    anyHrefLink = anyHrefLink ?? href
                }
            case "thumbnail", "content":
                // media:thumbnail / media:content carry the image in a `url` attribute.
                if namespaceURI?.contains("mrss") == true || namespaceURI?.contains("media") == true, let url = attributes["url"] {
                    image = image ?? url
                }
            case "enclosure":
                if let url = attributes["url"], attributes["type"]?.hasPrefix("image/") ?? true { image = image ?? url }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard inItem, currentElement != nil else { return }
            text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard inItem, currentElement != nil else { return }
            text += String(decoding: CDATABlock, as: UTF8.self)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let name = elementName.lowercased()
            if name == "item" || name == "entry" {
                inItem = false
                let url = firstNonEmpty([link, alternateLink ?? "", anyHrefLink ?? ""])
                if let url {
                    let cleanTitle = plainText(title)
                    let cleanSummary = plainText(summary.isEmpty ? content : summary)
                    items.append(
                        NewsListingItem(
                            url: url,
                            title: cleanTitle.isEmpty ? url : cleanTitle,
                            publishedAt: parseDate(date) ?? parseDate(updated),
                            summary: cleanSummary.isEmpty ? nil : String(cleanSummary.prefix(400)),
                            imageUrl: image ?? firstImageSource(inHtml: summary.isEmpty ? content : summary)
                        )
                    )
                }
                return
            }
            guard inItem else { return }
            let isMedia = namespaceURI?.contains("mrss") == true || namespaceURI?.contains("media") == true
            // media:title / media:description describe an attachment, not the article.
            guard !isMedia, name == currentElement else { return }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "title": title = value
            case "link": if !value.isEmpty { link = value }
            case "pubdate", "published", "date": date = value
            case "updated": updated = value
            case "description", "summary": summary = value
            case "content", "encoded": content = value
            default: break
            }
            currentElement = nil
        }

        private func firstNonEmpty(_ candidates: [String]) -> String? {
            candidates.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        }
    }
}
