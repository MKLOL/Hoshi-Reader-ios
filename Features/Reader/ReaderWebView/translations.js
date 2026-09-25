//
//  translations.js
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Places a small "show translation" button after each pre-translated sentence's 。
//
//  Anchors arrive from Swift as `{id, start, len, text}`, where `start`/`len` count only matchable
//  characters (kana, kanji, radicals, alphanumerics) from the start of the chapter — the same
//  offset space Sasayaki cues use, and the reason `collectSasayakiCueRanges` already exists.
//
//  Two invariants the rest of the reader depends on:
//
//    1. The button holds NO text node. Its glyph comes from CSS `::before`, so the tree walkers
//       that count characters for bookmarks, highlights and cue alignment cannot see it. (They
//       also reject `.hoshi-tl` explicitly — belt and braces.)
//    2. Offsets are rebuilt after insertion, and buttons are torn down on every chapter load.
//

window.hoshiTranslations = {
    buttons: [],

    // Swallowed after the terminator so the button lands after a closing 」 too. Same set as
    // hoshiSelection.trailingSentenceChars.
    trailingChars: '。、！？…‥」』）)】〉》〕｝}］]',

    /// One entry per matchable character in the chapter: the character itself, plus where it ends
    /// in the DOM. Built in a single walk, then indexed by normalized offset — which is exactly
    /// what an anchor addresses.
    scanChapter() {
        const chars = [];
        const ends = [];
        const walker = window.hoshiReader.createWalker();
        let node;
        while (node = walker.nextNode()) {
            const text = node.textContent;
            for (let i = 0; i < text.length;) {
                const char = String.fromCodePoint(text.codePointAt(i));
                const next = i + char.length;
                if (window.hoshiReader.isMatchableChar(char)) {
                    chars.push(char);
                    ends.push({ node: node, offset: next });
                }
                i = next;
            }
        }
        return { chars: chars, text: chars.join(''), ends: ends };
    },

    /// Resolves one anchor to the index of its last matchable character, or -1.
    ///
    /// The offset is a hint, not gospel: it is verified against the sentence text before use. When
    /// it does not match, the chapter is not the one the desktop tool saw (a re-import from a
    /// different build of the EPUB), so fall back to finding the sentence by its text — but only
    /// when it appears exactly once, because placing a button on the wrong sentence is worse than
    /// placing none.
    resolve(chapter, anchor) {
        const want = anchor.text || '';
        if (!want) return -1;
        const start = Number(anchor.start);
        const len = Number(anchor.len);
        if (!Number.isSafeInteger(start) || start < 0 ||
            !Number.isSafeInteger(len) || len <= 0) return -1;

        // Wire offsets count Unicode code points. JavaScript's substr/indexOf/string.length use
        // UTF-16 code units, so using them here makes a supplementary-plane ideograph shift every
        // later ends[] lookup. Compare arrays of code points in the same coordinate space instead.
        const wantChars = Array.from(want);
        if (wantChars.length !== len || start > chapter.chars.length - len) return -1;
        for (let i = 0; i < len; i++) {
            if (chapter.chars[start + i] !== wantChars[i]) return -1;
        }
        return start + len - 1;
    },

    /// Moves the insertion point past the punctuation that closes the sentence — the 。 itself,
    /// then any 」 』 ） … that trail it.
    ///
    /// Crosses text-node boundaries, which is not optional: when a sentence ends on a character
    /// inside <ruby>, the ruby base is its own text node and the 。 lives in the parent's NEXT
    /// text node. Stopping at the node edge left the button in front of the full stop instead of
    /// after it, on roughly one sentence in twenty of real furigana'd prose.
    extendPastPunctuation(position) {
        const walker = window.hoshiReader.createWalker();
        let node = position.node;
        let offset = position.offset;
        walker.currentNode = node;
        for (;;) {
            const text = node.textContent;
            while (offset < text.length) {
                const char = String.fromCodePoint(text.codePointAt(offset));
                if (this.trailingChars.indexOf(char) < 0) return { node: node, offset: offset };
                offset += char.length;
            }
            // Exhausted this node. Step into the next one only when it continues the punctuation
            // run, so the button never drifts into the sentence that follows.
            const next = walker.nextNode();
            if (!next) return { node: node, offset: offset };
            const nextText = next.textContent;
            if (nextText.length) {
                const first = String.fromCodePoint(nextText.codePointAt(0));
                if (this.trailingChars.indexOf(first) < 0) return { node: node, offset: offset };
            }
            node = next;
            offset = 0;
        }
    },

    // Punctuation whose glyph sits at the LEFT of its em box, leaving roughly half an em of blank
    // to its right (Japanese full stop, comma, closing brackets). A button after one of these has
    // to be pulled hard to look attached to it.
    wideTrailing: '。、」』）)】〉》〕｝}］]',
    // Punctuation drawn centred in its em box, so there is far less blank to reclaim. Pulling
    // these as hard as the above makes the ring collide with the glyph.
    narrowTrailing: '！？!?…‥',

    /// The character immediately before an insertion point, crossing back into the previous text
    /// node when the point sits at the very start of one.
    charBefore(position) {
        const text = position.node.textContent;
        if (position.offset > 0) return text[position.offset - 1];
        const walker = window.hoshiReader.createWalker();
        walker.currentNode = position.node;
        const previous = walker.previousNode();
        if (!previous) return '';
        const previousText = previous.textContent;
        return previousText.length ? previousText[previousText.length - 1] : '';
    },

    makeButton(id, position) {
        const button = document.createElement('span');
        // How far the button is pulled toward the sentence depends on what it follows: a fixed
        // margin either leaves 。 looking detached or drives the ring into ！.
        const preceding = this.charBefore(position);
        let kind = '';
        if (this.wideTrailing.indexOf(preceding) >= 0) kind = ' hoshi-tl-wide';
        else if (this.narrowTrailing.indexOf(preceding) >= 0) kind = ' hoshi-tl-narrow';
        button.className = 'hoshi-tl' + kind;
        button.setAttribute('role', 'button');
        // Deliberately empty: a text node here would be counted by every character walk in the
        // reader and would silently corrupt bookmark, highlight and cue offsets.
        button.dataset.tl = id;
        return button;
    },

    apply(anchors) {
        this.clear();
        if (!anchors || !anchors.length) return 0;

        const chapter = this.scanChapter();
        if (!chapter.ends.length) return 0;

        const placements = [];
        for (const anchor of anchors) {
            const last = this.resolve(chapter, anchor);
            if (last < 0 || last >= chapter.ends.length) continue;
            placements.push({
                id: anchor.id,
                position: this.extendPastPunctuation(chapter.ends[last])
            });
        }

        // Insert back to front: every insertion splits a text node, which would invalidate the
        // offsets recorded for anchors later in the document.
        for (let i = placements.length - 1; i >= 0; i--) {
            const { id, position } = placements[i];
            const button = this.makeButton(id, position);
            try {
                const range = document.createRange();
                range.setStart(position.node, Math.min(position.offset, position.node.length));
                range.collapse(true);
                range.insertNode(button);
                this.buttons.push(button);
            } catch (e) {
                // A stale offset (the node changed under us) must never take the chapter down.
            }
        }

        // The DOM changed, so anything that caches node offsets has to be rebuilt.
        window.hoshiReader.buildNodeOffsets();
        window.hoshiReader.refreshSasayakiCues?.();
        return this.buttons.length;
    },

    clear() {
        for (const button of this.buttons) {
            const parent = button.parentNode;
            if (parent) {
                parent.removeChild(button);
                parent.normalize();
            }
        }
        this.buttons = [];
    }
};
