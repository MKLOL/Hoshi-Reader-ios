import Foundation
import CHoshiDicts
import CxxStdlib

nonisolated enum DictionaryDownloadError: LocalizedError {
    case httpStatus(Int)
    case invalidArchive
    case importFailed(String)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let status): "The dictionary server returned HTTP \(status). Please try again."
        case .invalidArchive: "The dictionary server did not return a ZIP archive. Please try again."
        case .importFailed(let detail): "Could not import the dictionary: \(detail)"
        }
    }
}

/// Release downloads redirect to short-lived signed URLs. Do not reuse a cached redirect on
/// the next setup attempt, and never hand an HTTP error page to the native ZIP importer.
nonisolated enum DictionaryDownloads {
    /// The native importer writes index.json first and this marker last. An interrupted
    /// import must not be listed as installed or skipped by the next setup attempt.
    static func isImportedDictionary(at directory: URL) -> Bool {
        guard (try? directory.appendingPathComponent(".hoshidicts_1")
            .resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return false }
        return ["blobs.bin", "hash.table"].allSatisfy { name in
            guard let values = try? directory.appendingPathComponent(name)
                .resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else { return false }
            return values.isRegularFile == true && (values.fileSize ?? 0) > 0
        }
    }

    static func index(from url: URL) async throws -> DictionaryIndex {
        let data = try await fetch(from: url) { try await URLSession.shared.data(for: $0) }
        return try JSONDecoder().decode(DictionaryIndex.self, from: data)
    }

    static func archive(from url: URL) async throws -> URL {
        try await archive(from: url, load: { try await URLSession.shared.download(for: $0) })
    }

    static func archive(from url: URL,
                        resolveFallback: @Sendable (URL) async throws -> URL? = { try await githubReleaseAsset(for: $0) },
                        load: @Sendable (URLRequest) async throws -> (URL, URLResponse)) async throws -> URL {
        let file = try await fetch(from: url, discard: { try? FileManager.default.removeItem(at: $0) },
                                   resolveFallback: resolveFallback, load: load)
        do {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            guard try handle.read(upToCount: 4) == Data([0x50, 0x4b, 0x03, 0x04]) else {
                throw DictionaryDownloadError.invalidArchive
            }
            return file
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    static func fetch<Value: Sendable>(from url: URL,
                                      discard: @Sendable (Value) -> Void = { _ in },
                                      resolveFallback: @Sendable (URL) async throws -> URL? = { try await githubReleaseAsset(for: $0) },
                                      load: @Sendable (URLRequest) async throws -> (Value, URLResponse)) async throws -> Value {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.timeoutInterval = 120
        do {
            return try await fetch(request: request, discard: discard, load: load)
        } catch {
            guard let fallback = try await resolveFallback(url) else { throw error }
            request.url = fallback
            // GitHub's public asset API streams the binary with this media type. Without
            // it the same endpoint returns asset metadata instead of dictionary contents.
            request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
            return try await fetch(request: request, discard: discard, load: load)
        }
    }

    private static func fetch<Value: Sendable>(request original: URLRequest,
                                              discard: @Sendable (Value) -> Void,
                                              load: @Sendable (URLRequest) async throws -> (Value, URLResponse)) async throws -> Value {
        var request = original
        for attempt in 0...1 {
            do {
                let (value, response) = try await load(request)
                guard let response = response as? HTTPURLResponse else {
                    discard(value)
                    throw URLError(.badServerResponse)
                }
                guard (200..<300).contains(response.statusCode) else {
                    discard(value)
                    let status = response.statusCode
                    let expiredRelease = original.url?.host == "github.com" && [403, 618].contains(status)
                    if attempt == 0 && (expiredRelease || [408, 429, 500, 502, 503, 504].contains(status)) {
                        if expiredRelease {
                            // Also bypass intermediary caches holding an expired GitHub redirect.
                            var components = original.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
                            var items = components?.queryItems ?? []
                            items.append(.init(name: "hoshi_retry", value: UUID().uuidString))
                            components?.queryItems = items
                            request.url = components?.url ?? original.url
                        }
                        continue
                    }
                    throw DictionaryDownloadError.httpStatus(status)
                }
                return value
            } catch let error as URLError where attempt == 0 && [.timedOut, .networkConnectionLost].contains(error.code) {
                continue
            }
        }
        throw URLError(.badServerResponse)
    }

    /// The browser download endpoint can time out while the official API still serves the
    /// same release asset. Only recognized public release URLs are eligible for this route.
    static func githubReleaseAsset(for url: URL,
                                   load: @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
                                       try await URLSession.shared.data(for: $0)
                                   }) async throws -> URL? {
        guard url.scheme == "https", url.host == "github.com" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 6, parts[2] == "releases" else { return nil }
        let releasePath: String
        if parts[3] == "latest", parts[4] == "download" { releasePath = "latest" }
        else if parts[3] == "download" { releasePath = "tags/\(parts[4])" }
        else { return nil }
        guard let metadata = URL(string: "https://api.github.com/repos/\(parts[0])/\(parts[1])/releases/\(releasePath)") else { return nil }
        let data = try await fetch(from: metadata, resolveFallback: { _ in nil }) { request in
            var request = request
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            return try await load(request)
        }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard let asset = release.assets.first(where: { $0.name == parts[5] }),
              asset.url.scheme == "https", asset.url.host == "api.github.com",
              asset.url.path.hasPrefix("/repos/\(parts[0])/\(parts[1])/releases/assets/") else { return nil }
        return asset.url
    }

    private struct GitHubRelease: Decodable, Sendable {
        let assets: [Asset]
        struct Asset: Decodable, Sendable { let name: String; let url: URL }
    }

    @discardableResult
    static func importArchive(at file: URL, to directory: URL) throws -> String {
        let files = FileManager.default
        // Import under a hidden sibling on the same volume. Neither storage scans nor the
        // active lookup query should observe half-written banks, including during updates.
        let staging = directory.appendingPathComponent(".import-\(UUID())", isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: staging) }
        // The default importer queues CPU-count + 4 banks. Limit it to two on mobile;
        // JMdict expands to over 170 MB before its indexes and glossaries are built.
        let result = dictionary_importer.import(std.string(file.path(percentEncoded: false)),
                                                std.string(staging.path(percentEncoded: false)), true)
        guard result.success else {
            let detail = result.errors.map { cxxStringToSwift($0) }.joined(separator: "; ")
            throw DictionaryDownloadError.importFailed(detail.isEmpty ? "Invalid dictionary archive." : detail)
        }
        let title = cxxStringToSwift(result.title)
        let imported = staging.appendingPathComponent(title, isDirectory: true)
        guard isImportedDictionary(at: imported) else {
            throw DictionaryDownloadError.importFailed("The dictionary import did not finish.")
        }
        let destination = directory.appendingPathComponent(title, isDirectory: true)
        if files.fileExists(atPath: destination.path) {
            _ = try files.replaceItemAt(destination, withItemAt: imported)
        } else {
            try files.moveItem(at: imported, to: destination)
        }
        return title
    }
}
