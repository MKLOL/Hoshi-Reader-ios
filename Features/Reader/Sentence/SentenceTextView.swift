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
//  is requested explicitly (`usingTextLayoutManager: false`) because `NSLayoutManager` answers both
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
    /// Transcript rows grow to fit their text; sentence mode keeps its full-height scrolling view.
    var fitsContent = false

    /// Furigana are half the base size, as in the web reader.
    private static let rubySizeFactor: CGFloat = 0.5

    func makeUIView(context: Context) -> CenteringTextView {
        let view = CenteringTextView(usingTextLayoutManager: false)
        view.isScrollEnabled = !fitsContent
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
        let attributed = NSMutableAttributedString(string: text, attributes: attributes(readingFont: readingFont))
        if let highlight, highlight.location >= 0, NSMaxRange(highlight) <= length {
            attributed.addAttribute(
                .backgroundColor,
                value: color.withAlphaComponent(0.18),
                range: highlight
            )
        }
        uiView.attributedText = attributed
        uiView.configureRuby(
            ruby.filter { $0.start >= 0 && $0.length > 0 && $0.start + $0.length <= length },
            font: readingFont,
            color: color
        )
        uiView.setNeedsLayout()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: CenteringTextView, context: Context) -> CGSize? {
        guard fitsContent, let width = proposal.width, width > 0 else { return nil }
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    private func attributes(readingFont: UIFont) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = lineHeightMultiple
        // Furigana are drawn into the gap above each line: the first line uses the centering inset
        // above it, and lineSpacing opens the same gap above every following line.
        if !ruby.isEmpty {
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
            guard lineRect.contains(point) else { return nil }

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

/// A text view that keeps its content vertically centered (so a one-line sentence sits in the
/// middle of the screen) and draws furigana above their base glyphs.
final class CenteringTextView: UITextView {
    private var ruby: [RubyAnnotation] = []
    private var rubyFont: UIFont = .systemFont(ofSize: 8)
    private var rubyColor: UIColor = .label

    func configureRuby(_ ruby: [RubyAnnotation], font: UIFont, color: UIColor) {
        self.ruby = ruby
        rubyFont = font
        rubyColor = color
        setNeedsDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let layoutManager = layoutManager as NSLayoutManager? else { return }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer).height
        let top = max(0, (bounds.height - used) / 2)
        // The inset change re-enters layout; the threshold stops that from oscillating.
        if abs(textContainerInset.top - top) > 0.5 {
            textContainerInset = UIEdgeInsets(top: top, left: 0, bottom: 0, right: 0)
        }
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        guard !ruby.isEmpty, let layoutManager = layoutManager as NSLayoutManager? else { return }
        let container = textContainer
        let inset = textContainerInset
        let readingAttributes: [NSAttributedString.Key: Any] = [.font: rubyFont, .foregroundColor: rubyColor]
        let length = (text as NSString).length

        for annotation in ruby {
            let range = NSRange(location: annotation.start, length: annotation.length)
            guard NSMaxRange(range) <= length else { continue }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            // A base that wraps keeps its reading over the part on its first line.
            let firstLine = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            var baseRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
            baseRect = baseRect.intersection(CGRect(x: -.greatestFiniteMagnitude / 2, y: firstLine.minY,
                                                    width: .greatestFiniteMagnitude, height: firstLine.height))
            guard !baseRect.isNull, baseRect.width > 0 else { continue }

            let reading = NSAttributedString(string: annotation.reading, attributes: readingAttributes)
            let size = reading.size()
            let centerX = baseRect.midX + inset.left
            // Sit the reading in the gap just above the base line's glyphs.
            let baseTop = firstLine.minY + inset.top
            let origin = CGPoint(x: centerX - size.width / 2, y: baseTop - size.height + 1)
            reading.draw(at: origin)
        }
    }
}
