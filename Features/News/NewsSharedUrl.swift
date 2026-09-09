//
//  NewsSharedUrl.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Finds the article link in text shared from a browser ("Title https://... via App").
nonisolated enum NewsSharedUrl {
    private static let pattern = try! NSRegularExpression(pattern: #"https?://[^\s<>"'）)\]]+"#, options: .caseInsensitive)

    static func extract(_ text: String?) -> String? {
        guard let text, let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        var url = String(text[range])
        while let last = url.last, ".,。、".contains(last) { url.removeLast() }
        return url
    }
}
