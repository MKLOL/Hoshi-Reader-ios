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
    let onTap: (SentenceTap) -> Void
    let onSwipeLeft: () -> Void
    let onSwipeRight: () -> Void

    func makeUIView(context: Context) -> CenteringTextView {
        let view = CenteringTextView(usingTextLayoutManager: false)
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
        let attributed = NSMutableAttributedString(string: text, attributes: attributes())
        if let highlight, highlight.location >= 0, NSMaxRange(highlight) <= (text as NSString).length {
            attributed.addAttribute(
                .backgroundColor,
                value: color.withAlphaComponent(0.18),
                range: highlight
            )
        }
        if uiView.attributedText != attributed {
            uiView.attributedText = attributed
            uiView.setNeedsLayout()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    private func attributes() -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = lineHeightMultiple
        paragraph.alignment = .natural
        paragraph.lineBreakMode = .byWordWrapping
        return [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
    }

    @MainActor
    final class Coordinator {
        var parent: SentenceTextView
        weak var textView: CenteringTextView?

        init(parent: SentenceTextView) {
            self.parent = parent
        }

        @objc func handleSwipe(_ gesture: UISwipeGestureRecognizer) {
            if gesture.direction == .left { parent.onSwipeLeft() } else { parent.onSwipeRight() }
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = textView,
                  let layoutManager = view.layoutManager as NSLayoutManager?,
                  !view.text.isEmpty else { return }
            let container = view.textContainer
            var point = gesture.location(in: view)
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
            let lineRect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            guard lineRect.contains(point) else { return }

            let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            let length = (view.text as NSString).length
            guard characterIndex < length else { return }

            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: characterIndex, length: 1),
                actualCharacterRange: nil
            )
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
            rect.origin.x += view.textContainerInset.left
            rect.origin.y += view.textContainerInset.top - view.contentOffset.y
            parent.onTap(SentenceTap(characterOffset: characterIndex, rect: rect))
        }
    }
}

/// A text view that keeps its content vertically centered, so a one-line sentence sits in the
/// middle of the screen rather than pinned under the header.
final class CenteringTextView: UITextView {
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
    }
}
