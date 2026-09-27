import SwiftUI
import UIKit

private struct CardFontScaleKey: EnvironmentKey { static let defaultValue: Double = 1 }
extension EnvironmentValues {
    var cardFontScale: Double {
        get { self[CardFontScaleKey.self] }
        set { self[CardFontScaleKey.self] = newValue }
    }
}

/// Scale layout before drawing, so enlarged content reflows and remains scrollable inside the card.
struct ScaledCardContent<Content: View>: View {
    let scale: Double
    @ViewBuilder var content: () -> Content
    var body: some View {
        GeometryReader { geometry in
            content().frame(width: geometry.size.width / scale, height: geometry.size.height / scale)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading).clipped()
        }
    }
}

struct CardFont: ViewModifier {
    let style: Font.TextStyle
    @Environment(\.cardFontScale) private var scale
    func body(content: Content) -> some View {
        if scale == 1 { content.font(.system(style)) }
        else { content.font(.system(size: pointSize * scale, weight: style == .headline ? .semibold : .regular)) }
    }
    private var pointSize: CGFloat {
        #if os(iOS)
        let native: UIFont.TextStyle = switch style {
        case .caption: .caption1
        case .caption2: .caption2
        case .callout: .callout
        case .subheadline: .subheadline
        case .headline: .headline
        default: .body
        }
        return UIFont.preferredFont(forTextStyle: native).pointSize
        #else
        return switch style { case .caption, .caption2: 10; case .callout: 12; case .subheadline: 11; default: 13 }
        #endif
    }
}

enum PopupCardGeometry {
    static func translationDefaults(in size: CGSize, isPad: Bool) -> CGSize {
        CGSize(width: isPad ? 680 : 520, height: max(isPad ? 520 : 320, size.height * (isPad ? 0.84 : 0.78)))
    }
}

enum PopupCardSample {
    static let dictionaryHTML = """
    <script>
    window.collapseDictionaries = false;
    window.compactGlossaries = false;
    window.showExpressionTags = true;
    window.harmonicFrequency = false;
    window.deduplicatePitchAccents = true;
    window.audioSources = [];
    window.audioEnableAutoplay = false;
    window.audioPlaybackMode = "first";
    window.needsAudio = false;
    window.allowDupes = true;
    window.useAnkiConnect = false;
    window.embedMedia = false;
    window.compactGlossariesAnki = false;
    window.customCSS = "";
    window.swipeThreshold = 0;
    </script><div id="entries-container"></div>
    """
    static let source = "本を読むのが好きだ。"
    static let response = """
    I like reading books.

    | Word | Reading | Meaning |
    | --- | --- | --- |
    | 本 | ほん | book |
    | を | を | object marker |
    | 読む | よむ | to read |
    | の | の | turns the verb into a noun |
    | が | が | subject marker |
    | 好き | すき | liking; fondness |

    **Grammar**

    読むの means “reading.” 好きだ describes something you like.
    """
    static let entries: [[String: Any]] = [[
        "expression": "本", "reading": "ほん", "matched": "本", "rules": [], "deinflectionTrace": [],
        "glossaries": [["dictionary": "Sample dictionary", "content": "[\"book; volume\",\"main; head; this; our; current; present\",\"origin; basis; foundation\"]", "definitionTags": "n", "termTags": ""]],
        "frequencies": [], "pitches": []
    ]]
}
