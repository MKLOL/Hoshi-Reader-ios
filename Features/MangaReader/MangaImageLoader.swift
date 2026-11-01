// Copyright © 2026 Manhhao.
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

nonisolated struct MangaImageSource: Sendable {
    let url: String
    let path: String
}

nonisolated struct MangaImageCacheSnapshot: Equatable, Sendable {
    let entries: Int
    let bytes: Int
    let hits: Int
    let reads: Int
}

/// Book-scoped encoded image cache. File metadata and original bytes stay on this actor's
/// background executor. WebKit owns decoded retention; originals are served without resizing.
actor MangaImageLoader {
    private let namespace = UUID().uuidString
    private let encodedBudget: Int
    private var root: URL?
    private var declaredPaths: Set<String> = []
    private var wantedPaths: [String] = []
    private var bytes: [Key: Data] = [:]
    private var retainedBytes = 0
    private var hits = 0
    private var reads = 0
    private struct Key: Hashable, Sendable {
        let path: String
        let file: URL
        let size: Int
        let modified: Date
        var version: String { "\(size)-\(modified.timeIntervalSince1970.bitPattern)" }
    }
    private struct Read {
        let id: UUID
        let task: Task<Data, Error>
    }
    private var reading: [Key: Read] = [:]

    init(encodedBudget: Int = 24 * 1024 * 1024) {
        self.encodedBudget = max(0, encodedBudget)
    }

    func configure(root: URL, declaredPaths: Set<String>) {
        self.root = root
        self.declaredPaths = declaredPaths
    }

    /// The next page is retained before the current page, then nearby pages in reading order.
    /// Superseded work can finish an image still wanted by the new window; other reads cancel.
    func setWindow(_ paths: [String]) {
        var seen = Set<String>()
        wantedPaths = paths.filter { declaredPaths.contains($0) && seen.insert($0).inserted }
        for key in Array(bytes.keys) where !wantedPaths.contains(key.path) {
            retainedBytes -= bytes.removeValue(forKey: key)?.count ?? 0
        }
        for (key, read) in reading where !wantedPaths.contains(key.path) { read.task.cancel() }
    }

    func source(relativePath: String) -> MangaImageSource? {
        guard let key = key(for: relativePath) else { return nil }
        var components = URLComponents()
        components.scheme = MangaImageScheme.scheme
        components.host = MangaImageScheme.host
        components.path = "/" + relativePath
        components.queryItems = [URLQueryItem(name: "hoshiImage", value: namespace), URLQueryItem(name: "v", value: key.version)]
        return components.url.map { MangaImageSource(url: $0.absoluteString, path: relativePath) }
    }

    func image(for url: URL, allowedPaths: Set<String>) async throws -> Data {
        guard url.scheme == MangaImageScheme.scheme, url.host == MangaImageScheme.host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw URLError(.badURL) }
        let path = String(components.path.drop(while: { $0 == "/" }))
        guard allowedPaths.contains(path), declaredPaths.contains(path) else { throw URLError(.noPermissionsToReadFile) }
        // Retry once if an image was replaced while it was being read. A failed speculative
        // read never poisons the cache, and every response uses the current original bytes.
        for attempt in 0..<2 {
            try Task.checkCancellation()
            guard let key = key(for: path) else { throw URLError(.fileDoesNotExist) }
            if let cached = bytes[key] { hits += 1; return cached }
            let read: Read
            if let existing = reading[key] {
                hits += 1
                read = existing
            } else {
                reads += 1
                let budget = canRetain(key) ? encodedBudget : 0
                read = Read(id: UUID(), task: Task.detached(priority: .utility) {
                    try Self.readOriginal(key.file, size: key.size, cacheBudget: budget)
                })
                reading[key] = read
            }
            do {
                let data = try await read.task.value
                guard self.key(for: path) == key else {
                    if reading[key]?.id == read.id { reading.removeValue(forKey: key) }
                    if attempt == 0 { continue }
                    throw URLError(.resourceUnavailable)
                }
                if reading[key]?.id == read.id {
                    reading.removeValue(forKey: key)
                    retain(data, for: key)
                }
                try Task.checkCancellation()
                return data
            } catch {
                if reading[key]?.id == read.id { reading.removeValue(forKey: key) }
                if attempt == 0, self.key(for: path) != key { continue }
                throw error
            }
        }
        throw URLError(.resourceUnavailable)
    }

    func prepare(_ paths: [String]) async {
        for path in paths {
            if Task.isCancelled { return }
            guard let key = key(for: path), let source = source(relativePath: path), let url = URL(string: source.url) else { continue }
            if !canRetain(key) {
                let work = Task.detached(priority: .utility) { try Self.warmOriginal(key.file) }
                _ = try? await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            } else { _ = try? await image(for: url, allowedPaths: Set(paths)) }
        }
    }

    func cancelPreparation() {
        for read in reading.values { read.task.cancel() }
        reading.removeAll()
        bytes.removeAll()
        retainedBytes = 0
        wantedPaths = []
    }

    func snapshot() -> MangaImageCacheSnapshot {
        MangaImageCacheSnapshot(entries: bytes.count, bytes: retainedBytes, hits: hits, reads: reads)
    }

    private func key(for path: String) -> Key? {
        guard declaredPaths.contains(path), let root else { return nil }
        var components = URLComponents()
        components.scheme = MangaImageScheme.scheme; components.host = MangaImageScheme.host; components.path = "/" + path
        guard let url = components.url,
              let file = MangaImageScheme.resolveFile(url: url, bookRoot: root, allowedImagePaths: declaredPaths),
              let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attributes[.size] as? NSNumber, size.int64Value >= 0,
              size.uint64Value <= UInt64(Int.max), let modified = attributes[.modificationDate] as? Date else { return nil }
        return Key(path: path, file: file, size: size.intValue, modified: modified)
    }

    private func canRetain(_ key: Key) -> Bool {
        guard key.size > 0, key.size <= encodedBudget, let priority = wantedPaths.firstIndex(of: key.path) else { return false }
        let replaceable = bytes.filter { $0.key.path == key.path }.values.reduce(0) { $0 + $1.count }
        let freeable = bytes.filter { $0.key.path != key.path && (wantedPaths.firstIndex(of: $0.key.path) ?? Int.max) > priority }
            .values.reduce(0) { $0 + $1.count }
        return retainedBytes - replaceable - freeable <= encodedBudget - key.size
    }

    private nonisolated static func warmOriginal(_ file: URL) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var remaining = 8 * 1024 * 1024
        while remaining > 0 {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: min(64 * 1024, remaining)), !chunk.isEmpty else { return }
            remaining -= chunk.count
        }
    }

    private func retain(_ data: Data, for key: Key) {
        for stale in Array(bytes.keys) where stale.path == key.path {
            retainedBytes -= bytes.removeValue(forKey: stale)?.count ?? 0
        }
        guard data.count > 0, data.count <= encodedBudget, let priority = wantedPaths.firstIndex(of: key.path) else { return }
        let evictable = bytes.keys.filter { (wantedPaths.firstIndex(of: $0.path) ?? Int.max) > priority }
            .sorted { (wantedPaths.firstIndex(of: $0.path) ?? Int.max) > (wantedPaths.firstIndex(of: $1.path) ?? Int.max) }
        for evicted in evictable where retainedBytes + data.count > encodedBudget {
            retainedBytes -= bytes.removeValue(forKey: evicted)?.count ?? 0
        }
        guard retainedBytes + data.count <= encodedBudget else { return }
        bytes[key] = data
        retainedBytes += data.count
    }

    private nonisolated static func readOriginal(_ file: URL, size: Int, cacheBudget: Int) throws -> Data {
        try Task.checkCancellation()
        // Large originals remain usable without allocating or retaining an oversized byte array.
        guard size <= cacheBudget else { return try Data(contentsOf: file, options: .mappedIfSafe) }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var data = Data(capacity: size)
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
            guard data.count <= cacheBudget - chunk.count else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(chunk)
        }
        return data
    }
}
/// Resolves `hoshi-img://manga/<percent-encoded relative path>` URLs to on-disk image files
/// under the book's directory, with path-traversal containment + an allow-list. The Swift
/// counterpart of Android's `MangaWebResourceBridge`.
nonisolated enum MangaImageScheme {
    static let scheme = "hoshi-img"
    static let host = "manga"

    /// Resolves a request URL to the on-disk image file, or `nil` if it is not a manga-image
    /// request, names an image the page does not declare, or escapes the book root.
    static func resolveFile(url: URL, bookRoot: URL?, allowedImagePaths: Set<String>) -> URL? {
        guard let bookRoot,
              url.scheme == scheme,
              url.host == host else {
            return nil
        }
        // URLComponents percent-decodes `path`, round-tripping the encoded segments back to the
        // original on-disk relative path.
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var relative = components.path
        while relative.hasPrefix("/") { relative.removeFirst() }
        guard !relative.isEmpty, allowedImagePaths.contains(relative) else { return nil }

        let canonicalRoot = bookRoot.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = canonicalRoot.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        // Containment: candidate must live strictly inside the book root.
        let rootPath = canonicalRoot.path
        let candidatePath = candidate.path
        guard candidatePath != rootPath,
              candidatePath.hasPrefix(rootPath + "/") else {
            return nil
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidatePath, isDirectory: &isDir), !isDir.boolValue else {
            return nil
        }
        return candidate
    }

    static func mimeType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        case "avif": return "image/avif"
        case "bmp": return "image/bmp"
        default: return "application/octet-stream"
        }
    }
}

/// The neighbour page indexes to preload around `currentIndex`: three pages ahead and two behind, clamped to
/// the volume. Mirrors Android `mangaAdjacentPreloadIndexes` (next page first, then previous).
nonisolated func mangaAdjacentPreloadIndexes(currentIndex: Int, pageCount: Int) -> [Int] {
    guard pageCount > 0 else { return [] }
    return [currentIndex + 1, currentIndex - 1, currentIndex + 2, currentIndex - 2, currentIndex + 3].filter { $0 >= 0 && $0 < pageCount }
}
