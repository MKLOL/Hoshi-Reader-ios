//
//  SentenceFontResolver.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Turns the reader's selected font into a `UIFont`.
//
//  The reader itself never needs one: it hands `FontManager`'s file URL to a web view as a
//  `@font-face` rule. Sentence mode draws with TextKit, so an imported or downloaded font file has
//  to be registered with Core Text first and then addressed by its PostScript name. Registrations
//  are process-wide and permanent, so they are done once per URL and remembered.
//

import CoreGraphics
import CoreText
import UIKit

@MainActor
enum SentenceFontResolver {
    /// Every face in a registered collection. An empty array remembers an unreadable font.
    private static var registered: [URL: [String]] = [:]

    /// Sentence mode and transcripts share the same horizontal reading typography.
    static func sentenceFont(named name: String, size: Int) -> UIFont {
        font(named: name, size: CGFloat(size) * 1.1, verticalWriting: false)
    }

    /// The reader's font at `size`, falling back to the system serif face when the selected font
    /// cannot be resolved.
    static func font(named name: String, size: CGFloat, verticalWriting: Bool) -> UIFont {
        if let url = try? FontManager.shared.fontUrl(name: name, verticalWriting: verticalWriting),
           let font = font(at: url, preferredPostScriptName: FontManager.postScriptName(for: name, verticalWriting: verticalWriting), size: size) {
            return font
        }
        // The two built-in Japanese faces have no file — they are installed system-wide.
        if let font = UIFont(name: name, size: size) { return font }
        let descriptor = UIFontDescriptor(fontAttributes: [.family: name])
        let byFamily = UIFont(descriptor: descriptor, size: size)
        if byFamily.familyName == name { return byFamily }
        let serif = UIFontDescriptor
            .preferredFontDescriptor(withTextStyle: .body)
            .withDesign(.serif)
        return serif.map { UIFont(descriptor: $0, size: size) } ?? .systemFont(ofSize: size)
    }

    static func font(at url: URL, preferredPostScriptName: String?, size: CGFloat) -> UIFont? {
        let names = postScriptNames(for: url)
        let name = preferredPostScriptName.flatMap { names.contains($0) ? $0 : nil } ?? names.first
        return name.flatMap { UIFont(name: $0, size: size) }
    }

    private static func postScriptNames(for url: URL) -> [String] {
        if let cached = registered[url] { return cached }
        var error: Unmanaged<CFError>?
        // A font already registered by an earlier call reports an "already registered" error, which
        // is a success for our purposes — the name still resolves below.
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        error?.release()
        // CGFont(dataProvider:) sees only the first collection face: Klee.ttc starts with
        // Demibold, while the reader's downloaded family explicitly selects Klee-Medium.
        let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
        let names = descriptors.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String }
        registered[url] = names
        return names
    }
}
