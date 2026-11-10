//
//  reader.js
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

window.hoshiReader = {
    ttuRegexNegated: /[^0-9A-Za-z○◯々-〇〻ぁ-ゖゝ-ゞァ-ヺー０-９Ａ-Ｚａ-ｚｦ-ﾝ\p{Radical}\p{Unified_Ideograph}]+/gimu,
    ttuRegex: /[0-9A-Za-z○◯々-〇〻ぁ-ゖゝ-ゞァ-ヺー０-９Ａ-Ｚａ-ｚｦ-ﾝ\p{Radical}\p{Unified_Ideograph}]/iu,
    activeCueId: null,
    cueWrappers: new Map(),
    cueRanges: new Map(),
    cueRubyElements: new Map(),
    cueTargets: new Map(),
    sasayakiCues: [],
    nodeStartOffsets: new WeakMap(),
    nodeStartRawOffsets: new WeakMap(),

    isVertical() {
        return window.getComputedStyle(document.body).writingMode === "vertical-rl";
    },
    
    isFurigana(node) {
        const el = node.nodeType === Node.TEXT_NODE ? node.parentElement : node;
        return !!el?.closest('rt, rp');
    },
    
    // Sentence-translation buttons are chrome, not text. They carry no text node today, so this is
    // defensive — but every offset in the reader (bookmarks, highlights, Sasayaki cues) is counted
    // by these walkers, so the guard is cheap next to the failure it prevents.
    isTranslationButton(node) {
        const el = node.nodeType === Node.TEXT_NODE ? node.parentElement : node;
        return !!el?.closest('.hoshi-tl');
    },

    countChars(text) {
        return Array.from(this.normalizeText(text)).length;
    },
    
    countRawChars(text) {
        return Array.from(text).length;
    },
    
    normalizeText(text) {
        return text.replace(this.ttuRegexNegated, '');
    },
    
    isMatchableChar(char) {
        return this.ttuRegex.test(char || '');
    },
    
    createWalker(rootNode) {
        const root = rootNode || document.body;
        
        return document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
            acceptNode: (n) => (this.isFurigana(n) || this.isTranslationButton(n))
                ? NodeFilter.FILTER_REJECT
                : NodeFilter.FILTER_ACCEPT
        });
    },
    
    getRect(target) {
        let rect = target.getClientRects()[0];
        if (!rect && target.nodeType === Node.ELEMENT_NODE && target.firstChild) {
            // A sentence-break host (display: contents), such as a fragment target, has no
            // box of its own; its text does.
            const contents = document.createRange();
            contents.selectNodeContents(target);
            rect = contents.getClientRects()[0];
        }
        return rect || target.getBoundingClientRect();
    },
    
    buildNodeOffsets() {
        const offsets = new WeakMap();
        const rawOffsets = new WeakMap();
        const walker = this.createWalker();
        let count = 0;
        let rawCount = 0;
        let node;
        
        while (node = walker.nextNode()) {
            offsets.set(node, count);
            rawOffsets.set(node, rawCount);
            count += this.countChars(node.textContent);
            rawCount += this.countRawChars(node.textContent);
        }
        
        this.nodeStartOffsets = offsets;
        this.nodeStartRawOffsets = rawOffsets;
    },
    
    calculateProgress() {
        var vertical = this.isVertical();
        var walker = this.createWalker();
        var totalChars = 0;
        var exploredChars = 0;
        var node;
        // One range for the whole walk. A page turn reads every text node of the chapter, and a
        // range made for each one stays registered with the document until it is collected.
        var range = document.createRange();
        
        while (node = walker.nextNode()) {
            var nodeLen = this.countChars(node.textContent);
            totalChars += nodeLen;
            
            if (nodeLen > 0) {
                range.selectNodeContents(node);
                var rect = this.getRect(range);
                if ((vertical ? rect.top : rect.left) < 0) {
                    exploredChars += nodeLen;
                }
            }
        }
        
        return totalChars > 0 ? exploredChars / totalChars : 0;
    },
    
    registerSnapScroll(initialScroll) {
        if (window.snapScrollRegistered) {
            return;
        }
        window.snapScrollRegistered = true;
        window.lastPageScroll = initialScroll;
        
        var vertical = this.isVertical();
        var pageHeight = this.pageHeight;
        var pageWidth = this.pageWidth;
        document.body.addEventListener('scroll', function () {
            if (vertical) {
                var currentScroll = document.body.scrollTop;
                var snappedScroll = Math.round(currentScroll / pageHeight) * pageHeight;
                if (Math.abs(currentScroll - snappedScroll) > 1) {
                    document.body.scrollTop = window.lastPageScroll;
                } else {
                    window.lastPageScroll = snappedScroll;
                }
            } else {
                var currentScroll = document.body.scrollLeft;
                var snappedScroll = Math.round(currentScroll / pageWidth) * pageWidth;
                if (Math.abs(currentScroll - snappedScroll) > 1) {
                    document.body.scrollLeft = window.lastPageScroll;
                } else {
                    window.lastPageScroll = snappedScroll;
                }
            }
        }, { passive: true });
    },
    
    registerCopyText() {
        if (window.copyTextRegistered) {
            return;
        }
        window.copyTextRegistered = true
        document.addEventListener('copy', function (event) {
            const selection = window.getSelection();
            if (!selection || selection.rangeCount === 0) {
                return;
            }
            const fragment = selection.getRangeAt(0).cloneContents();
            fragment.querySelectorAll('rt, rp').forEach(el => el.remove());
            const text = fragment.textContent;
            if (!text) {
                return;
            }
            event.preventDefault();
            event.clipboardData.setData('text/plain', text);
        }, true);
    },
    
    notifyRestoreComplete() {
        window.webkit?.messageHandlers?.restoreCompleted?.postMessage(null);
    },
    
    getScrollContext() {
        var vertical = this.isVertical();
        var scrollEl = document.body;
        var pageSize = vertical ? this.pageHeight : this.pageWidth;
        var totalSize = vertical ? scrollEl.scrollHeight : scrollEl.scrollWidth;
        var maxScroll = Math.max(0, totalSize - pageSize);
        return { vertical, scrollEl, pageSize, maxScroll };
    },
    
    getPagePosition(context) {
        return context.vertical ? context.scrollEl.scrollTop : context.scrollEl.scrollLeft;
    },

    setPagePosition(context, scroll) {
        window.lastPageScroll = scroll;
        return this.setScrollOffset(context, scroll);
    },

    textOffsetForCharCount(node, count) {
        const text = node.textContent;
        let running = 0;
        for (let offset = 0; offset < text.length;) {
            const character = String.fromCodePoint(text.codePointAt(offset));
            if (this.isMatchableChar(character) && running++ >= count) return offset;
            offset += character.length;
        }
        return text.length;
    },

    setScrollOffset(context, scroll) {
        var clampedScroll = Math.min(Math.max(0, scroll), context.maxScroll);
        if (context.vertical) {
            context.scrollEl.scrollTop = clampedScroll;
        } else {
            context.scrollEl.scrollLeft = clampedScroll;
        }
        return clampedScroll;
    },
    
    alignToPage(context, anchor) {
        if (context.pageSize <= 0) {
            return 0;
        }
        var pageIndex = Math.floor(Math.max(0, anchor) / context.pageSize);
        return Math.min(Math.max(0, pageIndex * context.pageSize), context.maxScroll);
    },
    
    paginate(direction) {
        var vertical = this.isVertical();
        var pageSize = vertical ? this.pageHeight : this.pageWidth;
        if (pageSize <= 0) return "limit";
        
        if (direction === "forward") {
            var totalSize = vertical ? document.body.scrollHeight : document.body.scrollWidth;
            var maxScroll = Math.max(0, totalSize - pageSize);
            var maxAlignedScroll = Math.floor(maxScroll / pageSize) * pageSize;
            var currentScroll = vertical ? document.body.scrollTop : document.body.scrollLeft;
            if ((currentScroll + pageSize) <= (maxAlignedScroll + 1)) {
                var targetScroll = Math.round((currentScroll + pageSize) / pageSize) * pageSize;
                window.lastPageScroll = targetScroll;
                if (vertical) { document.body.scrollTop = targetScroll; } else { document.body.scrollLeft = targetScroll; }
                return "scrolled";
            }
            return "limit";
        } else {
            var currentScroll = vertical ? document.body.scrollTop : document.body.scrollLeft;
            if (currentScroll > 0) {
                var targetScroll = Math.round((currentScroll - pageSize) / pageSize) * pageSize;
                window.lastPageScroll = targetScroll;
                if (vertical) { document.body.scrollTop = targetScroll; } else { document.body.scrollLeft = targetScroll; }
                return "scrolled";
            }
            return "limit";
        }
    },
    
    scrollToRange(range) {
        const context = this.getScrollContext();
        if (context.pageSize <= 0) {
            return false;
        }
        
        const rect = this.getRect(range);
        const currentScroll = context.vertical ? context.scrollEl.scrollTop : context.scrollEl.scrollLeft;
        const anchor = (context.vertical ? (rect.top + rect.bottom) / 2 : (rect.left + rect.right) / 2) + currentScroll;
        const targetScroll = this.alignToPage(context, anchor);
        
        if (targetScroll === currentScroll) {
            return false;
        }
        
        window.lastPageScroll = targetScroll;
        this.setScrollOffset(context, targetScroll);
        requestAnimationFrame(() => {
            this.setScrollOffset(context, targetScroll);
        });
        
        return true;
    },
    
    collectSasayakiCueRanges(cues) {
        const cueRanges = new Map();
        if (!cues.length) {
            return [];
        }
        
        let index = 0;
        let current = cues[0];
        let start = current.start;
        let end = start + current.length;
        let cursor = 0;
        let segment = null;
        
        const flushSegment = (node) => {
            if (!segment) {
                return;
            }
            
            const ranges = cueRanges.get(segment.id) || [];
            ranges.push({ node, start: segment.start, end: segment.end });
            cueRanges.set(segment.id, ranges);
            segment = null;
        };
        
        const advanceCue = () => {
            index += 1;
            current = cues[index];
            if (current) {
                start = current.start;
                end = start + current.length;
            }
        };
        
        let node;
        const walker = this.createWalker();
        while (current && (node = walker.nextNode())) {
            const text = node.textContent;
            let i = 0;
            while (i < text.length && current) {
                const char = String.fromCodePoint(text.codePointAt(i));
                const next = i + char.length;
                if (this.isMatchableChar(char)) {
                    if (cursor >= start && cursor < end) {
                        if (!segment) {
                            segment = { id: current.id, start: i, end: next };
                        } else {
                            segment.end = next;
                        }
                    } else {
                        flushSegment(node);
                    }
                    cursor += 1;
                    if (cursor === end) {
                        flushSegment(node);
                        advanceCue();
                    }
                } else if (segment) {
                    segment.end = next;
                }
                i = next;
            }
            flushSegment(node);
        }
        
        return cues.map(cue => ({
            id: cue.id,
            ranges: cueRanges.get(cue.id) || []
        }));
    },
    
    supportsSasayakiRangeHighlights() {
        return !!(window.CSS && CSS.highlights && window.Highlight);
    },

    cueNeedsWrapper(cue) {
        return cue.ranges.some(segment => {
            let element = segment.node.parentElement;
            while (element && element !== document.body) {
                const style = window.getComputedStyle(element);
                const emphasis = style.webkitTextEmphasisStyle || style.textEmphasisStyle || 'none';
                if (emphasis !== 'none') return true;
                element = element.parentElement;
            }
            return false;
        });
    },

    applySasayakiCues(cues) {
        const active = this.activeCueId;
        this.resetSasayakiCues();
        this.sasayakiCues = cues;
        const cueRanges = this.collectSasayakiCueRanges([...cues].sort((a, b) => a.start - b.start));
        const fallback = [];
        for (const cue of cueRanges) {
            if (!this.supportsSasayakiRangeHighlights() || this.cueNeedsWrapper(cue)) {
                fallback.push(cue);
                continue;
            }
            const ranges = [], rubies = [], targets = [];
            for (const segment of cue.ranges) {
                const ruby = segment.node.parentElement?.closest('ruby');
                if (ruby) {
                    if (!rubies.includes(ruby)) { rubies.push(ruby); targets.push(ruby); }
                } else {
                    const range = document.createRange();
                    range.setStart(segment.node, segment.start);
                    range.setEnd(segment.node, segment.end);
                    ranges.push(range);
                    targets.push(range);
                }
            }
            this.cueRanges.set(cue.id, ranges);
            this.cueRubyElements.set(cue.id, rubies);
            this.cueTargets.set(cue.id, targets);
        }
        this.wrapSasayakiCueRanges(fallback);
        this.buildNodeOffsets();
        if (active) this.highlightSasayakiCue(active, false);
    },

    refreshSasayakiCues() {
        if (this.sasayakiCues.length) this.applySasayakiCues(this.sasayakiCues);
    },

    wrapSasayakiCueRanges(cueRanges) {
        const range = document.createRange();
        for (let i = cueRanges.length - 1; i >= 0; i--) {
            const { id, ranges } = cueRanges[i];
            if (!ranges.length) {
                continue;
            }
            
            const wrappers = [];
            for (let j = ranges.length - 1; j >= 0; j--) {
                const segment = ranges[j];
                range.setStart(segment.node, segment.start);
                range.setEnd(segment.node, segment.end);
                
                const wrapper = document.createElement('span');
                wrapper.className = 'hoshi-sasayaki-cue';
                wrapper.appendChild(range.extractContents());
                range.insertNode(wrapper);
                
                wrappers.push(wrapper);
            }
            wrappers.reverse();
            this.cueWrappers.set(id, wrappers);
        }
        
    },

    highlightSasayakiCue(cueId, reveal) {
        this.clearSasayakiCue();
        const wrappers = this.cueWrappers.get(cueId) || [];
        const targets = wrappers.length ? wrappers : this.cueTargets.get(cueId) || [];
        if (!targets.length) return null;
        this.activeCueId = cueId;
        wrappers.forEach(wrapper => wrapper.classList.add('hoshi-sasayaki-active'));
        const ranges = this.cueRanges.get(cueId) || [];
        if (ranges.length && this.supportsSasayakiRangeHighlights()) CSS.highlights.set('hoshi-sasayaki', new Highlight(...ranges));
        (this.cueRubyElements.get(cueId) || []).forEach(ruby => ruby.classList.add('hoshi-sasayaki-ruby-active'));
        if (reveal) {
            const target = targets[0];
            const range = document.createRange();
            if (target.nodeType === Node.ELEMENT_NODE) range.selectNodeContents(target);
            if (this.scrollToRange(target.nodeType === Node.ELEMENT_NODE ? range : target)) return this.calculateProgress();
        }
        return null;
    },

    clearSasayakiCue() {
        if (this.supportsSasayakiRangeHighlights()) CSS.highlights.delete('hoshi-sasayaki');
        (this.cueWrappers.get(this.activeCueId) || []).forEach(wrapper => wrapper.classList.remove('hoshi-sasayaki-active'));
        (this.cueRubyElements.get(this.activeCueId) || []).forEach(ruby => ruby.classList.remove('hoshi-sasayaki-ruby-active'));
        this.activeCueId = null;
    },

    resetSasayakiCues() {
        this.clearSasayakiCue();
        this.cueWrappers.forEach(wrappers => this.unwrap(wrappers));
        this.cueWrappers.clear();
        this.cueRanges.clear();
        this.cueRubyElements.clear();
        this.cueTargets.clear();
    },

    unwrap(wrappers) {
        wrappers.forEach(wrapper => {
            const parent = wrapper.parentNode;
            if (!parent) {
                return;
            }
            while (wrapper.firstChild) {
                parent.insertBefore(wrapper.firstChild, wrapper);
            }
            parent.removeChild(wrapper);
            parent.normalize();
        });
    },
    
    async restoreProgress(progress) {
        await document.fonts.ready;
        var context = this.getScrollContext();
        
        if (context.pageSize <= 0) {
            this.registerSnapScroll(0);
            this.notifyRestoreComplete();
            return;
        }
        
        if (progress <= 0) {
            this.setScrollOffset(context, 0);
            this.registerSnapScroll(0);
            this.notifyRestoreComplete();
            return;
        }
        
        if (progress >= 0.99) {
            var lastPage = Math.floor(context.maxScroll / context.pageSize) * context.pageSize;
            lastPage = Math.max(0, lastPage);
            this.setScrollOffset(context, lastPage);
            requestAnimationFrame(() => {
                this.setScrollOffset(context, lastPage);
                this.registerSnapScroll(lastPage);
                requestAnimationFrame(() => this.notifyRestoreComplete());
            });
            return;
        }
        
        var walker = this.createWalker();
        var totalChars = 0;
        var node;
        
        while (node = walker.nextNode()) {
            totalChars += this.countChars(node.textContent);
        }
        
        if (totalChars <= 0) {
            this.registerSnapScroll(0);
            this.notifyRestoreComplete();
            return;
        }
        
        var targetCharCount = Math.ceil(totalChars * progress);
        var runningSum = 0;
        var targetNode = null;
        
        walker = this.createWalker();
        while (node = walker.nextNode()) {
            runningSum += this.countChars(node.textContent);
            if (runningSum > targetCharCount) {
                targetNode = node;
                break;
            }
        }
        
        if (targetNode) {
            // A node can open with whitespace that the layout collapsed. It has no box, so a range
            // over it reads as the origin and would restore the position to the first page.
            var text = targetNode.textContent;
            var range = document.createRange();
            var rect = null;
            // The first counted character is nearly always drawn. A node that is not displayed at
            // all has no box anywhere, so only its first few characters are tried.
            for (var offset = this.textOffsetForCharCount(targetNode, 0), tries = 0; offset < text.length && tries < 16 && !rect; tries++) {
                var length = String.fromCodePoint(text.codePointAt(offset)).length;
                range.setStart(targetNode, offset);
                range.setEnd(targetNode, offset + length);
                var box = range.getClientRects()[0];
                if (box && (box.width > 0 || box.height > 0)) rect = box;
                offset += length;
            }
            if (!rect) {
                range.selectNodeContents(targetNode);
                rect = this.getRect(range);
            }
            var anchor = (context.vertical ? rect.top : rect.left) + (context.vertical ? context.scrollEl.scrollTop : context.scrollEl.scrollLeft);
            var targetScroll = this.alignToPage(context, anchor);
            
            this.setScrollOffset(context, targetScroll);
            requestAnimationFrame(() => {
                this.setScrollOffset(context, targetScroll);
                this.registerSnapScroll(targetScroll);
            });
        } else {
            this.registerSnapScroll(0);
        }
        
        requestAnimationFrame(() => {
            requestAnimationFrame(() => this.notifyRestoreComplete());
        });
    },
    
    async jumpToFragment(fragment) {
        await document.fonts.ready;
        var context = this.getScrollContext();
        var rawFragment = (fragment || '').trim();
        var target = rawFragment && (document.getElementById(rawFragment) || document.getElementsByName(rawFragment)[0]);
        
        if (context.pageSize <= 0 || !target) {
            this.registerSnapScroll(0);
            this.notifyRestoreComplete();
            return false;
        }
        
        var rect = this.getRect(target);
        var currentScroll = context.vertical ? context.scrollEl.scrollTop : context.scrollEl.scrollLeft;
        var anchor = (context.vertical ? rect.top : rect.left) + currentScroll;
        var targetScroll = this.alignToPage(context, anchor);
        
        this.setScrollOffset(context, targetScroll);
        
        requestAnimationFrame(() => {
            this.setScrollOffset(context, targetScroll);
            this.registerSnapScroll(targetScroll);
            requestAnimationFrame(() => this.notifyRestoreComplete());
        });
        
        return true;
    }
};
