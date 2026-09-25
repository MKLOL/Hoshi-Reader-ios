//
//  scrollreader.js
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
    
    // Sentence-translation buttons are chrome, not text — see reader.js.
    isTranslationButton(node) {
        const el = node.nodeType === Node.TEXT_NODE ? node.parentElement : node;
        return !!el?.closest('.hoshi-tl');
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
        const rect = target.getClientRects()[0];
        return rect || target.getBoundingClientRect();
    },
    
    scrollToTarget(target) {
        const rect = this.getRect(target);
        const vertical = this.isVertical();
        if (vertical) {
            if (rect.left >= 0 && rect.right <= window.innerWidth) {
                return false;
            }
        } else if (rect.top >= 0 && rect.bottom <= window.innerHeight) {
            return false;
        }
        if (typeof target.scrollIntoView === 'function') {
            target.scrollIntoView({ block: 'start', inline: 'nearest' });
        } else {
            // A CSS Highlight target is a Range, not an Element. Align the first line to the
            // leading edge in continuous mode, including negative horizontal scroll in vertical text.
            const root = document.scrollingElement || document.documentElement;
            if (vertical) {
                const current = window.scrollX || root.scrollLeft;
                const left = current + rect.right - window.innerWidth;
                window.scrollTo({ left, top: window.scrollY, behavior: 'instant' });
                root.scrollLeft = left;
            } else {
                const current = root.scrollTop || window.scrollY;
                const top = current + rect.top;
                window.scrollTo({ left: window.scrollX, top, behavior: 'instant' });
                root.scrollTop = top;
            }
        }
        return true;
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
        
        while (node = walker.nextNode()) {
            var nodeLen = this.countChars(node.textContent);
            totalChars += nodeLen;
            
            if (nodeLen > 0) {
                var range = document.createRange();
                range.selectNodeContents(node);
                var rect = range.getBoundingClientRect();
                if (vertical ? (rect.left > window.innerWidth) : (rect.bottom < 0)) {
                    exploredChars += nodeLen;
                }
            }
        }
        
        return totalChars > 0 ? exploredChars / totalChars : 0;
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
        if (reveal && this.scrollToTarget(targets[0])) return this.calculateProgress();
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
    
    async restoreProgress(progress) {
        await document.fonts.ready;
        if (progress <= 0) {
            this.notifyRestoreComplete();
            return;
        }
        
        var vertical = this.isVertical();
        var walker = this.createWalker();
        var totalChars = 0;
        var node;
        
        while (node = walker.nextNode()) {
            totalChars += this.countChars(node.textContent);
        }
        
        if (totalChars <= 0) {
            this.notifyRestoreComplete();
            return;
        }
        
        var targetCharCount = Math.ceil(totalChars * progress);
        var runningSum = 0;
        var targetNode = null;
        
        walker = this.createWalker();
        while (node = walker.nextNode()) {
            runningSum += this.countChars(node.textContent);
            targetNode = node;
            if (runningSum > targetCharCount) {
                break;
            }
        }
        
        if (targetNode) {
            var el = targetNode.parentElement;
            if (el) {
                el.scrollIntoView({
                    block: progress >= 0.999999 ? 'end' : 'start',
                    behavior: 'instant'
                });
            }
        }
        
        requestAnimationFrame(() => {
            requestAnimationFrame(() => this.notifyRestoreComplete());
        });
    },
    
    async jumpToFragment(fragment) {
        await document.fonts.ready;
        var rawFragment = (fragment || '').trim();
        var target = rawFragment && (document.getElementById(rawFragment) || document.getElementsByName(rawFragment)[0]);
        
        if (!target) {
            this.notifyRestoreComplete();
            return false;
        }
        
        target.scrollIntoView();
        requestAnimationFrame(() => {
            requestAnimationFrame(() => this.notifyRestoreComplete());
        });
        return true;
    }
};
