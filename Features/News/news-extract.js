// Runs inside the hidden news WebView (see WebViewNewsExtractor). Defines
// window.hoshiNewsExtract(options) and returns a JSON string:
//   listing: {ready, items:[{url,title,publishedAt,imageUrl}]}
//   article: {ready, url, title, xhtml, text, publishedAt, imageUrl}
// "ready" is false while a client-rendered page has not produced its content yet; the host
// keeps polling until it flips to true or a timeout expires.
(function () {
    if (window.hoshiNewsExtract) return;

    var BLOCK_TAGS = ['P', 'DIV', 'LI', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'BLOCKQUOTE', 'FIGURE', 'FIGCAPTION', 'TR', 'BR', 'SECTION', 'ARTICLE'];
    var JUNK_SELECTOR = 'script, style, noscript, iframe, form, button, input, select, textarea, svg, canvas, video, audio, template, [aria-hidden="true"], [hidden]';

    function japaneseLength(text) {
        var count = 0;
        for (var i = 0; i < text.length; i++) {
            var code = text.charCodeAt(i);
            if ((code >= 0x3040 && code <= 0x30ff) || (code >= 0x4e00 && code <= 0x9fff) || (code >= 0xff66 && code <= 0xff9f)) count++;
        }
        return count;
    }

    function visibleText(node) {
        var clone = node.cloneNode(true);
        clone.querySelectorAll('rt, rp, ' + JUNK_SELECTOR).forEach(function (el) { el.remove(); });
        return (clone.textContent || '').replace(/\s+/g, ' ').trim();
    }

    function absolute(url) {
        if (!url) return null;
        try { return new URL(url, document.baseURI).toString(); } catch (e) { return null; }
    }

    function parseDate(value) {
        if (!value) return null;
        var text = String(value).trim();
        var ms = Date.parse(text);
        if (!isNaN(ms)) return ms;
        // 2025年9月8日 12時34分 / 2025/09/08 12:34 / 9月8日
        var m = text.match(/(\d{4})[年\/.-](\d{1,2})[月\/.-](\d{1,2})日?(?:[^\d]*(\d{1,2})[時:](\d{1,2}))?/);
        if (m) {
            var d = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]), Number(m[4] || 0), Number(m[5] || 0));
            return isNaN(d.getTime()) ? null : d.getTime();
        }
        return null;
    }

    function nearestDate(el) {
        var scope = el;
        for (var depth = 0; depth < 4 && scope; depth++, scope = scope.parentElement) {
            var time = scope.querySelector('time[datetime], time');
            if (time) {
                var parsed = parseDate(time.getAttribute('datetime') || time.textContent);
                if (parsed) return parsed;
            }
        }
        return null;
    }

    function firstMatching(selectors) {
        for (var i = 0; i < selectors.length; i++) {
            try {
                var found = document.querySelector(selectors[i]);
                if (found) return found;
            } catch (e) { /* invalid selector in hints */ }
        }
        return null;
    }

    function metaContent(names) {
        for (var i = 0; i < names.length; i++) {
            var meta = document.querySelector('meta[property="' + names[i] + '"], meta[name="' + names[i] + '"]');
            if (meta && meta.getAttribute('content')) return meta.getAttribute('content');
        }
        return null;
    }

    function pickArticleContainer(hints) {
        var hinted = firstMatching(hints.articleSelectors || []);
        if (hinted && japaneseLength(visibleText(hinted)) >= 40) return hinted;
        var candidates = Array.prototype.slice.call(document.querySelectorAll('article, main, [role="main"], section, div'));
        var best = null;
        var bestScore = 0;
        candidates.forEach(function (el) {
            if (el.closest('nav, header, footer, aside')) return;
            var text = visibleText(el);
            var jp = japaneseLength(text);
            if (jp < 40) return;
            var links = Array.prototype.slice.call(el.querySelectorAll('a'));
            var linkText = links.reduce(function (sum, a) { return sum + (a.textContent || '').length; }, 0);
            var density = text.length ? linkText / text.length : 1;
            var paragraphs = el.querySelectorAll('p').length;
            // Prefer dense text with paragraphs; penalize link farms and huge wrappers (body).
            var score = jp * (1 - density) * (paragraphs > 0 ? 1.2 : 0.8) / Math.sqrt(1 + el.querySelectorAll('*').length / 400);
            if (score > bestScore) { bestScore = score; best = el; }
        });
        return best;
    }

    function cleanClone(container, hints) {
        var clone = container.cloneNode(true);
        var remove = JUNK_SELECTOR + ', nav, header, footer, aside';
        (hints.removeSelectors || []).forEach(function (selector) { remove += ', ' + selector; });
        try { clone.querySelectorAll(remove).forEach(function (el) { el.remove(); }); } catch (e) {
            clone.querySelectorAll(JUNK_SELECTOR).forEach(function (el) { el.remove(); });
        }
        clone.querySelectorAll('img').forEach(function (img) {
            var src = img.getAttribute('src') || img.getAttribute('data-src') || (img.getAttribute('srcset') || '').split(/\s|,/)[0];
            var abs = absolute(src);
            if (abs) img.setAttribute('src', abs); else img.remove();
        });
        clone.querySelectorAll('[style]').forEach(function (el) { el.removeAttribute('style'); });
        // Drop the headline if the container repeats it; the EPUB writer adds its own <h1>.
        var title = extractTitle(hints);
        clone.querySelectorAll('h1, h2').forEach(function (h) {
            // Compare without furigana: a headline wrapped in <ruby> still repeats the title.
            if (visibleText(h) === title) h.remove();
        });
        return clone;
    }

    function extractTitle(hints) {
        var hinted = firstMatching(hints.titleSelectors || []);
        var text = hinted ? visibleText(hinted) : '';
        if (!text) text = metaContent(['og:title', 'twitter:title']) || '';
        if (!text) text = (document.title || '').split(/\s[|｜-]\s/)[0];
        return text.trim();
    }

    // NHK ONE shows a one-time "For users abroad: text is available, some videos are not —
    // I understand" notice before any content renders outside Japan. Only a source that names the
    // button (hints.acknowledgeSelector) is allowed to click it, at most once per page load, and
    // the click is the same one a reader would make in a browser; the site remembers the choice.
    var gateDebug = null;

    function acknowledgeAccessNotice(hints) {
        var selector = hints && hints.acknowledgeSelector;
        if (!selector || window.__hoshiNewsGateClicked) return false;
        var target = null;
        try { target = document.querySelector(selector); } catch (e) { return false; }
        if (!target) return false;
        window.__hoshiNewsGateClicked = true;
        gateDebug = {
            target: (target.outerHTML || '').substring(0, 300),
            disabled: !!target.disabled,
            cookies: (document.cookie || '').substring(0, 120)
        };
        try {
            ['pointerdown', 'mousedown', 'pointerup', 'mouseup'].forEach(function (type) {
                target.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, view: window }));
            });
            target.click();
        } catch (e) { gateDebug.clickError = String(e); }
        return true;
    }

    function extractArticle(options) {
        var hints = options.hints || {};
        if (acknowledgeAccessNotice(hints)) return { ready: false, url: location.href, title: '', xhtml: '', text: '', gate: true, debug: gateDebug };
        var ready = true;
        if (hints.readySelector) {
            try { ready = !!document.querySelector(hints.readySelector); } catch (e) { ready = true; }
        }
        var container = pickArticleContainer(hints);
        if (!container) return { ready: false, url: location.href, title: extractTitle(hints), xhtml: '', text: '' };
        var clone = cleanClone(container, hints);
        var text = visibleText(clone);
        var xhtml = '';
        try { xhtml = new XMLSerializer().serializeToString(clone); } catch (e) { xhtml = ''; }
        var published = parseDate(metaContent(['article:published_time', 'og:article:published_time', 'date', 'pubdate'])) || nearestDate(container);
        var image = absolute(metaContent(['og:image', 'twitter:image']));
        if (!image) {
            var firstImg = clone.querySelector('img');
            image = firstImg ? firstImg.getAttribute('src') : null;
        }
        return {
            ready: ready && japaneseLength(text) >= 40,
            url: location.href,
            title: extractTitle(hints),
            xhtml: xhtml,
            text: text,
            publishedAt: published,
            imageUrl: image
        };
    }

    function extractListing(options) {
        if (acknowledgeAccessNotice(options.hints)) return { ready: false, items: [], gate: true, debug: gateDebug };
        var pattern = null;
        try { pattern = options.articleUrlPattern ? new RegExp('^' + options.articleUrlPattern + '$') : null; } catch (e) { pattern = null; }
        var seen = {};
        var items = [];
        Array.prototype.slice.call(document.querySelectorAll('a[href]')).forEach(function (anchor) {
            var url = absolute(anchor.getAttribute('href'));
            if (!url) return;
            url = url.replace(/[#?].*$/, '');
            if (pattern && !pattern.test(url)) return;
            if (!pattern && !/\/\d{4,}/.test(url)) return;
            if (seen[url]) return;
            var card = anchor.closest('article, li, section, [class*="item"], [class*="card"], [class*="list"]') || anchor;
            var titleEl = card.querySelector('h1, h2, h3, h4, [class*="title"]') || anchor;
            var title = visibleText(titleEl) || visibleText(anchor) || (anchor.querySelector('img') || {}).alt || '';
            if (!title) return;
            seen[url] = true;
            var img = card.querySelector('img');
            items.push({
                url: url,
                title: title,
                publishedAt: nearestDate(card),
                imageUrl: img ? absolute(img.getAttribute('src') || img.getAttribute('data-src')) : null
            });
        });
        var anchors = Array.prototype.slice.call(document.querySelectorAll('a[href]'));
        return {
            ready: items.length > 0,
            items: items,
            // Surfaced in the "no articles" error so a site redesign can be diagnosed from the device.
            debug: {
                readyState: document.readyState,
                viewport: window.innerWidth + 'x' + window.innerHeight,
                anchorCount: anchors.length,
                easyHrefs: anchors.map(function (a) { return a.getAttribute('href') || ''; })
                    .filter(function (h) { return /easy|ne20\d{9,}/.test(h); }).slice(0, 20),
                clickableCount: document.querySelectorAll('[role="link"], [role="button"], [onclick]').length,
                neSnippet: (function () {
                    var html = document.body ? document.body.innerHTML : '';
                    var at = html.search(/ne20\d{9,}/);
                    return at < 0 ? null : html.substring(Math.max(0, at - 160), at + 120);
                })(),
                textLength: (document.body ? (document.body.textContent || '').length : 0)
            }
        };
    }

    window.hoshiNewsExtract = function (options) {
        options = options || {};
        try {
            var result = options.mode === 'listing' ? extractListing(options) : extractArticle(options);
            return JSON.stringify(result);
        } catch (e) {
            return JSON.stringify({ ready: false, error: String(e && e.message || e) });
        }
    };
})();
