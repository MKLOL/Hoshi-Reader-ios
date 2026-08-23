//
//  SentenceButtonCss.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  The one definition of how a sentence-translation button looks.
//
//  Both readers inject it: the paginated `ReaderWebView` and the continuous
//  `ScrollReaderWebView`. It lives here because it was duplicated in both, each copy carrying a
//  comment telling the next person to keep them identical — and the first time the paginated copy
//  was adjusted, continuous mode silently kept the old spacing. A shared constant makes that
//  failure impossible rather than merely discouraged.
//

/// CSS for `.hoshi-tl`, the button `translations.js` inserts after a pre-translated sentence.
///
/// The span is deliberately EMPTY — a text node inside it would be counted by every character walk
/// in the reader and would corrupt bookmark, highlight and Sasayaki offsets. So the ring and dot
/// are drawn entirely with a border and `::before`, and `::after` supplies a larger tap target
/// without affecting layout.
nonisolated let sentenceButtonCss = """
.hoshi-tl {
    display: inline-block;
    position: relative;
    width: 0.6em;
    height: 0.6em;
    /* Logical margins, so this is correct in vertical-rl and horizontal text alike.
       inline-end opens a clear break before the next sentence begins; inline-start is set per
       punctuation class below, because how much blank there is to reclaim depends entirely on
       which glyph the button follows. */
    margin-inline-start: 0;
    margin-inline-end: 0.45em;
    border: 0.07em solid currentColor;
    border-radius: 50%;
    opacity: 0.4;
    cursor: pointer;
    -webkit-user-select: none;
    user-select: none;
}
/* After 。、」』） — the glyph sits at the left of its em box, so there is about half an em of
   blank to reclaim before the ring looks attached to the sentence. */
.hoshi-tl-wide {
    margin-inline-start: -0.36em;
}
/* After ！？…… — drawn centred, with far less blank on the right. Pulling these as hard as the
   wide set drove the ring into the glyph. */
.hoshi-tl-narrow {
    margin-inline-start: -0.06em;
}
.hoshi-tl::before {
    content: '';
    position: absolute;
    left: 50%;
    top: 50%;
    width: 0.18em;
    height: 0.18em;
    margin: -0.09em 0 0 -0.09em;
    border-radius: 50%;
    background: currentColor;
}
.hoshi-tl::after {
    content: '';
    position: absolute;
    left: -0.7em;
    right: -0.7em;
    top: -0.7em;
    bottom: -0.7em;
}
"""
