//
//  HttpSyncKv.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Generic key/value blob transport for the v2 sync protocol (see docs/HTTP_SYNC_KV.md). Ported
//  byte-for-byte from the Android client (features/sync/http/HttpSyncKv.kt) so the two platforms
//  talk to the same server. This file is intentionally schema-free: it knows keys, bytes,
//  content-types, timestamps and etags, but not bookmarks, chat entries, manga or EPUB. The
//  Hoshi-specific blob shapes live in SyncBlobs.swift; reconciliation lives in
//  HttpSyncReconciler.swift; the reader-hot single-PUT pushes live in HttpSyncManager.swift.
//
//  Endpoints (all under the configured mount point + `/v1/kv...`):
//   - PUT    /v1/kv/{key}                          upsert opaque bytes (preserves Content-Type)
//   - GET    /v1/kv/{key}                          fetch bytes (nil on 404)
//   - DELETE /v1/kv/{key}                          delete (204 and 404 both succeed)
//   - GET    /v1/kv?prefix=&since=&cursor=&limit=  list key metadata, auto-paginated
//   - POST   /v1/kv-multipart/start                begin a large-payload upload
//   - PUT    /v1/kv-multipart/{id}/{part}          upload one raw part (1-based)
//   - POST   /v1/kv-multipart/{id}/complete        finish, server concatenates parts
//   - DELETE /v1/kv-multipart/{id}                 cancel an unfinished upload
//

import Foundation

// MARK: - Fetched body + headers

/// Body + server headers from a successful `GET /v1/kv/{key}`.
struct HttpSyncKvFetched {
    let body: Data
    let contentType: String
    /// Server-provided `Last-Modified` (RFC 3339 UTC). Empty if the server omitted it.
    let lastModified: String
    /// Server-provided `ETag` (`sha256:<hex>`). Empty if the server omitted it.
    let etag: String
}

/// Headers from a successful `GET /v1/kv/{key}` streamed directly to disk.
struct HttpSyncKvFileFetched {
    let contentType: String
    let lastModified: String
    let etag: String
}

/// All sync transport failures funnel through this so callers can `try?`/`catch` one type.
struct HttpSyncError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

// MARK: - Transport protocol

/// The blob-store operations the sync code needs. A protocol so tests can fake the network with
/// an in-memory map and never hit the real `HttpSyncKvClient`. `nonisolated` so the reconciler /
/// payload codec can drive it from any actor (the project defaults unannotated code to MainActor).
nonisolated protocol HttpSyncKvTransport: Sendable {
    /// Upsert opaque `body` at `key` with the given `contentType`. Returns the server's stamp.
    func put(key: String, contentType: String, body: Data) async throws -> HttpSyncKvWriteResponse

    /// Uploads a file from disk; uses multipart automatically when the file exceeds the
    /// multipart threshold so each request stays below the server's per-PUT body cap.
    func putFile(key: String, contentType: String, fileURL: URL) async throws -> HttpSyncKvWriteResponse

    /// Returns `nil` on `404` (key not present). All other non-2xx responses throw.
    func get(key: String) async throws -> HttpSyncKvFetched?

    /// Downloads `key` into `targetURL` without holding the whole body in memory. `nil` on 404.
    func downloadToFile(key: String, targetURL: URL) async throws -> HttpSyncKvFileFetched?

    /// Lists key metadata for one page (no values). Callers auto-paginate via `nextCursor`.
    func list(prefix: String?, since: String?, cursor: String?, limit: Int?) async throws -> HttpSyncKvList

    /// `204` and `404` both succeed silently — the post-condition is "this key is gone."
    func delete(key: String) async throws
}

nonisolated extension HttpSyncKvTransport {
    /// Convenience: walk every page of a listing, applying `handle` to each key's metadata.
    /// Mirrors Android's `do { list(...) } while (cursor != null && page.truncated)` loop.
    func listAll(
        prefix: String?,
        since: String?,
        limit: Int? = nil,
        handle: (HttpSyncKvKeyMeta) -> Void
    ) async throws {
        var cursor: String? = nil
        repeat {
            let page = try await list(prefix: prefix, since: since, cursor: cursor, limit: limit)
            for meta in page.keys { handle(meta) }
            cursor = page.nextCursor
            if page.truncated != true { break }
        } while cursor != nil
    }
}

// MARK: - URLSession client

/// Concrete transport over the v2 KV REST API using `URLSession` async/await (no third-party
/// dependency). `baseURL` is the server's mount point — e.g. `https://dragos.games/api/book_sync`
/// — and the `/v1/kv...` paths are appended.
nonisolated final class HttpSyncKvClient: HttpSyncKvTransport, @unchecked Sendable {
    private let baseURL: String
    private let bearerToken: String
    private let session: URLSession
    private let multipartPartSizeBytes: Int64
    private let multipartThresholdBytes: Int64

    private static let jsonDecoder = JSONDecoder()
    private static let jsonEncoder = JSONEncoder()

    /// Android sends parts up to 64 MiB so each request stays under Cloudflare's ~100 MB cap, and
    /// uses the same value as the single-PUT-vs-multipart threshold.
    static let maxMultipartPartSizeBytes: Int64 = 64 * 1024 * 1024
    static let defaultMultipartThresholdBytes: Int64 = 64 * 1024 * 1024

    init(
        baseURL: String,
        bearerToken: String,
        session: URLSession? = nil,
        multipartPartSizeBytes: Int64 = HttpSyncKvClient.maxMultipartPartSizeBytes,
        multipartThresholdBytes: Int64 = HttpSyncKvClient.defaultMultipartThresholdBytes
    ) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 600
            config.waitsForConnectivity = false
            self.session = URLSession(configuration: config)
        }
        self.multipartPartSizeBytes = multipartPartSizeBytes
        self.multipartThresholdBytes = multipartThresholdBytes
    }

    // MARK: PUT

    func put(key: String, contentType: String, body: Data) async throws -> HttpSyncKvWriteResponse {
        var request = makeRequest("PUT", path: "/v1/kv/\(encodeKey(key))", contentType: contentType)
        request.httpBody = body
        let (data, response) = try await perform(request, uploadBody: body)
        try ensureSuccess(response: response, data: data)
        return try decodeWriteResponse(data)
    }

    func putFile(key: String, contentType: String, fileURL: URL) async throws -> HttpSyncKvWriteResponse {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path(percentEncoded: false))
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        if size > multipartThresholdBytes {
            return try await putFileMultipart(key: key, contentType: contentType, fileURL: fileURL)
        }
        var request = makeRequest("PUT", path: "/v1/kv/\(encodeKey(key))", contentType: contentType)
        let (data, response) = try await uploadFile(request: &request, fileURL: fileURL)
        try ensureSuccess(response: response, data: data)
        return try decodeWriteResponse(data)
    }

    // MARK: GET

    func get(key: String) async throws -> HttpSyncKvFetched? {
        let request = makeRequest("GET", path: "/v1/kv/\(encodeKey(key))", contentType: nil)
        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else {
            throw HttpSyncError("Sync server returned a non-HTTP response.")
        }
        if http.statusCode == 404 { return nil }
        try ensureSuccess(response: response, data: data)
        return HttpSyncKvFetched(
            body: data,
            contentType: header(http, "Content-Type") ?? "application/octet-stream",
            lastModified: header(http, "Last-Modified") ?? "",
            etag: header(http, "ETag") ?? ""
        )
    }

    func downloadToFile(key: String, targetURL: URL) async throws -> HttpSyncKvFileFetched? {
        let request = makeRequest("GET", path: "/v1/kv/\(encodeKey(key))", contentType: nil)
        let (tempURL, response) = try await downloadData(request)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        guard let http = response as? HTTPURLResponse else {
            throw HttpSyncError("Sync server returned a non-HTTP response.")
        }
        if http.statusCode == 404 { return nil }
        guard (200...299).contains(http.statusCode) else {
            let raw = (try? Data(contentsOf: tempURL)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            throw HttpSyncError(parseError(code: http.statusCode, rawBody: raw))
        }
        try? FileManager.default.removeItem(at: targetURL)
        try FileManager.default.createDirectory(
            at: targetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: tempURL, to: targetURL)
        return HttpSyncKvFileFetched(
            contentType: header(http, "Content-Type") ?? "application/octet-stream",
            lastModified: header(http, "Last-Modified") ?? "",
            etag: header(http, "ETag") ?? ""
        )
    }

    // MARK: LIST

    func list(prefix: String?, since: String?, cursor: String?, limit: Int?) async throws -> HttpSyncKvList {
        var components = URLComponents()
        var items: [URLQueryItem] = []
        if let prefix { items.append(URLQueryItem(name: "prefix", value: prefix)) }
        if let since { items.append(URLQueryItem(name: "since", value: since)) }
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        if let limit { items.append(URLQueryItem(name: "limit", value: String(limit))) }
        components.queryItems = items.isEmpty ? nil : items
        let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""

        let request = makeRequest("GET", path: "/v1/kv\(query)", contentType: nil)
        let (data, response) = try await perform(request)
        try ensureSuccess(response: response, data: data)
        do {
            return try Self.jsonDecoder.decode(HttpSyncKvList.self, from: data)
        } catch {
            throw HttpSyncError("Sync server returned malformed JSON for the key listing.")
        }
    }

    // MARK: DELETE

    func delete(key: String) async throws {
        let request = makeRequest("DELETE", path: "/v1/kv/\(encodeKey(key))", contentType: nil)
        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else {
            throw HttpSyncError("Sync server returned a non-HTTP response.")
        }
        // 204 (deleted) and 404 (already gone) both satisfy the post-condition.
        if http.statusCode == 204 || http.statusCode == 404 { return }
        try ensureSuccess(response: response, data: data)
    }

    // MARK: - Multipart upload

    private struct MultipartStartRequest: Encodable { let key: String; let contentType: String }
    private struct MultipartStartResponse: Decodable { let uploadId: String }
    private struct MultipartCompleteRequest: Encodable { let parts: [Int] }
    private struct MultipartCompleteResponse: Decodable {
        let key: String
        let lastModified: String
        let etag: String?
        let size: Int64?
        let contentType: String?
    }

    private func putFileMultipart(key: String, contentType: String, fileURL: URL) async throws -> HttpSyncKvWriteResponse {
        guard multipartPartSizeBytes >= 1, multipartPartSizeBytes <= Self.maxMultipartPartSizeBytes else {
            throw HttpSyncError("Invalid multipart part size configuration.")
        }
        var uploadId: String? = nil
        do {
            let id = try await startMultipartUpload(key: key, contentType: contentType)
            uploadId = id
            let parts = try await uploadMultipartParts(uploadId: id, fileURL: fileURL)
            return try await completeMultipartUpload(uploadId: id, parts: parts, fallbackContentType: contentType)
        } catch {
            if let uploadId { await cancelMultipartUploadQuietly(uploadId: uploadId) }
            throw error
        }
    }

    private func startMultipartUpload(key: String, contentType: String) async throws -> String {
        let body = try Self.jsonEncoder.encode(MultipartStartRequest(key: key, contentType: contentType))
        var request = makeRequest("POST", path: "/v1/kv-multipart/start", contentType: "application/json; charset=utf-8")
        request.httpBody = body
        let (data, response) = try await perform(request, uploadBody: body)
        try ensureSuccess(response: response, data: data)
        do {
            return try Self.jsonDecoder.decode(MultipartStartResponse.self, from: data).uploadId
        } catch {
            throw HttpSyncError("Sync server returned malformed JSON starting a multipart upload.")
        }
    }

    private func uploadMultipartParts(uploadId: String, fileURL: URL) async throws -> [Int] {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var parts: [Int] = []
        var partNumber = 1
        while true {
            let chunk = try handle.read(upToCount: Int(multipartPartSizeBytes)) ?? Data()
            if chunk.isEmpty { break }
            try await uploadMultipartPart(uploadId: uploadId, partNumber: partNumber, chunk: chunk)
            parts.append(partNumber)
            partNumber += 1
        }
        return parts
    }

    private func uploadMultipartPart(uploadId: String, partNumber: Int, chunk: Data) async throws {
        var request = makeRequest(
            "PUT",
            path: "/v1/kv-multipart/\(urlEncode(uploadId))/\(partNumber)",
            contentType: "application/octet-stream"
        )
        request.httpBody = chunk
        let (data, response) = try await perform(request, uploadBody: chunk)
        try ensureSuccess(response: response, data: data)
    }

    private func completeMultipartUpload(uploadId: String, parts: [Int], fallbackContentType: String) async throws -> HttpSyncKvWriteResponse {
        let body = try Self.jsonEncoder.encode(MultipartCompleteRequest(parts: parts))
        var request = makeRequest(
            "POST",
            path: "/v1/kv-multipart/\(urlEncode(uploadId))/complete",
            contentType: "application/json; charset=utf-8"
        )
        request.httpBody = body
        let (data, response) = try await perform(request, uploadBody: body)
        try ensureSuccess(response: response, data: data)
        do {
            let decoded = try Self.jsonDecoder.decode(MultipartCompleteResponse.self, from: data)
            return HttpSyncKvWriteResponse(
                key: decoded.key,
                lastModified: decoded.lastModified,
                etag: decoded.etag,
                size: decoded.size.map { Int(clamping: $0) },
                contentType: decoded.contentType ?? fallbackContentType
            )
        } catch {
            throw HttpSyncError("Sync server returned malformed JSON completing a multipart upload.")
        }
    }

    private func cancelMultipartUploadQuietly(uploadId: String) async {
        let request = makeRequest("DELETE", path: "/v1/kv-multipart/\(urlEncode(uploadId))", contentType: nil)
        // Best effort only; the user-facing error should be the original upload failure.
        _ = try? await session.data(for: request)
    }

    // MARK: - Networking primitives

    private func makeRequest(_ method: String, path: String, contentType: String?) -> URLRequest {
        let urlString = baseURL.trimmingTrailingSlashes() + path
        // Path is pre-encoded; use the permissive initializer so already-encoded `%` and `/`
        // are preserved rather than double-encoded.
        let url = URL(string: urlString) ?? URL(fileURLWithPath: urlString)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func perform(_ request: URLRequest, uploadBody: Data? = nil) async throws -> (Data, URLResponse) {
        do {
            if let uploadBody {
                var bodyless = request
                bodyless.httpBody = nil
                return try await session.upload(for: bodyless, from: uploadBody)
            }
            return try await session.data(for: request)
        } catch {
            throw HttpSyncError(friendlyMessage(error))
        }
    }

    private func uploadFile(request: inout URLRequest, fileURL: URL) async throws -> (Data, URLResponse) {
        do {
            return try await session.upload(for: request, fromFile: fileURL)
        } catch {
            throw HttpSyncError(friendlyMessage(error))
        }
    }

    private func downloadData(_ request: URLRequest) async throws -> (URL, URLResponse) {
        do {
            let (tempURL, response) = try await session.download(for: request)
            return (tempURL, response)
        } catch {
            throw HttpSyncError(friendlyMessage(error))
        }
    }

    private func ensureSuccess(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw HttpSyncError("Sync server returned a non-HTTP response.")
        }
        guard (200...299).contains(http.statusCode) else {
            throw HttpSyncError(parseError(code: http.statusCode, rawBody: String(decoding: data, as: UTF8.self)))
        }
    }

    private func decodeWriteResponse(_ data: Data) throws -> HttpSyncKvWriteResponse {
        do {
            return try Self.jsonDecoder.decode(HttpSyncKvWriteResponse.self, from: data)
        } catch {
            throw HttpSyncError("Sync server returned malformed JSON for the write response.")
        }
    }

    private func header(_ response: HTTPURLResponse, _ name: String) -> String? {
        response.value(forHTTPHeaderField: name)
    }

    private struct ServerError: Decodable { let error: String? }

    private func parseError(code: Int, rawBody: String) -> String {
        let message = (try? Self.jsonDecoder.decode(ServerError.self, from: Data(rawBody.utf8)))?
            .error?.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = (message?.isEmpty == false) ? message : nil
        switch code {
        case 401:
            return "Server rejected the bearer token (HTTP 401). Check the token in HTTP Sync settings."
        case 403:
            return "Server forbids this request (HTTP 403)."
        case 404:
            return "Not found on server (HTTP 404)."
        case 413:
            return "Body too large for the sync server (HTTP 413)."
        case 500...599:
            if let detail { return "Server is having trouble (HTTP \(code)): \(detail)" }
            return "Server is having trouble (HTTP \(code)). Try again in a moment."
        default:
            if let detail { return "HTTP \(code): \(detail)" }
            return "HTTP sync request failed (HTTP \(code))."
        }
    }

    /// Turns raw URLSession errors into messages a user can act on.
    private func friendlyMessage(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                return "Can't reach the sync server — check your network or the base URL."
            case NSURLErrorCannotConnectToHost:
                return "Sync server is not reachable (connection refused). Is it up?"
            case NSURLErrorTimedOut:
                return "Sync request timed out. Network is too slow or the server is hung."
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                return "No network — try again when you're back online."
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
                return "TLS handshake with the sync server failed."
            default:
                break
            }
        }
        let raw = nsError.localizedDescription
        return raw.isEmpty ? "HTTP sync request failed." : "Network error: \(raw)"
    }

    /// Encodes a key for use in the URL path. The server's grammar (`[A-Za-z0-9_.-]` per segment,
    /// `/`-separated) needs no real percent-encoding, but routing each segment through a strict
    /// allowed-character set keeps the client safe if a borderline character ever appears, and
    /// preserves `/` as a path separator (matching Android's `encodeKey`).
    private func encodeKey(_ key: String) -> String {
        key.split(separator: "/", omittingEmptySubsequences: false)
            .map { urlEncode(String($0)) }
            .joined(separator: "/")
    }

    private func urlEncode(_ value: String) -> String {
        // Match Java's URLEncoder semantics closely enough for the v2 key grammar: keep
        // unreserved characters, percent-encode everything else.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "_-.~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

nonisolated private extension String {
    func trimmingTrailingSlashes() -> String {
        var s = self
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
