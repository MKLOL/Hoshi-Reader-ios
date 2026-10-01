// Podcast navigation around the EPUB reader's existing ruby layout and word selection.
// Text and readings enter through DOM text nodes, never through parsed episode HTML.
window.hoshiTranscript = {
    lines: [],
    layoutRevision: 0,
    state: { current: null, following: true, showEnglish: false },

    setDocument(lines) {
        this.layoutRevision++;
        this.clearSelection();
        this.lines = lines;
        delete document.documentElement.dataset.readingsReady;
        const container = document.getElementById('transcript');
        container.replaceChildren();
        lines.forEach((line, index) => {
            const article = document.createElement('article');
            article.id = 'podcast-line-' + index;
            article.dataset.index = index;
            const button = document.createElement('button');
            button.id = 'podcast-time-' + index;
            button.textContent = line.time;
            button.setAttribute('aria-label', line.playLabel);
            button.addEventListener('click', () => {
                this.clearSelection();
                webkit.messageHandlers.podcastPlay.postMessage(index);
            });
            const text = document.createElement('p');
            text.id = 'podcast-text-' + index;
            text.className = 'japanese';
            text.dataset.index = index;
            text.textContent = line.text;
            article.append(button, text);
            if (line.english) {
                const english = document.createElement('div');
                english.className = 'english';
                english.textContent = line.english;
                article.append(english);
            }
            container.append(article);
        });
        this.update(this.state, true);
    },

    setReadings(readingsByLine) {
        // Reflow must not jump a reader who has scrolled away from the playing line.
        this.layoutRevision++;
        const anchor = this.visibleAnchor();
        this.clearSelection();
        readingsByLine.forEach((annotations, index) => {
            const paragraph = document.getElementById('podcast-text-' + index);
            const original = this.lines[index]?.text;
            if (!paragraph || typeof original !== 'string') return;
            const content = document.createDocumentFragment();
            let offset = 0;
            for (const annotation of annotations) {
                const {start, length, reading} = annotation;
                if (!Number.isInteger(start) || !Number.isInteger(length) ||
                    start < offset || length <= 0 || start > original.length ||
                    length > original.length - start || typeof reading !== 'string') continue;
                content.append(document.createTextNode(original.slice(offset, start)));
                const base = original.slice(start, start + length);
                for (const [text, kana] of segmentFurigana(base, reading, {strict: true})) {
                    if (!kana) {
                        content.append(document.createTextNode(text));
                    } else {
                        // The same native HTML ruby structure used by EPUB chapters.
                        const ruby = document.createElement('ruby');
                        const span = document.createElement('span');
                        span.textContent = text;
                        const rt = document.createElement('rt');
                        rt.textContent = kana;
                        ruby.append(span, rt);
                        content.append(ruby);
                    }
                }
                offset = start + length;
            }
            content.append(document.createTextNode(original.slice(offset)));
            paragraph.replaceChildren(content);
        });
        document.documentElement.dataset.readingsReady = 'true';
        if (this.state.following) this.revealCurrent();
        else this.restoreAnchor(anchor);
    },

    update(state, force = false) {
        const previous = this.state;
        const anchor = this.visibleAnchor();
        this.state = state;
        if (previous.showEnglish !== state.showEnglish) this.layoutRevision++;
        document.body.classList.toggle('show-english', state.showEnglish);
        if (previous.current !== state.current || force) {
            document.querySelector('.current')?.classList.remove('current');
            document.getElementById('podcast-line-' + state.current)?.classList.add('current');
        }
        if (state.following && (force || !previous.following || previous.current !== state.current)) {
            this.revealCurrent();
        } else if (previous.showEnglish !== state.showEnglish) {
            this.restoreAnchor(anchor);
        }
    },

    visibleAnchor() {
        const text = document.elementFromPoint(24, 24)?.closest('article') ||
            Array.from(document.querySelectorAll('article')).find(line => line.getBoundingClientRect().bottom > 0);
        return text ? {id: text.id, top: text.getBoundingClientRect().top} : null;
    },
    restoreAnchor(anchor) {
        const line = anchor && document.getElementById(anchor.id);
        if (line) window.scrollBy(0, line.getBoundingClientRect().top - anchor.top);
    },
    userScrolled() {
        this.layoutRevision++;
        this.state = {...this.state, following: false};
        this.clearSelection();
    },
    revealCurrent() {
        this.layoutRevision++;
        const line = document.getElementById('podcast-line-' + this.state.current);
        if (line) window.scrollBy(0, line.getBoundingClientRect().top - window.innerHeight * 0.2);
    },

    selectAt(x, y, maxLength = 16) {
        const element = document.elementFromPoint(x, y);
        // Buttons use their ordinary browser activation, including VoiceOver.
        if (element?.closest('button')) return;
        const paragraph = element?.closest('p.japanese');
        if (!paragraph) {
            this.clearSelection();
            webkit.messageHandlers.podcastOutside.postMessage(null);
            return;
        }
        if (!window.hoshiSelection.selectText(x, y, maxLength)) {
            webkit.messageHandlers.podcastOutside.postMessage(null);
        }
    },
    clearSelection() {
        window.hoshiSelection.clearSelection();
    }
};
