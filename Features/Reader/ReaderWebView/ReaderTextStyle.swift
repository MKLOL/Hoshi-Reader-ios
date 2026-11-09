import Foundation

/// Shared EPUB and transcript typography. WebKit lays out `<ruby>` and `<rt>`; the app
/// supplies neither annotation coordinates nor extra reading headroom.
@MainActor enum ReaderTextStyle {
    static func fontFaceCSS(font: String, verticalWriting: Bool) -> String {
        guard (try? FontManager.shared.fontUrl(name: font, verticalWriting: verticalWriting)) != nil,
              let url = ReaderFontHandler.url(name: font, verticalWriting: verticalWriting) else { return "" }
        return """
        @font-face {
            font-family: \(quoted(font));
            src: url(\(quoted(url.absoluteString)));
        }
        """
    }

    static func typographyDeclarations(
        font: String, size: Int, lineHeight: Double? = nil,
        characterSpacing: Double? = nil, color: String? = nil
    ) -> String {
        var declarations = """
        font-family: \(quoted(font)), serif !important;
        font-size: \(size)px !important;
        -webkit-text-size-adjust: none !important;
        """
        if let lineHeight { declarations += "\nline-height: \(lineHeight) !important;" }
        if let characterSpacing { declarations += "\nletter-spacing: \(characterSpacing / 100.0)em !important;" }
        if let color { declarations += "\ncolor: \(color) !important;" }
        return declarations
    }

    /// A line's height comes from the paragraph's own line height, the em box of each inline
    /// box and replaced elements, never from an inline element's own line height. `glyphs` in
    /// place of `inline-box` lays Japanese prose, ruby and emphasis out identically, but makes
    /// WebKit measure the ink of every text run. The word boxes multiply those runs, and a
    /// 50-page chapter then took over four seconds to paginate instead of a third of one.
    static let lineBoxCSS = "html { -webkit-line-box-contain: block inline-box replaced; }"

    static var wordLayoutCSS: String {
        """
        body { word-break: normal !important; overflow-wrap: break-word !important; }
        .hoshi-word { display: inline !important; white-space: nowrap !important; overflow-wrap: normal !important; }
        .hoshi-sentence-block-break {
            break-before: column !important; -webkit-column-break-before: always !important;
            -webkit-margin-before: 0 !important; margin-block-start: 0 !important;
        }
        .hoshi-sentence-page-break {
            display: block !important; width: 0 !important; height: 0 !important;
            margin: 0 !important; padding: 0 !important; line-height: 0 !important;
            break-before: column !important; -webkit-column-break-before: always !important;
        }
        .hoshi-sentence-break-host { display: contents !important; }
        """
    }

    static var textLayoutScript: String {
        guard let url = Bundle.main.url(forResource: "textlayout", withExtension: "js") else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    static func rubyCSS(hidden: Bool) -> String {
        """
        ruby > rt, ruby > rp {
            -webkit-user-select: none;
        }
        \(hidden ? "rt { display: none !important; }" : "")
        """
    }

    /// Keep imported font names inside one CSS string, including when the style is in HTML.
    /// Callers that embed CSS in JavaScript must serialize the whole stylesheet as a string.
    private static func quoted(_ value: String) -> String {
        let escaped = value.unicodeScalars.map { scalar -> String in
            switch scalar.value {
            case 0...0x1F, 0x22, 0x24, 0x27, 0x3C, 0x3E, 0x5C, 0x60, 0x7F:
                return "\\\(String(scalar.value, radix: 16)) "
            default:
                return String(scalar)
            }
        }.joined()
        return "'" + escaped + "'"
    }
}
