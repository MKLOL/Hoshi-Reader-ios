//
//  MangaScreenshotCrop.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Ported from Android `features/mangareader/MangaScreenshotCrop.kt` plus the crop/encode
//  helpers from `MangaReaderScreen.kt`. The on-screen drag rectangle (host points) is mapped
//  to original image pixels by the page script's `imageCropFromHostRect`, then the source page
//  image FILE is cropped with CoreGraphics + a CGImageSource region/thumbnail downsample (so a
//  large scan is never fully decoded), encoded to PNG and wrapped in an `AiChatImage`.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Minimum side of a usable crop, in both host and image pixels (matches Android).
nonisolated let mangaScreenshotCropMinSizePx = 32
/// Output crops are clamped to these limits before PNG encode (matches Android).
private nonisolated let mangaScreenshotOutputMaxEdgePx = 2048
private nonisolated let mangaScreenshotOutputMaxAreaPx = 4_000_000

/// A drag rectangle in host (on-screen) pixels.
nonisolated struct MangaScreenshotCropRect: Equatable {
    let left: Int
    let top: Int
    let right: Int
    let bottom: Int

    var width: Int { right - left }
    var height: Int { bottom - top }
}

/// Normalises a raw drag (start/end points) into a clamped, ordered rectangle inside the
/// container, rejecting anything smaller than `minSize` on either side.
nonisolated func normalizedMangaScreenshotCropRect(
    startX: CGFloat,
    startY: CGFloat,
    endX: CGFloat,
    endY: CGFloat,
    containerWidth: Int,
    containerHeight: Int,
    minSize: Int = mangaScreenshotCropMinSizePx
) -> MangaScreenshotCropRect? {
    if containerWidth <= 0 || containerHeight <= 0 { return nil }
    let left = clampInt(Int(min(startX, endX).rounded(.down)), 0, containerWidth)
    let top = clampInt(Int(min(startY, endY).rounded(.down)), 0, containerHeight)
    let right = clampInt(Int(max(startX, endX).rounded(.up)), 0, containerWidth)
    let bottom = clampInt(Int(max(startY, endY).rounded(.up)), 0, containerHeight)
    let rect = MangaScreenshotCropRect(left: left, top: top, right: right, bottom: bottom)
    return (rect.width >= minSize && rect.height >= minSize) ? rect : nil
}

/// Source-image crop in intrinsic manga image pixels (as returned by the page script's
/// `imageCropFromHostRect`).
nonisolated struct MangaImageCropRect: Equatable {
    let left: Int
    let top: Int
    let right: Int
    let bottom: Int
    let pageIndex: Int

    var width: Int { right - left }
    var height: Int { bottom - top }
}

/// Parses the JSON the page script's `imageCropFromHostRect` returns, returning `nil` when the
/// crop is missing or below the minimum size.
nonisolated func parseMangaImageCropRect(_ json: [String: Any]?) -> MangaImageCropRect? {
    guard let json,
          let left = intValue(json["left"]),
          let top = intValue(json["top"]),
          let right = intValue(json["right"]),
          let bottom = intValue(json["bottom"]),
          let pageIndex = intValue(json["pageIndex"]) else {
        return nil
    }
    let crop = MangaImageCropRect(left: left, top: top, right: right, bottom: bottom, pageIndex: pageIndex)
    guard crop.width >= mangaScreenshotCropMinSizePx,
          crop.height >= mangaScreenshotCropMinSizePx else {
        return nil
    }
    return crop
}

/// Crops the `imageFile` to `crop` (in source-image pixels) and returns PNG bytes. Uses a
/// CGImageSource so a large scan is decoded at a reduced size where possible rather than fully.
nonisolated func cropMangaImageFilePng(imageFile: URL, crop: MangaImageCropRect) -> Data? {
    guard let source = CGImageSourceCreateWithURL(imageFile as CFURL, nil) else { return nil }
    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
          let pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
          pixelWidth > 0, pixelHeight > 0 else {
        return nil
    }

    let cropLeft = clampInt(crop.left, 0, pixelWidth)
    let cropTop = clampInt(crop.top, 0, pixelHeight)
    let cropRight = clampInt(crop.right, 0, pixelWidth)
    let cropBottom = clampInt(crop.bottom, 0, pixelHeight)
    let cropWidth = cropRight - cropLeft
    let cropHeight = cropBottom - cropTop
    guard cropWidth >= mangaScreenshotCropMinSizePx,
          cropHeight >= mangaScreenshotCropMinSizePx else {
        return nil
    }

    // Decode at a size adequate for the crop: ask the source for a thumbnail whose max edge is
    // large enough that the crop region survives at the output budget's detail, scaled up so
    // the crop occupies the same fraction of the decoded thumbnail as of the full image. This
    // avoids fully decoding a multi-thousand-pixel scan when only a small bubble is cropped.
    let imageMaxEdge = max(pixelWidth, pixelHeight)
    let cropMaxEdge = max(cropWidth, cropHeight)
    let outputScale = outputDownsampleScale(width: cropWidth, height: cropHeight)
    let neededCropEdge = max(1, Int((Double(cropMaxEdge) * outputScale).rounded()))
    // The crop's footprint relative to the whole image's max edge (always in (0, 1]).
    let cropFractionOfImage = Double(cropMaxEdge) / Double(imageMaxEdge)
    let thumbnailMaxEdge = cropFractionOfImage > 0
        ? min(imageMaxEdge, max(neededCropEdge, Int((Double(neededCropEdge) / cropFractionOfImage).rounded())))
        : imageMaxEdge

    let decoded = decodeImage(source: source, thumbnailMaxEdge: thumbnailMaxEdge, imageMaxEdge: imageMaxEdge)
    guard let decoded else { return nil }

    // Map the crop (in original pixels) into the decoded image's coordinate space.
    let decodeScaleX = Double(decoded.width) / Double(pixelWidth)
    let decodeScaleY = Double(decoded.height) / Double(pixelHeight)
    let regionX = Int((Double(cropLeft) * decodeScaleX).rounded(.down))
    let regionY = Int((Double(cropTop) * decodeScaleY).rounded(.down))
    let regionW = max(1, Int((Double(cropWidth) * decodeScaleX).rounded()))
    let regionH = max(1, Int((Double(cropHeight) * decodeScaleY).rounded()))
    let region = CGRect(
        x: clampInt(regionX, 0, decoded.width),
        y: clampInt(regionY, 0, decoded.height),
        width: min(regionW, decoded.width - clampInt(regionX, 0, decoded.width)),
        height: min(regionH, decoded.height - clampInt(regionY, 0, decoded.height))
    )
    guard region.width >= 1, region.height >= 1,
          let cropped = decoded.cropping(to: region) else {
        return nil
    }

    // Final downsample to the output budget if the cropped region is still large.
    let finalImage = downsample(cropped, scale: outputDownsampleScale(width: cropped.width, height: cropped.height)) ?? cropped
    return pngData(from: finalImage)
}

/// Builds an `AiChatImage` from PNG bytes for the screenshot-translation hook.
nonisolated func mangaScreenshotAiImage(pngData: Data) -> AiChatImage {
    AiChatImage(mimeType: "image/png", base64Data: pngData.base64EncodedString())
}

// MARK: - Private helpers

private nonisolated func decodeImage(source: CGImageSource, thumbnailMaxEdge: Int, imageMaxEdge: Int) -> CGImage? {
    if thumbnailMaxEdge >= imageMaxEdge {
        // Full-size decode requested — use the primary image directly.
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxEdge,
        // Keep raw (untransformed) pixel orientation so the decoded dims match the
        // kCGImagePropertyPixelWidth/Height the crop rect is computed against, and so this path
        // agrees with the full-size CGImageSourceCreateImageAtIndex branch (also untransformed).
        kCGImageSourceCreateThumbnailWithTransform: false,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
}

private nonisolated func outputDownsampleScale(width: Int, height: Int) -> Double {
    if width <= 0 || height <= 0 { return 1 }
    let area = Double(width) * Double(height)
    let edge = Double(max(width, height))
    let scale = min(
        1.0,
        Double(mangaScreenshotOutputMaxEdgePx) / edge,
        (Double(mangaScreenshotOutputMaxAreaPx) / area).squareRoot()
    )
    return scale
}

private nonisolated func downsample(_ image: CGImage, scale: Double) -> CGImage? {
    if scale >= 0.999 { return image }
    let targetWidth = max(mangaScreenshotCropMinSizePx, Int((Double(image.width) * scale).rounded()))
    let targetHeight = max(mangaScreenshotCropMinSizePx, Int((Double(image.height) * scale).rounded()))
    if targetWidth == image.width && targetHeight == image.height { return image }
    let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: targetWidth,
        height: targetHeight,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return image
    }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
    return context.makeImage() ?? image
}

private nonisolated func pngData(from image: CGImage) -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        data as CFMutableData,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        return nil
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
}

private nonisolated func clampInt(_ value: Int, _ lower: Int, _ upper: Int) -> Int {
    min(max(value, lower), upper)
}

private nonisolated func intValue(_ value: Any?) -> Int? {
    if let n = value as? NSNumber { return n.intValue }
    if let i = value as? Int { return i }
    if let d = value as? Double { return Int(d) }
    return nil
}
