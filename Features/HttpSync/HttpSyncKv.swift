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

/// Serializes sync requests from every `HttpSyncKvClient` in this process. The production sync
/// endpoint is bearer-authenticated but currently also passes through a 500-request/minute global
/// web limit. A full first sync can contain thousands of small bookmark/chat keys, so firing them
/// as fast as URLSession can complete guarantees an HTTP 429 partway through the run.
///
/// 150 ms keeps the app below 400 requests/minute, leaving room for an occasional browser request
/// or an in-flight reader push. This is deliberately process-wide: per-client gates would still
/// race when a manual sync and a page-turn push overlap.
private actor HttpSyncRequestGate {
    private let minimumInterval: TimeInterval
    private var nextRequestAt = Date.distantPast
    private var blockedUntil = Date.distantPast

    init(minimumInterval: TimeInterval) {
        self.minimumInterval = minimumInterval
    }

    func wait() async throws {
        // Reserve the slot BEFORE suspending. Actors are re-entrant across `await`; updating after
        // sleep would let several concurrent callers wake together and burst past the server cap.
        let now = Date()
        let scheduledAt = max(now, nextRequestAt, blockedUntil)
        nextRequestAt = scheduledAt.addingTimeInterval(minimumInterval)
        let delay = scheduledAt.timeIntervalSince(now)
        if delay > 0 {
            try await Task.sleep(for: .seconds(delay))
        }
    }

    /// Applies a server-requested cooldown to every sync caller, not just the request that saw the
    /// 429. Existing future reservations are moved behind the same deadline.
    func imposeCooldown(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        if deadline > blockedUntil { blockedUntil = deadline }
        if deadline > nextRequestAt { nextRequestAt = deadline }
    }
}

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
nonisolated struct HttpSyncKvFileFetched: Codable, Sendable {
    let contentType: String
    let lastModified: String
    let etag: String
}

/// All sync transport failures funnel through this so callers can `try?`/`catch` one type.
struct HttpSyncError: LocalizedError {
    let message: String
    /// When true, the reconciler advances its cursor PAST this item instead of retrying it on every
    /// sync (e.g. the device can't fit this book). Prevents the "re-download the same GB payload
    /// forever" loop on a storage-starved device.
    let skip: Bool
    let statusCode: Int?
    var errorDescription: String? { message }
    init(_ message: String, skip: Bool = false, statusCode: Int? = nil) { self.message = message; self.skip = skip; self.statusCode = statusCode }
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

    /// Fetch a small sidecar with a limit enforced while bytes arrive, before allocation.
    func getBounded(key: String, maxBytes: Int) async throws -> HttpSyncKvFetched?

    /// Downloads `key` into `targetURL` without holding the whole body in memory. `nil` on 404.
    func downloadToFile(key: String, targetURL: URL) async throws -> HttpSyncKvFileFetched?

    /// Lists key metadata for one page (no values). Callers auto-paginate via `nextCursor`.
    func list(prefix: String?, since: String?, cursor: String?, limit: Int?) async throws -> HttpSyncKvList

    /// `204` and `404` both succeed silently — the post-condition is "this key is gone."
    func delete(key: String) async throws
}

nonisolated extension HttpSyncKvTransport {
    /// In-memory test transports can use the ordinary GET; network transports override this.
    func getBounded(key: String, maxBytes: Int) async throws -> HttpSyncKvFetched? {
        let fetched = try await get(key: key)
        if let fetched, fetched.body.count > maxBytes { throw HttpSyncError("Sync response exceeds the size limit.") }
        return fetched
    }

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

/// Records the exact ETags produced by one full reconcile. Comparing the post-reconcile list to
/// this expected fingerprint distinguishes our own writes from a concurrent device write, so map
/// publication is safe without forcing an otherwise identical second full scan.
nonisolated final class HttpSyncWriteTrackingTransport: HttpSyncKvTransport, @unchecked Sendable {
    private enum Mutation {
        case put(key: String, etag: String?)
        case delete(key: String)
    }

    private let base: HttpSyncKvTransport
    private let lock = NSLock()
    private var mutations: [Mutation] = []

    init(base: HttpSyncKvTransport) {
        self.base = base
    }

    func put(key: String, contentType: String, body: Data) async throws -> HttpSyncKvWriteResponse {
        let response = try await base.put(key: key, contentType: contentType, body: body)
        record(.put(key: key, etag: response.etag))
        return response
    }

    func putFile(key: String, contentType: String, fileURL: URL) async throws -> HttpSyncKvWriteResponse {
        let response = try await base.putFile(key: key, contentType: contentType, fileURL: fileURL)
        record(.put(key: key, etag: response.etag))
        return response
    }

    func get(key: String) async throws -> HttpSyncKvFetched? {
        try await base.get(key: key)
    }

    func getBounded(key: String, maxBytes: Int) async throws -> HttpSyncKvFetched? {
        try await base.getBounded(key: key, maxBytes: maxBytes)
    }

    func downloadToFile(key: String, targetURL: URL) async throws -> HttpSyncKvFileFetched? {
        try await base.downloadToFile(key: key, targetURL: targetURL)
    }

    func list(
        prefix: String?,
        since: String?,
        cursor: String?,
        limit: Int?
    ) async throws -> HttpSyncKvList {
        try await base.list(prefix: prefix, since: since, cursor: cursor, limit: limit)
    }

    func delete(key: String) async throws {
        try await base.delete(key: key)
        record(.delete(key: key))
    }

    /// Nil means a successful PUT omitted its ETag, so an exact safety comparison is impossible.
    func expectedLegacyEtags(after baseline: [String: String]) -> [String: String]? {
        lock.withLock {
            var expected = baseline
            for mutation in mutations {
                switch mutation {
                case let .put(key, etag):
                    guard !key.hasPrefix(httpSyncMapPrefix) else { continue }
                    guard let etag, !etag.isEmpty else { return nil }
                    expected[key] = etag
                case let .delete(key):
                    guard !key.hasPrefix(httpSyncMapPrefix) else { continue }
                    expected.removeValue(forKey: key)
                }
            }
            return expected
        }
    }

    private func record(_ mutation: Mutation) {
        lock.withLock { mutations.append(mutation) }
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
    private let useBackgroundDownloads: Bool
    private let onTransfer: @Sendable (HttpSyncTransferSample) -> Void

    private static let jsonDecoder = JSONDecoder()
    private static let jsonEncoder = JSONEncoder()
    private static let requestGate = HttpSyncRequestGate(minimumInterval: 0.150)
    private static let maxRateLimitRetries = 5

    /// Android sends parts up to 64 MiB so each request stays under Cloudflare's ~100 MB cap, and
    /// uses the same value as the single-PUT-vs-multipart threshold.
    static let maxMultipartPartSizeBytes: Int64 = 64 * 1024 * 1024
    static let defaultMultipartThresholdBytes: Int64 = 64 * 1024 * 1024

    init(
        baseURL: String,
        bearerToken: String,
        session: URLSession? = nil,
        multipartPartSizeBytes: Int64 = HttpSyncKvClient.maxMultipartPartSizeBytes,
        multipartThresholdBytes: Int64 = HttpSyncKvClient.defaultMultipartThresholdBytes,
        onTransfer: @escaping @Sendable (HttpSyncTransferSample) -> Void = { _ in }
    ) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        self.useBackgroundDownloads = session == nil
        self.onTransfer = onTransfer
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 600
            config.waitsForConnectivity = false
            // Never persist sync responses to the on-disk URL cache. Caching KV GETs is pointless
            // (the reconciler does its own LWW comparison and re-lists every pass), and when the
            // device's Caches volume is full or its cache DB is wedged, every response write fails
            // with SQLITE_IOERR. That flood previously trapped the app (signal 5) mid-sync. Opting
            // out of the URL cache removes both the noise and the crash trigger.
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
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
        onTransfer(.init(key: key, uploading: true, completed: 0, total: size))
        let (data, response) = try await uploadFile(request: &request, fileURL: fileURL) { [onTransfer] done in
            onTransfer(.init(key: key, uploading: true, completed: done, total: size))
        }
        try ensureSuccess(response: response, data: data)
        return try decodeWriteResponse(data)
    }

    // MARK: GET

    func getBounded(key: String, maxBytes: Int) async throws -> HttpSyncKvFetched? {
        guard maxBytes >= 0 else { throw HttpSyncError("Invalid response size limit.") }
        let request = makeRequest("GET", path: "/v1/kv/\(encodeKey(key))", contentType: nil)
        for attempt in 0...Self.maxRateLimitRetries {
            try await Self.requestGate.wait()
            let (bytes, response) = try await session.bytes(for: request)
            // Cancellation also stops oversized/chunked bodies and redirects' error bodies.
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { throw HttpSyncError("Sync server returned a non-HTTP response.") }
            if http.statusCode == 404 { return nil }
            if shouldRetryRateLimit(response: response, attempt: attempt) {
                try await waitForRateLimit(response: response, attempt: attempt)
                continue
            }
            let ok = (200...299).contains(http.statusCode)
            let limit = ok ? maxBytes : 8192
            if ok && response.expectedContentLength > Int64(maxBytes) { throw HttpSyncError("Sync response exceeds the size limit.") }
            var body = Data()
            for try await byte in bytes {
                if body.count >= limit {
                    if ok { throw HttpSyncError("Sync response exceeds the size limit.") }
                    break
                }
                body.append(byte)
            }
            try ensureSuccess(response: response, data: body)
            return HttpSyncKvFetched(body: body, contentType: header(http, "Content-Type") ?? "application/octet-stream",
                lastModified: header(http, "Last-Modified") ?? "", etag: header(http, "ETag") ?? "")
        }
        throw HttpSyncError("Sync server kept rate-limiting requests (HTTP 429). Try again in a moment.")
    }

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
        if useBackgroundDownloads {
            for attempt in 0...Self.maxRateLimitRetries {
                do {
                    try Task.checkCancellation()
                    try await Self.requestGate.wait()
                    return try await HttpSyncBackgroundDownloads.shared.download(request, to: targetURL) { [onTransfer] done, total in
                        onTransfer(.init(key: key, uploading: false, completed: done, total: total))
                    }
                } catch {
                    try Task.checkCancellation()
                    if let http = error as? HttpSyncDownloadHTTPError {
                        if shouldRetryRateLimit(response: http.response, attempt: attempt) {
                            try await waitForRateLimit(response: http.response, attempt: attempt)
                            continue
                        }
                        throw HttpSyncError(parseError(code: http.response.statusCode, rawBody: ""))
                    }
                    guard attempt < 2, NetworkReachability.isNetworkFailure(error) else { throw error }
                    try await Task.sleep(for: .seconds(attempt + 1))
                }
            }
        }
        let (tempURL, response) = try await downloadData(request)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        guard let http = response as? HTTPURLResponse else {
            throw HttpSyncError("Sync server returned a non-HTTP response.")
        }
        if http.statusCode == 404 { return nil }
        guard (200...299).contains(http.statusCode) else {
            let raw = (try? Data(contentsOf: tempURL)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            throw HttpSyncError(parseError(code: http.statusCode, rawBody: raw), statusCode: http.statusCode)
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
        // Encode query values the same way Android does (Java URLEncoder): `/`, `:` etc. are
        // percent-encoded. URLComponents.percentEncodedQuery leaves `/` and `:` literal, which
        // would diverge from the Android client and from servers that match query strings exactly.
        var parts: [String] = []
        if let prefix { parts.append("prefix=\(urlEncode(prefix))") }
        if let since { parts.append("since=\(urlEncode(since))") }
        if let cursor { parts.append("cursor=\(urlEncode(cursor))") }
        if let limit { parts.append("limit=\(limit)") }
        let query = parts.isEmpty ? "" : "?" + parts.joined(separator: "&")

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
            let parts = try await uploadMultipartParts(uploadId: id, fileURL: fileURL, key: key)
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

    private func uploadMultipartParts(uploadId: String, fileURL: URL, key: String) async throws -> [Int] {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var parts: [Int] = []
        var partNumber = 1
        var uploaded: Int64 = 0
        let total = Int64((try fileURL.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
        onTransfer(.init(key: key, uploading: true, completed: 0, total: total))
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: Int(multipartPartSizeBytes)) ?? Data()
            if chunk.isEmpty { break }
            let offset = uploaded
            try await uploadMultipartPart(uploadId: uploadId, partNumber: partNumber, chunk: chunk) { [onTransfer] done in
                onTransfer(.init(key: key, uploading: true, completed: offset + done, total: total))
            }
            uploaded += Int64(chunk.count)
            parts.append(partNumber)
            partNumber += 1
        }
        return parts
    }

    private func uploadMultipartPart(uploadId: String, partNumber: Int, chunk: Data, progress: @escaping @Sendable (Int64) -> Void) async throws {
        var request = makeRequest(
            "PUT",
            path: "/v1/kv-multipart/\(urlEncode(uploadId))/\(partNumber)",
            contentType: "application/octet-stream"
        )
        request.httpBody = chunk
        let (data, response) = try await perform(request, uploadBody: chunk, progress: progress)
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

    private func perform(_ request: URLRequest, uploadBody: Data? = nil, progress: (@Sendable (Int64) -> Void)? = nil) async throws -> (Data, URLResponse) {
        for attempt in 0...Self.maxRateLimitRetries {
            do {
                try Task.checkCancellation()
                try await Self.requestGate.wait()
                let result: (Data, URLResponse)
                if let uploadBody {
                    var bodyless = request
                    bodyless.httpBody = nil
                    result = try await session.upload(for: bodyless, from: uploadBody,
                        delegate: progress.map(HttpSyncUploadProgressDelegate.init))
                } else {
                    result = try await session.data(for: request)
                }
                if shouldRetryRateLimit(response: result.1, attempt: attempt) {
                    try await waitForRateLimit(response: result.1, attempt: attempt)
                    continue
                }
                return result
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                throw HttpSyncError(friendlyMessage(error))
            }
        }
        throw HttpSyncError("Sync server kept rate-limiting requests (HTTP 429). Try again in a moment.")
    }

    private func uploadFile(request: inout URLRequest, fileURL: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> (Data, URLResponse) {
        for attempt in 0...Self.maxRateLimitRetries {
            do {
                try Task.checkCancellation()
                try await Self.requestGate.wait()
                let result = try await session.upload(for: request, fromFile: fileURL,
                    delegate: HttpSyncUploadProgressDelegate(progress))
                if shouldRetryRateLimit(response: result.1, attempt: attempt) {
                    try await waitForRateLimit(response: result.1, attempt: attempt)
                    continue
                }
                return result
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                throw HttpSyncError(friendlyMessage(error))
            }
        }
        throw HttpSyncError("Sync server kept rate-limiting requests (HTTP 429). Try again in a moment.")
    }

    private func downloadData(_ request: URLRequest) async throws -> (URL, URLResponse) {
        for attempt in 0...Self.maxRateLimitRetries {
            do {
                try Task.checkCancellation()
                try await Self.requestGate.wait()
                let result = try await session.download(for: request)
                if shouldRetryRateLimit(response: result.1, attempt: attempt) {
                    try? FileManager.default.removeItem(at: result.0)
                    try await waitForRateLimit(response: result.1, attempt: attempt)
                    continue
                }
                return result
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                throw HttpSyncError(friendlyMessage(error))
            }
        }
        throw HttpSyncError("Sync server kept rate-limiting requests (HTTP 429). Try again in a moment.")
    }

    private func shouldRetryRateLimit(response: URLResponse, attempt: Int) -> Bool {
        guard attempt < Self.maxRateLimitRetries,
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 429
    }

    /// Honor the server's Retry-After value when present. Flask-Limiter normally sends integer
    /// seconds, while RFC 9110 also permits an HTTP date; support both and fall back to bounded
    /// exponential backoff when a proxy strips the header.
    private func waitForRateLimit(response: URLResponse, attempt: Int) async throws {
        let delay = rateLimitDelay(response: response, attempt: attempt)
        await Self.requestGate.imposeCooldown(seconds: delay)
        try Task.checkCancellation()
    }

    private func rateLimitDelay(response: URLResponse, attempt: Int) -> TimeInterval {
        guard let http = response as? HTTPURLResponse,
              let raw = header(http, "Retry-After")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return min(30, pow(2, Double(attempt + 1)))
        }
        if let seconds = TimeInterval(raw) {
            return min(120, max(0.5, seconds))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        if let date = formatter.date(from: raw) {
            return min(120, max(0.5, date.timeIntervalSinceNow))
        }
        return min(30, pow(2, Double(attempt + 1)))
    }

    private func ensureSuccess(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw HttpSyncError("Sync server returned a non-HTTP response.")
        }
        guard (200...299).contains(http.statusCode) else {
            throw HttpSyncError(parseError(code: http.statusCode, rawBody: String(decoding: data, as: UTF8.self)), statusCode: http.statusCode)
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
        case 429:
            if let detail { return "Sync server rate limit reached (HTTP 429): \(detail)" }
            return "Sync server rate limit reached (HTTP 429). The app waited and retried, but the server is still busy."
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
