//
//  selection.js
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

window.hoshiSelection = {
    selection: null,
    scanDelimiters: '。、！？…‥「」『』（）()【】〈〉《》〔〕｛｝{}［］[]・：；:;，,.─\n\r',
    sentenceDelimiters: '。！？.!?\n\r',
    trailingSentenceChars: '。、！？…‥」』）)】〉》〕｝}］]',
    brackets: {'「':'」', '『': '』', '（':'）', '(':')', '【':'】', '〈':'〉', '《':'》', '〔':'〕', '｛':'｝', '{':'}', '［':'］', '[':']'},

    isVertical() {
        return window.getComputedStyle(document.body).writingMode === "vertical-rl";
    },

    isScanBoundary(char) {
        return /^[\s\u3000]$/.test(char) || this.scanDelimiters.includes(char);
    },

    isJapaneseChar(char) {
        return /[\p{Script=Han}\u3040-\u30ff\uff66-\uff9f]/u.test(char);
    },

    isJapaneseText(text) {
        for (const char of text) {
            if (this.isJapaneseChar(char)) {
                return true;
            }
        }
        return false;
    },

    allowsScanText(text) {
        return window.scanNonJapaneseText !== false || this.isJapaneseText(text);
    },
    
    isFurigana(node) {
        const el = node.nodeType === Node.TEXT_NODE ? node.parentElement : node;
        return !!el?.closest('rt, rp');
    },
    
    isTranslationButton(node) {
        const el = node.nodeType === Node.TEXT_NODE ? node.parentElement : node;
        return !!el?.closest('.hoshi-tl');
    },

    findParagraph(node) {
        let el = node.nodeType === Node.TEXT_NODE ? node.parentElement : node;
        return el?.closest('p, .glossary-content') || null;
    },
    
    createWalker(rootNode) {
        const root = rootNode || document.body;

        return document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
            acceptNode: (n) => (this.isFurigana(n) || this.isTranslationButton(n))
                ? NodeFilter.FILTER_REJECT
                : NodeFilter.FILTER_ACCEPT
        });
    },
    
    inCharRange(charRange, x, y) {
        const rects = charRange.getClientRects();
        if (rects.length) {
            for (const rect of rects) {
                if (x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom) {
                    return true;
                }
            }
            return false;
        }
        const rect = charRange.getBoundingClientRect();
        return x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom;
    },

    rectDistance(rect, x, y) {
        const dx = x < rect.left ? rect.left - x : (x > rect.right ? x - rect.right : 0);
        const dy = y < rect.top ? rect.top - y : (y > rect.bottom ? y - rect.bottom : 0);
        return Math.hypot(dx, dy);
    },

    getMangaBoxAtPoint(x, y) {
        const el = document.elementFromPoint(x, y);
        const direct = el?.closest?.('.ocr-box.revealed');
        if (direct) {
            return direct;
        }
        return window.hoshiManga?.hitSlopBoxAt?.(x, y) || null;
    },

    getCharacterInContainerAtPoint(container, x, y) {
        if (!container) {
            return null;
        }

        const walker = this.createWalker(container);
        const range = document.createRange();
        let node;
        let best = null;
        let bestDistance = Infinity;
        const tolerance = 10;

        while (node = walker.nextNode()) {
            const text = node.textContent || '';
            for (let offset = 0; offset < text.length;) {
                const char = String.fromCodePoint(text.codePointAt(offset));
                const end = offset + char.length;
                const start = offset;
                offset = end;
                if (this.isScanBoundary(char)) {
                    continue;
                }
                if (window.scanNonJapaneseText === false && !this.isJapaneseChar(char)) {
                    continue;
                }

                range.setStart(node, start);
                range.setEnd(node, end);
                const rects = range.getClientRects();
                for (const rect of rects) {
                    if (rect.width <= 0 || rect.height <= 0) {
                        continue;
                    }
                    if (x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom) {
                        return { node, offset: start };
                    }
                    const distance = this.rectDistance(rect, x, y);
                    if (distance < bestDistance && distance <= tolerance) {
                        bestDistance = distance;
                        best = { node, offset: start };
                    }
                }
            }
        }

        return best;
    },
    
    getCaretRange(x, y) {
        if (document.caretPositionFromPoint) {
            const pos = document.caretPositionFromPoint(x, y);
            if (!pos) {
                return null;
            }
            
            const range = document.createRange();
            range.setStart(pos.offsetNode, pos.offset);
            range.collapse(true);
            return range;
        } else {
            const element = document.elementFromPoint(x, y);
            if (!element) {
                return null;
            }
            
            const container = element.closest('p, div, span, ruby, a') || document.body;
            const walker = this.createWalker(container);
            
            const range = document.createRange();
            let node;
            while (node = walker.nextNode()) {
                for (let i = 0; i < node.textContent.length;) {
                    const end = i + String.fromCodePoint(node.textContent.codePointAt(i)).length;
                    range.setStart(node, i);
                    range.setEnd(node, end);
                    i = end;
                    if (this.inCharRange(range, x, y)) {
                        range.collapse(true);
                        return range;
                    }
                }
            }
            return document.caretRangeFromPoint(x, y);
        }
    },
    
    getCharacterAtPoint(x, y) {
        const mangaBox = this.getMangaBoxAtPoint(x, y);
        const mangaHit = this.getCharacterInContainerAtPoint(mangaBox, x, y);
        if (mangaHit) {
            return mangaHit;
        }

        const range = this.getCaretRange(x, y);
        if (!range) {
            return null;
        }
        
        const node = range.startContainer;
        if (node.nodeType !== Node.TEXT_NODE) {
            return null;
        }
        
        if (this.isFurigana(node)) {
            return null;
        }
        
        const text = node.textContent;
        const caret = range.startOffset;
        
        for (let offset of [caret, caret - 1, caret + 1]) {
            if (offset > 0 && /[\uDC00-\uDFFF]/.test(text[offset]) && /[\uD800-\uDBFF]/.test(text[offset - 1])) offset--;
            if (offset < 0 || offset >= text.length) {
                continue;
            }
            
            const charRange = document.createRange();
            charRange.setStart(node, offset);
            charRange.setEnd(node, offset + String.fromCodePoint(text.codePointAt(offset)).length);
            if (this.inCharRange(charRange, x, y)) {
                const char = String.fromCodePoint(text.codePointAt(offset));
                if (this.isScanBoundary(char)) {
                    return null;
                }
                if (window.scanNonJapaneseText === false && !this.isJapaneseChar(char)) {
                    return null;
                }
                return { node, offset };
            }
        }
        
        return null;
    },
    
    getSentence(startNode, startOffset) {
        const container = this.findParagraph(startNode) || document.body;
        const walker = this.createWalker(container);
        
        walker.currentNode = startNode;
        const partsBefore = [];
        let node = startNode;
        let limit = startOffset;
        
        while (node) {
            const text = node.textContent;
            let foundStart = false;
            for (let i = limit - 1; i >= 0; i--) {
                if (this.sentenceDelimiters.includes(text[i])) {
                    partsBefore.push(text.slice(i + 1, limit));
                    foundStart = true;
                    break;
                }
            }
            
            if (foundStart) {
                break;
            }
            
            partsBefore.push(text.slice(0, limit));
            node = walker.previousNode();
            if (node) limit = node.textContent.length;
        }
        
        walker.currentNode = startNode;
        const partsAfter = [];
        node = startNode;
        let start = startOffset;
        
        while (node) {
            const text = node.textContent;
            let foundEnd = false;
            
            for (let i = start; i < text.length; i++) {
                if (this.sentenceDelimiters.includes(text[i])) {
                    let end = i + 1;
                    
                    while (end < text.length) {
                        if (!this.trailingSentenceChars.includes(text[end])) break;
                        end += 1;
                    }
                    partsAfter.push(text.slice(start, end));
                    foundEnd = true;
                    break;
                }
            }
            
            if (foundEnd) {
                break;
            }
            
            partsAfter.push(text.slice(start));
            
            node = walker.nextNode();
            start = 0;
        }
        
        let sentence = (partsBefore.reverse().join('') + partsAfter.join('')).trim();

        const closeBrackets = new Set(Object.values(this.brackets));
        const openBrackets = new Set(Object.keys(this.brackets));
        let stack = [];
        let unmatchedClose = [];
        
        for (let i = 0; i < sentence.length; i++) {
            const ch = sentence[i];
            if (openBrackets.has(ch)) {
                stack.push(ch);
            } else if (closeBrackets.has(ch)) {
                if (stack.length > 0 && this.brackets[stack[stack.length-1]] === ch) {
                    stack.pop();
                } else {
                    unmatchedClose.push(ch);
                }
            }
        }

        let startSlice = 0;
        while (stack.length > 0 && startSlice < sentence.length - 1) {
            // Stack consists of unmatched open brackets arranged from start to end
            if (stack[0] === sentence[startSlice]) {
                stack.shift();
            } else break;
            startSlice++;
        }

        let endSlice = sentence.length - 1;
        let endIdx = sentence.length - 1;
        while (unmatchedClose.length > 0 && endIdx > startSlice) {
            if (unmatchedClose[unmatchedClose.length - 1] === sentence[endIdx]) {     
                unmatchedClose.pop();
                endSlice = endIdx - 1;
            // sentenceDelimiters used as trailingSentenceDelimiters as it does not have any overlap with brackets
            } else if (!this.sentenceDelimiters.includes(sentence[endIdx])) break;
            endIdx--;
        }
        return sentence.slice(startSlice, endSlice + 1).trim();
    },
    
    selectText(x, y, maxLength) {
        // A sentence-translation button is handled here rather than with its own click listener:
        // the reader drives selection from a native tap recognizer, so a competing JS listener
        // would race it. Checking first means one tap does exactly one thing.
        const button = document.elementFromPoint(x, y)?.closest?.('.hoshi-tl');
        if (button) {
            this.clearSelection();
            try {
                webkit.messageHandlers.sentenceTranslate.postMessage({ id: button.dataset.tl || '' });
            } catch (e) {}
            return null;
        }

        const hit = this.getCharacterAtPoint(x, y);
        
        if (!hit) {
            this.clearSelection();
            return null;
        }
        
        if (this.selection &&
            hit.node === this.selection.startNode &&
            hit.offset === this.selection.startOffset) {
            this.clearSelection();
            return null;
        }
        
        this.clearSelection();
        
        const container = this.findParagraph(hit.node) || document.body;
        const walker = this.createWalker(container);
        
        let text = '';
        let codePoints = 0;
        let node = hit.node;
        let offset = hit.offset;
        let ranges = [];
        
        walker.currentNode = node;
        while (codePoints < maxLength && node) {
            const content = node.textContent;
            const start = offset;
            
            while (offset < content.length && codePoints < maxLength) {
                const char = String.fromCodePoint(content.codePointAt(offset));
                if (this.isScanBoundary(char)) {
                    break;
                }
                text += char;
                offset += char.length;
                codePoints++;
            }
            
            if (offset > start) {
                ranges.push({ node, start, end: offset });
            }
            
            if (offset < content.length || codePoints >= maxLength) {
                break;
            }
            
            node = walker.nextNode();
            offset = 0;
        }
        
        if (!text) {
            return null;
        }
        if (!this.allowsScanText(text)) {
            this.clearSelection();
            return null;
        }
        
        this.selection = {
            startNode: hit.node,
            startOffset: hit.offset,
            ranges,
            text
        };
        
        const sentence = this.getSentence(hit.node, hit.offset);
        const normalizedOffset = window.hoshiReader ? this.getNormalizedOffset(hit.node, hit.offset) : null;
        const rect = this.getSelectionRect(x, y);
        webkit.messageHandlers.textSelected.postMessage({
            documentIdentity: window.hoshiMangaDocumentIdentity ?? null,
            text,
            sentence,
            rect,
            // Hosts with multiple paragraphs can pair the selection with its original line.
            paragraphId: container.id || null,
            // Manga only (set by getSelectionRect): the tapped block's true writing
            // orientation from the mokuro data. The box aspect ratio is a bad proxy for
            // squat multi-column vertical bubbles (wider than tall), which the popup
            // layout would otherwise treat as horizontal text and cover the bubble.
            verticalBlock: this.lastBlockVertical ?? null,
            normalizedOffset
        });
        
        return text;
    },
    
    getPointSelectionRect(x, y) {
        if (!this.selection?.ranges.length) {
            return null;
        }

        const first = this.selection.ranges[0];
        const range = document.createRange();
        range.setStart(first.node, first.start);
        range.setEnd(first.node, first.start + String.fromCodePoint(first.node.textContent.codePointAt(first.start)).length);

        const rects = Array.from(range.getClientRects());
        const rect = rects.find(rect => x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom) ?? range.getBoundingClientRect();
        return { x: rect.x, y: rect.y, width: rect.width, height: rect.height };
    },

    inflateRect(rect, margin) {
        return {
            x: rect.x - margin,
            y: rect.y - margin,
            width: rect.width + 2 * margin,
            height: rect.height + 2 * margin
        };
    },

    getSelectionRect(x, y) {
        if (!this.selection?.ranges.length) {
            return null;
        }

        // Manga (mokuro) only: anchor the popup to the WHOLE OCR bubble, not the tapped character,
        // so it can be placed clear of the bubble being read. EPUB has no `.ocr-box`, so it keeps
        // using the precise character rect below. When the native WKWebView is zoomed/panned, the
        // whole bubble may be mostly off-screen; anchor to the tapped character so the native popup
        // stays near the word the user pressed. Done here at the source (rather than via a fragile
        // messageHandler shim) so it's reliable. Convert to host coords if the manga bridge is present.
        const selNode = this.selection.startNode;
        const selEl = selNode && (selNode.nodeType === 1 ? selNode : selNode.parentElement);
        const ocrBox = selEl && selEl.closest && selEl.closest('.ocr-box');
        this.lastBlockVertical = null;
        if (ocrBox) {
            let r = null;
            const pointRect = this.getPointSelectionRect(x, y);
            if (window.hoshiManga?.isHostZoomedOrPanned?.() && pointRect) {
                r = this.inflateRect(pointRect, 8);
            } else {
                r = ocrBox.getBoundingClientRect();
                // The revealed (boosted) text can overflow the box; union with the rendered
                // text's own rect so the popup clears the glyphs actually on screen.
                const textEl = ocrBox.querySelector('p');
                if (textEl) {
                    const tr = textEl.getBoundingClientRect();
                    const left = Math.min(r.left, tr.left);
                    const top = Math.min(r.top, tr.top);
                    r = {
                        x: left,
                        y: top,
                        width: Math.max(r.right, tr.right) - left,
                        height: Math.max(r.bottom, tr.bottom) - top
                    };
                }
                // Inflate a touch: the mokuro box hugs the text but the drawn balloon extends
                // past it, so a margin keeps the popup off the balloon outline.
                r = this.inflateRect(r, 8);
            }
            if (window.hoshiManga && window.hoshiManga.hostRectFromViewportRect) {
                r = window.hoshiManga.hostRectFromViewportRect(r);
            }
            this.lastBlockVertical = ocrBox.classList.contains('vertical');
            return { x: r.x, y: r.y, width: r.width, height: r.height };
        }

        return this.getPointSelectionRect(x, y);
    },
    
    highlightSelection(charCount) {
        if (!this.selection?.ranges.length) {
            return;
        }
        
        const highlights = [];
        let remaining = charCount;
        
        for (const r of this.selection.ranges) {
            if (remaining <= 0) {
                break;
            }
            
            let end = r.start;
            while (end < r.end && remaining > 0) {
                const char = String.fromCodePoint(r.node.textContent.codePointAt(end));
                end += char.length;
                remaining--;
            }
            
            const range = document.createRange();
            range.setStart(r.node, r.start);
            range.setEnd(r.node, end);
            highlights.push(range);
        }
        
        CSS.highlights?.set('hoshi-selection', new Highlight(...highlights));
    },
    
    getNormalizedOffset(targetNode, offset) {
        let count = window.hoshiReader.nodeStartOffsets.get(targetNode) ?? 0;
        const text = targetNode.textContent;
        for (let i = 0; i < offset;) {
            const char = String.fromCodePoint(text.codePointAt(i));
            if (window.hoshiReader.isMatchableChar(char)) {
                count++;
            }
            i += char.length;
        }
        return count;
    },
    
    clearSelection() {
        window.getSelection()?.removeAllRanges();
        CSS.highlights?.get('hoshi-selection')?.clear();
        this.selection = null;
    }
};

let lastHasSelection = false;
document.addEventListener('selectionchange', () => {
    const s = getSelection();
    const hasSelection = !!s && !s.isCollapsed;
    if (hasSelection === lastHasSelection) return;
    lastHasSelection = hasSelection;
    try { window.webkit?.messageHandlers?.selectionState?.postMessage(hasSelection); } catch {}
});
