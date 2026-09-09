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

        // A web page shared from a browser arrives as a URL; it becomes an article in the News
        // tab. Plain text keeps its original meaning: a dictionary lookup.
        if let urlProvider = attachments.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) {
            urlProvider.loadItem(forTypeIdentifier: UTType.url.identifier) { [weak self] item, _ in
                let shared = (item as? URL)?.absoluteString ?? (item as? String)
                self?.open(host: "save-article", query: "url", value: shared)
            }
            return
        }
        guard let provider = attachments.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.text.identifier) }) else {
            finish()
            return
        }
        provider.loadItem(forTypeIdentifier: UTType.text.identifier) { [weak self] item, _ in
            self?.open(host: "search", query: "text", value: item as? String)
        }
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
