//
//  ShareViewController.swift
//  ShareExtension
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem, let attachments = item.attachments else {
            finish()
            return
        }

        // Text keeps its original meaning, a dictionary lookup, unless the text itself is a link.
        // A page shared from a browser without selected text arrives as a URL only and becomes an
        // article in the News tab.
        if let textProvider = attachments.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.text.identifier) }) {
            textProvider.loadItem(forTypeIdentifier: UTType.text.identifier) { [weak self] item, _ in
                let text = item as? String ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
                if let text, Self.isBareLink(text) {
                    self?.open(host: "save-article", query: "url", value: text.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    self?.open(host: "search", query: "text", value: text)
                }
            }
            return
        }
        guard let urlProvider = attachments.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) else {
            finish()
            return
        }
        urlProvider.loadItem(forTypeIdentifier: UTType.url.identifier) { [weak self] item, _ in
            let shared = (item as? URL)?.absoluteString
                ?? (item as? String)
                ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
            self?.open(host: "save-article", query: "url", value: shared)
        }
    }

    private static func isBareLink(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    private func open(host: String, query: String, value: String?) {
        guard let value, var components = URLComponents(string: "hoshi://\(host)") else {
            DispatchQueue.main.async { self.finish() }
            return
        }
        components.queryItems = [URLQueryItem(name: query, value: value)]
        guard let url = components.url else {
            DispatchQueue.main.async { self.finish() }
            return
        }

        DispatchQueue.main.async {
            var responder: UIResponder? = self
            while responder != nil {
                if let application = responder as? UIApplication {
                    application.open(url, options: [:], completionHandler: nil)
                    break
                }
                responder = responder?.next
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self.finish()
            }
        }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}
