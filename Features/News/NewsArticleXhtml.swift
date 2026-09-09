//
//  NewsArticleXhtml.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Reduces an extracted article fragment to the small XHTML vocabulary the reader needs. The web
//  view extractor already serializes the article container as XML; this pass keeps an allow-list
//  of elements, unwraps everything else, drops scripts/navigation subtrees, and keeps only `src`
//  and `alt` on images. Built on Foundation's XMLParser; malformed input yields nil and the caller
//  falls back to plain paragraphs.
//

import Foundation

nonisolated enum NewsArticleXhtml {
    /// Elements kept as-is. Anything else is unwrapped, except `dropped`, whose subtree is removed.
    static let allowed: Set<String> = [
        "p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "blockquote", "figure", "figcaption",
        "ruby", "rt", "rp", "rb", "br", "img", "strong", "em", "b", "i", "table", "thead", "tbody", "tr", "td", "th", "div",
    ]
    static let dropped: Set<String> = [
        "script", "style", "nav", "header", "footer", "aside", "iframe", "form", "button", "input", "select",
        "textarea", "svg", "noscript", "video", "audio", "canvas", "object", "embed", "template", "head", "link", "meta",
    ]
    private static let blocks: Set<String> = ["p", "div", "li", "ul", "ol", "blockquote", "figure", "h1", "h2", "h3", "h4", "h5", "h6"]

    /// Returns the sanitized fragment, or nil when `xhtml` is not well-formed XML or has no content.
    static func sanitize(_ xhtml: String) -> String? {
        let delegate = Builder()
        let parser = XMLParser(data: Data(xhtml.utf8))
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), let root = delegate.root else { return nil }
        let pruned = prune(root)
        let hasText = !textContent(pruned).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasImage = containsImage(pruned)
        guard hasText || hasImage else { return nil }
        return pruned.children.map(serialize).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Escapes `text` into one `<p>` per non-blank line for the plain-text fallback.
    static func paragraphs(fromText text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { "<p>\(escape($0))</p>" }
            .joined(separator: "\n")
    }

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for char in text {
            switch char {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(char)
            }
        }
        return out
    }

    // MARK: - Tree

    final class Node {
        var name: String
        var attributes: [String: String]
        var children: [Node] = []
        var text: String?
        init(name: String, attributes: [String: String] = [:], text: String? = nil) {
            self.name = name
            self.attributes = attributes
            self.text = text
        }
        var isText: Bool { text != nil }
    }

    /// Collects the allowed subtree while unwrapping unknown elements and dropping junk ones.
    private final class Builder: NSObject, XMLParserDelegate {
        var root: Node?
        private var stack: [Node] = []
        private var dropDepth = 0

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
            let name = elementName.lowercased()
            if dropDepth > 0 || dropped.contains(name) {
                dropDepth += 1
                return
            }
            if root == nil {
                let node = Node(name: "div")
                root = node
                stack = [node]
                return
            }
            if allowed.contains(name) {
                var kept: [String: String] = [:]
                if name == "img" {
                    let src = attributes["src"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let lowered = src.lowercased()
                    let usable = !src.isEmpty && !lowered.hasPrefix("javascript:") && !(lowered.hasPrefix("data:") && src.count > maxDataUri)
                    if !usable {
                        // Treat an unusable image as dropped so its (empty) subtree vanishes.
                        dropDepth += 1
                        return
                    }
                    // Plain-http images never load under App Transport Security; the https
                    // variant usually exists (the Android app applies the same rewrite).
                    kept["src"] = lowered.hasPrefix("http://") ? "https://" + src.dropFirst("http://".count) : src
                    if let alt = attributes["alt"], !alt.trimmingCharacters(in: .whitespaces).isEmpty { kept["alt"] = alt }
                }
                let node = Node(name: name, attributes: kept)
                // Attach to the nearest kept ancestor: an unwrapped wrapper (span, section, a) in
                // between must not swallow the element the way it would if it were a real parent.
                realParent?.children.append(node)
                stack.append(node)
            } else {
                // Unwrapped: children attach to the current parent. Push a marker so the matching
                // end tag pops nothing real.
                stack.append(Node(name: "#unwrap"))
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if dropDepth > 0 {
                dropDepth -= 1
                return
            }
            guard stack.count > 1 else { return }
            let node = stack.removeLast()
            if node.name == "#unwrap" {
                // Its children were appended to the nearest real ancestor as they arrived.
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard dropDepth == 0, !string.isEmpty else { return }
            realParent?.children.append(Node(name: "#text", text: string))
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard dropDepth == 0 else { return }
            realParent?.children.append(Node(name: "#text", text: String(decoding: CDATABlock, as: UTF8.self)))
        }

        private var realParent: Node? { stack.last(where: { $0.name != "#unwrap" }) }
    }

    /// Removes block elements that ended up with no text and no image, e.g. emptied wrappers.
    private static func prune(_ node: Node) -> Node {
        node.children = node.children.compactMap { child -> Node? in
            if child.isText { return child }
            let pruned = prune(child)
            if blocks.contains(pruned.name), textContent(pruned).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !containsImage(pruned), !containsTag(pruned, "br") {
                return nil
            }
            return pruned
        }
        return node
    }

    private static func textContent(_ node: Node) -> String {
        if let text = node.text { return text }
        return node.children.map(textContent).joined()
    }

    private static func containsImage(_ node: Node) -> Bool { containsTag(node, "img") }

    private static func containsTag(_ node: Node, _ tag: String) -> Bool {
        if node.name == tag { return true }
        return node.children.contains { containsTag($0, tag) }
    }

    private static let voidElements: Set<String> = ["br", "img"]

    private static func serialize(_ node: Node) -> String {
        if let text = node.text { return escape(text) }
        var out = "<\(node.name)"
        for key in node.attributes.keys.sorted() {
            out += " \(key)=\"\(escape(node.attributes[key] ?? ""))\""
        }
        if voidElements.contains(node.name) && node.children.isEmpty { return out + "/>" }
        out += ">"
        out += node.children.map(serialize).joined()
        return out + "</\(node.name)>"
    }

    private static let maxDataUri = 200_000
}
