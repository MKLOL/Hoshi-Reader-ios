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
    /// PostScript name per font file already registered in this process; nil marks a file that
    /// could not be registered, so a broken font is not retried on every layout pass.
    private static var registered: [URL: String?] = [:]

    /// The reader's font at `size`, falling back to the system serif face when the selected font
    /// cannot be resolved.
    static func font(named name: String, size: CGFloat, verticalWriting: Bool) -> UIFont {
        if let url = try? FontManager.shared.fontUrl(name: name, verticalWriting: verticalWriting),
           let postScriptName = postScriptName(for: url),
           let font = UIFont(name: postScriptName, size: size) {
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

    private static func postScriptName(for url: URL) -> String? {
        if let cached = registered[url] { return cached }
        var error: Unmanaged<CFError>?
        // A font already registered by an earlier call reports an "already registered" error, which
        // is a success for our purposes — the name still resolves below.
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        error?.release()
        let name = CGDataProvider(url: url as CFURL)
            .flatMap { CGFont($0) }
            .flatMap { $0.postScriptName as String? }
        registered[url] = name
        return name
    }
}
