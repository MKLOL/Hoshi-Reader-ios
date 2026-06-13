//
//  CoverImage.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import ImageIO
import UIKit

/// Process-wide cache of decoded cover thumbnails, keyed by file path + requested pixel size. Cover
/// art is immutable for a given file, so a decoded thumbnail is reusable for the life of the process.
///
/// Without this, every time a cell scrolls back into view SwiftUI re-runs `CoverImage`'s `.task` and
/// re-decodes the (often ~1 MB) JPEG/WebP from disk. On a fast scroll through a full library, dozens
/// of decodes fire at once and saturate every CPU core; the main thread is starved, so the list only
/// catches up once the finger lifts and the decodes drain. Caching makes a re-appearing cover free,
/// and bounding by byte cost keeps the cache from becoming its own source of memory pressure.
final class CoverThumbnailCache {
    static let shared = CoverThumbnailCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        // Bound by decoded bytes, not count, so a few large covers can't blow up memory.
        cache.totalCostLimit = 96 * 1024 * 1024 // ~96 MB of decoded covers
    }

    func image(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func set(_ image: UIImage, forKey key: String) {
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }
}

struct CoverImage<Content: View, Placeholder: View>: View {
    let url: URL?
    let maxPixelSize: Int
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                content(Image(uiImage: image))
            } else {
                placeholder()
            }
        }
        .task(id: CoverImageKey(url: url, maxPixelSize: maxPixelSize)) {
            guard let url else {
                image = nil
                return
            }
            let key = "\(url.path(percentEncoded: false))|\(maxPixelSize)"
            // Re-appearing cover: hand back the cached decode immediately, no disk/CPU work. This is
            // the common case during scrolling and is what keeps the bookshelf smooth.
            if let cached = CoverThumbnailCache.shared.image(forKey: key) {
                image = cached
                return
            }
            let max = maxPixelSize
            // Decode at `.utility`, NOT `.userInitiated`: a burst of cover decodes during a fast
            // scroll must never outrank the main thread's own rendering, or the scroll stalls until
            // the decodes finish (the "only scrolls after I lift my finger" bug).
            let loaded = await Task.detached(priority: .utility) { () -> UIImage? in
                loadThumbnail(url: url, maxPixelSize: max)
            }.value
            guard !Task.isCancelled else {
                return
            }
            if let loaded {
                CoverThumbnailCache.shared.set(loaded, forKey: key)
            }
            image = loaded
        }
    }
}

private struct CoverImageKey: Hashable {
    let path: String?
    let maxPixelSize: Int

    init(url: URL?, maxPixelSize: Int) {
        self.path = url?.path(percentEncoded: false)
        self.maxPixelSize = maxPixelSize
    }
}

private nonisolated func loadThumbnail(url: URL, maxPixelSize: Int) -> UIImage? {
    let sourceOptions: [CFString: Any] = [
        kCGImageSourceShouldCache: false
    ]
    guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
        return nil
    }
    let thumbOptions: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
        return nil
    }
    return UIImage(cgImage: cgImage)
}
