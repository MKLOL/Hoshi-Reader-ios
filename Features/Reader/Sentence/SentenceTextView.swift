//
//  SentenceTextView.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  The one sentence sentence mode shows, laid out horizontally and tappable word by word.
//
//  TextKit rather than SwiftUI `Text`: a dictionary lookup needs the character index under the
//  finger and that character's rect (to anchor the popup), and SwiftUI exposes neither. TextKit 1
//  is constructed explicitly because `NSLayoutManager` answers both
//  questions directly, which is exactly what `selection.js` does for the web reader.
//
//  Furigana are drawn by hand (`CenteringTextView.draw`) rather than with a `CTRubyAnnotation`
//  attribute: NSLayoutManager (TextKit 1) does not render that Core Text attribute, so it would
//  silently show nothing. The reader keeps the base text untouched — offsets, taps and the
//  highlight all address the base — and the readings ride above each base's glyphs.
//

import SwiftUI
import UIKit

/// What a tap on the sentence resolved to.
struct SentenceTap {
    /// UTF-16 offset of the tapped character in the sentence.
    let characterOffset: Int
    /// The tapped character's rect, in the text view's own coordinate space.
    let rect: CGRect
}

struct SentenceTextView: UIViewRepresentable {
    let text: String
    let font: UIFont
    let color: UIColor
    let lineHeightMultiple: CGFloat
    /// UTF-16 range to highlight, or nil. Set from the dictionary's matched length.
    let highlight: NSRange?
    /// Furigana to draw above their bases, half-size like the reader. Empty when hidden.
    let ruby: [RubyAnnotation]
    let onTap: (SentenceTap) -> Void
    /// A tap that lands beside the text (margin, past the last line) rather than on a character.
    let onTapOutside: () -> Void
    let onSwipeLeft: () -> Void
    let onSwipeRight: () -> Void

    /// Furigana are half the base size, as in the web reader.
    private static let rubySizeFactor: CGFloat = 0.5

    func makeUIView(context: Context) -> CenteringTextView {
        let view = CenteringTextView(frame: .zero, textContainer: nil)
        view.isEditable = false
        view.isSelectable = false
        view.backgroundColor = .clear
        view.alwaysBounceVertical = false
        view.showsVerticalScrollIndicator = false
        view.textContainer.lineFragmentPadding = 0
        view.textContainerInset = .zero
        view.adjustsFontForContentSizeCategory = false

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.handleSwipe(_:))
            )
            swipe.direction = direction
            view.addGestureRecognizer(swipe)
        }
        context.coordinator.textView = view
        return view
    }

    func updateUIView(_ uiView: CenteringTextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.textView = uiView
        // Ruby annotations compare by identity, so the attributed string itself cannot tell a
        // no-op update from a real one; a signature of everything that feeds it can.
        let signature = [
            text, "\(highlight?.location ?? -1),\(highlight?.length ?? -1)", font.fontName,
            "\(font.pointSize)", color.description, "\(lineHeightMultiple)",
            ruby.map { "\($0.start)+\($0.length)=\($0.reading)" }.joined(separator: "|"),
        ].joined(separator: "\u{1F}")
        guard context.coordinator.signature != signature else { return }
        context.coordinator.signature = signature

        let readingFont = font.withSize((font.pointSize * Self.rubySizeFactor).rounded())
        let length = (text as NSString).length
        let validRuby = ruby.filter {
            $0.start >= 0 && $0.start <= length && $0.length > 0 && $0.length <= length - $0.start &&
                !$0.reading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let attributed = NSMutableAttributedString(string: text, attributes: attributes(readingFont: readingFont, hasRuby: !validRuby.isEmpty))
        if let highlight, highlight.location >= 0, highlight.location <= length,
           highlight.length >= 0, highlight.length <= length - highlight.location {
            attributed.addAttribute(
                .backgroundColor,
                value: color.withAlphaComponent(0.18),
                range: highlight
            )
        }
        uiView.attributedText = attributed
        uiView.configureRuby(
            validRuby,
            font: readingFont,
            color: color
        )
        uiView.setNeedsLayout()
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    private func attributes(readingFont: UIFont, hasRuby: Bool) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = lineHeightMultiple
        // CenteringTextView reserves space above the first line.
        // The paragraph spacing opens the same reading gap above following lines.
        if hasRuby {
            paragraph.lineSpacing = readingFont.lineHeight
        }
        paragraph.alignment = .natural
        paragraph.lineBreakMode = .byWordWrapping
        return [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
    }

    @MainActor
    final class Coordinator {
        var parent: SentenceTextView
        weak var textView: CenteringTextView?
        var signature = ""

        init(parent: SentenceTextView) {
            self.parent = parent
        }

        @objc func handleSwipe(_ gesture: UISwipeGestureRecognizer) {
            if gesture.direction == .left { parent.onSwipeLeft() } else { parent.onSwipeRight() }
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            if let tap = resolveTap(gesture) {
                parent.onTap(tap)
            } else {
                // The text view fills the sentence area, so a miss here is the reader's
                // "tap outside": it must close an open popup rather than be swallowed.
                parent.onTapOutside()
            }
        }

        private func resolveTap(_ gesture: UITapGestureRecognizer) -> SentenceTap? {
            guard let view = textView else { return nil }
            return Self.resolveTap(in: view, at: gesture.location(in: view))
        }

        static func resolveTap(in view: UITextView, at location: CGPoint) -> SentenceTap? {
            guard let layoutManager = view.layoutManager as NSLayoutManager?,
                  !view.text.isEmpty else { return nil }
            let container = view.textContainer
            layoutManager.ensureLayout(for: container)
            var point = location
            point.x -= view.textContainerInset.left
            point.y -= view.textContainerInset.top

            var fraction: CGFloat = 0
            let glyphIndex = layoutManager.glyphIndex(
                for: point,
                in: container,
                fractionOfDistanceThroughGlyph: &fraction
            )
            // A tap in the margin resolves to the nearest glyph, which would look like a hit on a
            // word the user never touched. Require the point to be inside the line it landed on.
            guard glyphIndex < layoutManager.numberOfGlyphs else { return nil }
            let lineRect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            guard lineRect.contains(point) else {
                return (view as? CenteringTextView)?.rubyBaseTap(at: location)
            }

            let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            let length = (view.text as NSString).length
            guard characterIndex < length else { return nil }

            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: characterIndex, length: 1),
                actualCharacterRange: nil
            )
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
            rect.origin.x += view.textContainerInset.left
            rect.origin.y += view.textContainerInset.top - view.contentOffset.y
            return SentenceTap(characterOffset: characterIndex, rect: rect)
        }
    }
}

/// Centers the native sentence screen. EPUB chapters and podcast transcripts use WebKit ruby.
final class CenteringTextView: UITextView, NSLayoutManagerDelegate {
    private var sourceText: NSAttributedString?
    private var wrappingGroups: [NSRange] = []
    private var measuredWidth: CGFloat = -1
    private var applyingLayout = false
    private var ruby: [RubyAnnotation] = []
    private var rubyFont: UIFont = .systemFont(ofSize: 8)
    private var rubyColor: UIColor = .label
    override init(frame: CGRect, textContainer: NSTextContainer?) {
        // UITextView's `usingTextLayoutManager` API is an Objective-C class factory, which can
        // bypass a Swift subclass's stored-property initialization. Use the designated
        // initializer with a TextKit 1 stack so ruby/layout state exists before the first update.
        let container: NSTextContainer
        let storage: NSTextStorage?
        if let textContainer {
            container = textContainer
            storage = textContainer.layoutManager?.textStorage
        } else {
            let newStorage = NSTextStorage()
            let layout = NSLayoutManager()
            container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
            container.widthTracksTextView = true
            newStorage.addLayoutManager(layout)
            layout.addTextContainer(container)
            storage = newStorage
        }
        super.init(frame: frame, textContainer: container)
        // Storage owns the layout manager, which owns the container; their reverse links do
        // not retain their owners. Keep the whole stack alive until UITextView adopts it.
        withExtendedLifetime(storage) {}
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    private var readingHeadroom: CGFloat { ruby.isEmpty ? 0 : ceil(rubyFont.lineHeight) }

    func configureRuby(_ ruby: [RubyAnnotation], font: UIFont, color: UIColor) {
        self.ruby = ruby
        sourceText = attributedText
        wrappingGroups = Self.wrappingRanges(text: text, ruby: ruby)
        measuredWidth = -1
        layoutManager.delegate = self
        rubyFont = font
        rubyColor = color
        updateTextInsets()
        invalidateIntrinsicContentSize()
        setNeedsDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        fitWrappingGroups()
        updateTextInsets()
        setNeedsDisplay()
    }

    /// A publisher ruby base is atomic. Short, partially annotated kanji compounds also wrap
    /// together, while a long unannotated run can still fill ordinary lines.
    static func wrappingRanges(text: String, ruby: [RubyAnnotation]) -> [NSRange] {
        let source = text as NSString
        var groups = ruby.map { NSRange(location: $0.start, length: $0.length) }
        let expression = try! NSRegularExpression(pattern: "[\\p{Han}々〻]+")
        for match in expression.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            if source.substring(with: match.range).unicodeScalars.count <= 4 { groups.append(match.range) }
        }
        var merged: [NSRange] = []
        for group in groups.sorted(by: { $0.location < $1.location }) {
            if let previous = merged.last, NSIntersectionRange(previous, group).length > 0 {
                merged[merged.count - 1] = NSUnionRange(previous, group)
            } else { merged.append(group) }
        }
        return merged
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldBreakLineByWordBeforeCharacterAt charIndex: Int) -> Bool {
        !wrappingGroups.contains { $0.location < charIndex && charIndex < NSMaxRange($0) }
    }

    private func fitWrappingGroups() {
        let width = bounds.width - textContainerInset.left - textContainerInset.right - textContainer.lineFragmentPadding * 2
        guard width > 0, abs(width - measuredWidth) > 0.5, !applyingLayout, let sourceText else { return }
        applyingLayout = true
        defer { applyingLayout = false }
        measuredWidth = width
        let fitted = NSMutableAttributedString(attributedString: sourceText)
        for group in wrappingGroups {
            guard NSMaxRange(group) <= fitted.length,
                  let font = sourceText.attribute(.font, at: group.location, effectiveRange: nil) as? UIFont else { continue }
            let baseWidth = sourceText.attributedSubstring(from: group).size().width
            let annotations = ruby.filter { NSIntersectionRange(group, NSRange(location: $0.start, length: $0.length)).length > 0 }
            var required = baseWidth
            for annotation in annotations {
                let span = NSRange(location: annotation.start, length: annotation.length)
                let base = sourceText.attributedSubstring(from: span).size().width
                let reading = (annotation.reading as NSString).size(withAttributes: [.font: rubyFont]).width
                required += max(0, reading - base)
            }
            let scale = min(1, width / max(1, required))
            fitted.addAttribute(.font, value: font.withSize(font.pointSize * scale), range: group)
            for annotation in annotations {
                let span = NSRange(location: annotation.start, length: annotation.length)
                let base = sourceText.attributedSubstring(from: span).size().width
                let reading = (annotation.reading as NSString).size(withAttributes: [.font: rubyFont]).width
                if reading > base {
                    fitted.addAttribute(.kern, value: (reading - base) * scale / CGFloat(max(1, span.length)), range: span)
                }
            }
        }
        attributedText = fitted
        layoutManager.ensureLayout(for: textContainer)
    }

    private func updateTextInsets() {
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer).height
        let top = readingHeadroom + max(0, (bounds.height - used - readingHeadroom) / 2)
        // Inset changes request another layout; ignore subpixel differences to keep it stable.
        if abs(textContainerInset.top - top) > 0.5 {
            textContainerInset = UIEdgeInsets(top: top, left: 0, bottom: 0, right: 0)
        }
    }

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        for drawing in rubyDrawings() { drawing.text.draw(at: drawing.frame.origin) }
    }

    /// Furigana are part of the same tappable word; a hit above the base resolves to the
    /// underlying base glyph rather than the nearest caret in the next line.
    func rubyBaseTap(at point: CGPoint) -> SentenceTap? {
        for drawing in rubyDrawings() where drawing.frame.contains(point) {
            let glyphs = layoutManager.glyphRange(forCharacterRange: drawing.range, actualCharacterRange: nil)
            let base = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            let location = CGPoint(x: min(max(point.x - textContainerInset.left, base.minX + 0.1), base.maxX - 0.1), y: base.midY)
            let glyph = layoutManager.glyphIndex(for: location, in: textContainer)
            let character = layoutManager.characterIndexForGlyph(at: glyph)
            guard NSLocationInRange(character, drawing.range) else { continue }
            let range = (text as NSString).rangeOfComposedCharacterSequence(at: character)
            let target = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: target, in: textContainer)
                .offsetBy(dx: textContainerInset.left, dy: textContainerInset.top - contentOffset.y)
            return SentenceTap(characterOffset: range.location, rect: rect)
        }
        return nil
    }

    private func rubyDrawings() -> [(text: NSAttributedString, frame: CGRect, range: NSRange)] {
        guard !ruby.isEmpty else { return [] }
        layoutManager.ensureLayout(for: textContainer)
        let container = textContainer
        let inset = textContainerInset
        let readingAttributes: [NSAttributedString.Key: Any] = [.font: rubyFont, .foregroundColor: rubyColor]
        let length = (text as NSString).length
        var drawings: [(text: NSAttributedString, frame: CGRect, range: NSRange)] = []

        for annotation in ruby {
            let range = NSRange(location: annotation.start, length: annotation.length)
            guard range.location >= 0, range.location <= length, range.length > 0,
                  range.length <= length - range.location else { continue }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphRange.length > 0, glyphRange.location < layoutManager.numberOfGlyphs else { continue }
            // A base that wraps keeps its reading over the glyphs on its first line. Intersect
            // glyph ranges before measuring: a multiline union rectangle can include unrelated
            // text at the start of the next line and place the reading over the wrong word.
            var firstLineGlyphs = NSRange()
            let firstLine = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphRange.location, effectiveRange: &firstLineGlyphs)
            let firstBaseGlyphs = NSIntersectionRange(glyphRange, firstLineGlyphs)
            let baseRect = layoutManager.boundingRect(forGlyphRange: firstBaseGlyphs, in: container)
            guard !baseRect.isNull, baseRect.width > 0 else { continue }

            let baseFont = attributedText.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont
            var scaledAttributes = readingAttributes
            if let baseFont { scaledAttributes[.font] = baseFont.withSize(baseFont.pointSize * 0.5) }
            let reading = NSAttributedString(string: annotation.reading, attributes: scaledAttributes)
            let size = reading.size()
            let centerX = baseRect.midX + inset.left
            // Sit the reading in the gap just above the base line's glyphs.
            let baseTop = firstLine.minY + inset.top
            let left = min(max(inset.left, centerX - size.width / 2), max(inset.left, bounds.width - inset.right - size.width))
            let origin = CGPoint(x: left, y: baseTop - size.height + 1)
            drawings.append((reading, CGRect(origin: origin, size: size), range))
        }
        return drawings
    }
}
