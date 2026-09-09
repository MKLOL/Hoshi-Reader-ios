//
//  NewsHttp.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

struct NewsHttpError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Plain GETs for feeds and cover images, with a size cap.
nonisolated struct NewsHttp: Sendable {
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1 HoshiReader"

    func getData(_ urlString: String, maxBytes: Int) async throws -> Data {
        guard let url = URL(string: urlString) else { throw NewsHttpError(message: "Invalid URL: \(urlString)") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw NewsHttpError(message: "HTTP \(code) for \(urlString)") }
        guard data.count <= maxBytes else { throw NewsHttpError(message: "Response larger than \(maxBytes) bytes: \(urlString)") }
        return data
    }

    func getText(_ urlString: String, maxBytes: Int = 4 * 1024 * 1024) async throws -> String {
        String(decoding: try await getData(urlString, maxBytes: maxBytes), as: UTF8.self)
    }
}
