//
//  MokuroCover.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Headless cover-thumbnail generation for mokuro manga, mirroring the EPUB importer's habit
//  of writing a small bookshelf cover. Uses ImageIO directly (no UIImage) so it stays cheap
//  and usable off the main thread; the source is a full-resolution manga page so downsampling
//  is essential.
//

import Foundation
import ImageIO
import UniformTypeIdentifiers

enum MokuroCover {
    enum CoverError: LocalizedError {
        case sourceUnreadable(URL)
        case thumbnailFailed(URL)
        case destinationFailed(URL)

        var errorDescription: String? {
            switch self {
            case .sourceUnreadable(let url):
                return "Could not read cover source image at \(url.lastPathComponent)."
            case .thumbnailFailed(let url):
                return "Could not generate a cover thumbnail from \(url.lastPathComponent)."
            case .destinationFailed(let url):
                return "Could not write the cover thumbnail to \(url.lastPathComponent)."
            }
        }
    }

    /// Generates a downsampled JPEG cover from `imageURL` and writes it to `destURL`.
    ///
    /// `maxPixel` bounds the longer edge of the thumbnail. The thumbnail is always created
    /// from the full image (`kCGImageSourceCreateThumbnailFromImageAlways`) so EXIF-embedded
    /// thumbnails — often tiny or absent in manga scans — are never used.
    ///
    /// - Throws: `CoverError` if the source can't be read, the thumbnail can't be produced,
    ///   or the destination can't be written.
    static func generateThumbnail(from imageURL: URL, to destURL: URL, maxPixel: Int = 600) throws {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, sourceOptions as CFDictionary) else {
            throw CoverError.sourceUnreadable(imageURL)
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            throw CoverError.thumbnailFailed(imageURL)
        }

        // Ensure the destination directory exists before writing.
        let destDir = destURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: destDir.path(percentEncoded: false)) {
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        }

        guard let destination = CGImageDestinationCreateWithURL(
            destURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw CoverError.destinationFailed(destURL)
        }

        let destProperties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.8
        ]
        CGImageDestinationAddImage(destination, thumbnail, destProperties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw CoverError.destinationFailed(destURL)
        }
    }
}
