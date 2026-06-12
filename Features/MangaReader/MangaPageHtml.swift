//
//  MangaPageHtml.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Ported from the Android `features/mangareader/MangaPageHtml.kt`, adapted for WKWebView:
//   - Image URLs use the custom `hoshi-img://manga/<percent-encoded relative path>` scheme so
//     a `WKURLSchemeHandler` (see MangaReaderWebView) serves the bytes off disk, rather than
//     the Android `https://hoshi.local/manga/` base intercepted via WebViewClient.
//   - Every Android `window.HoshiX.method(...)` JS bridge call is rewritten to
//     `window.webkit.messageHandlers.X.postMessage({...})`. Handlers: `hoshiManga` (tap/reveal
//     routing → "selected nothing"), `hoshiMangaAi` (ask about bubble), `hoshiMangaClipboard`
//     (copy text) and `textSelected` (dictionary lookup; payload mirrors the EPUB SelectionData
//     `{text, sentence, rect:{x,y,width,height}}`).
//
//  Everything else faithfully follows the Android renderer: definite-px sized `.page` flexbox
//  (no vw/vh/%), `.frame` aspect-fit, `.ocr-box` absolute %-positioning + cqw font-size,
//  vertical-rl writing mode, transparent-until-tapped reveal with action buttons, the
//  wrap-fallback binary-search JS, the crop/host-rect mapping JS, and `setHostScale`.
//

import Foundation

/// Pure, `nonisolated` page-HTML builder so the adjacent-page preloader can build neighbour
/// pages off the main actor (see `MangaPageRenderCache`). Has no MainActor dependencies — it
/// turns a `MokuroPage` + a few primitives into an HTML string.
nonisolated enum MangaPageHtml {
    /// Base URL the per-page HTML is loaded against; the custom scheme handler serves
    /// `hoshi-img://manga/<relative image path>` requests off disk.
    static let baseURLString = "hoshi-img://manga/"
    private static let mangaMaxSelectionLength = 16

    /// Builds the full HTML document for `page`.
    ///
    /// - Parameters:
    ///   - page: the mokuro page to render.
    ///   - backgroundCssColor: CSS colour for the letterbox area around the image.
    ///   - selectionScript: JS to inject (the shared selection mechanism), verbatim, so the
    ///     page's `window.hoshiSelection` interface works on tap.
    ///   - scanNonJapaneseText: forwarded to `window.scanNonJapaneseText`, mirroring the EPUB
    ///     reader so the selection scanner respects the dictionary setting.
    ///   - viewportCssWidth/viewportCssHeight: the host WebView's viewport size in CSS px;
    ///     every layout size is baked into the CSS as a definite px value.
    ///   - singleTapLookup: when `true`, the first tap reveals + looks up; default `false`
    ///     keeps the two-tap-to-lookup behaviour.
    ///   - useNotoSansJpFont: when `true`, emits an explicit `font-family` on `.ocr-box`.
    static func build(
        page: MokuroPage,
        backgroundCssColor: String,
        selectionScript: String,
        scanNonJapaneseText: Bool,
        viewportCssWidth: Int,
        viewportCssHeight: Int,
        singleTapLookup: Bool = false,
        useNotoSansJpFont: Bool = false
    ) -> String {
        let imageWidth = max(page.imageWidth, 1)
        let imageHeight = max(page.imageHeight, 1)
        // The largest box with the image's aspect ratio that fits the viewport — the
        // `object-fit: contain` fit, baked into the CSS as a definite px size (no vw/vh, no
        // JS, no layout-viewport dependency).
        let viewportWidth = max(viewportCssWidth, 1)
        let viewportHeight = max(viewportCssHeight, 1)
        let fitScale = min(
            Double(viewportWidth) / Double(imageWidth),
            Double(viewportHeight) / Double(imageHeight)
        )
        let frameWidthCss = formatNumber(Double(imageWidth) * fitScale)
        let frameHeightCss = formatNumber(Double(imageHeight) * fitScale)
        let boxes = page.textBoxes
            .map { textBoxHtml($0, imageWidth: imageWidth, imageHeight: imageHeight, fitScale: fitScale) }
            .joined(separator: "\n")

        let css = pageCss(
            backgroundCssColor: backgroundCssColor,
            viewportCssWidth: viewportWidth,
            viewportCssHeight: viewportHeight,
            frameWidthCss: frameWidthCss,
            frameHeightCss: frameHeightCss,
            useNotoSansJpFont: useNotoSansJpFont
        )

        let imageSrc = escapeAttribute(encodeImagePath(page.imagePath))

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=5, user-scalable=yes">
        <style>
        \(css)
        </style>
        </head>
        <body>
        <div class="page">
          <div class="frame" data-page-index="\(page.index)" data-image-width="\(imageWidth)" data-image-height="\(imageHeight)">
            <img class="page-image" src="\(imageSrc)" alt="">
            <div class="ocr-layer">
        \(boxes)
            </div>
          </div>
        </div>
        <script>
        window.scanNonJapaneseText = \(scanNonJapaneseText);
        // NOTE: anchoring the popup to the whole OCR bubble (rect substitution + the block's
        // verticalBlock orientation) happens at the source in selection.js `getSelectionRect`
        // — see the `.ocr-box` branch there. A messageHandlers shim that used to live here
        // never fired reliably and has been removed.
        \(selectionScript)
        \(mangaTapHandlerScript)
        window.hoshiManga && window.hoshiManga.setSingleTapLookup(\(singleTapLookup));
        window.hoshiManga && window.hoshiManga.installTapListener(\(mangaMaxSelectionLength));
        </script>
        </body>
        </html>
        """
    }

    private static func pageCss(
        backgroundCssColor: String,
        viewportCssWidth: Int,
        viewportCssHeight: Int,
        frameWidthCss: String,
        frameHeightCss: String,
        useNotoSansJpFont: Bool
    ) -> String {
        let matchedWordHighlight = "::highlight(hoshi-selection) { background: #ffd400; color: #000; }"
        let ocrBoxFontFamilyRule = useNotoSansJpFont
            ? "font-family: 'Hiragino Sans', 'Hiragino Kaku Gothic ProN', sans-serif;"
            : ""
        return """
        * { margin: 0; padding: 0; box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
        html, body {
          width: 100%;
          height: 100%;
          background: \(backgroundCssColor);
          overflow: hidden;
          -webkit-text-size-adjust: 100%;
        }
        .page {
          position: absolute;
          top: 0;
          left: 0;
          width: \(viewportCssWidth)px;
          height: \(viewportCssHeight)px;
          background: \(backgroundCssColor);
          display: flex;
          align-items: center;
          justify-content: center;
        }
        .frame {
          position: relative;
          width: \(frameWidthCss)px;
          height: \(frameHeightCss)px;
          container-type: inline-size;
        }
        .page-image {
          display: block;
          width: 100%;
          height: 100%;
          object-fit: contain;
          -webkit-user-select: none;
          user-select: none;
          pointer-events: none;
        }
        .ocr-layer {
          position: absolute;
          inset: 0;
        }
        .ocr-box {
          position: absolute;
          line-height: 1.1;
          white-space: pre;
          color: transparent;
          background: transparent;
          border-radius: 3px;
          font-size: var(--hoshi-drawn-fs);
          padding: 0.08em;
          \(ocrBoxFontFamilyRule)
          -webkit-user-select: text;
          user-select: text;
        }
        .ocr-box.wrap {
          white-space: pre-wrap;
          word-break: break-all;
          overflow-wrap: anywhere;
        }
        .ocr-box.revealed {
          color: #000;
          background: #fff;
          /* The readability zoom (see textBoxHtml) applies only once revealed; unrevealed
             transparent text stays at drawn size so it can't steal neighbours' taps. */
          font-size: var(--hoshi-reveal-fs);
          /* The white halo carries legibility wherever boosted text spills past the plate;
             the extra 3px ring makes it read slightly stronger over busy art. NO box-shadow /
             plate apron here: a hard-edged white square stamped over the balloon reads as a
             rendering glitch (user-reported) — the per-glyph halo is the only emphasis. */
          text-shadow:
            1px 1px 1px #fff, -1px 1px 1px #fff, 1px -1px 1px #fff, -1px -1px 1px #fff,
            2px 0 2px #fff, -2px 0 2px #fff, 0 2px 2px #fff, 0 -2px 2px #fff,
            3px 0 3px #fff, -3px 0 3px #fff, 0 3px 3px #fff, 0 -3px 3px #fff;
        }
        .ocr-box.vertical {
          writing-mode: vertical-rl;
          text-orientation: upright;
        }
        .ocr-box p {
          margin: 0;
        }
        .ocr-actions {
          display: none;
          position: fixed;
          left: 0;
          top: 0;
          margin: 0;
          /* Keep the toolbar in viewport coordinates. This avoids WebKit resolving the action
             buttons through a vertical-rl containing block, which can stack the two controls and
             clip the copy button on narrow bubbles. */
          writing-mode: horizontal-tb;
          width: 52px;
          height: 24px;
          z-index: 50;
          overflow: visible;
        }
        .ocr-box.revealed .ocr-actions {
          display: block;
        }
        .ocr-copy-btn { position: absolute; top: 0; left: 0; }
        .ocr-ai-btn { position: absolute; top: 0; left: 28px; }
        .ocr-action-btn {
          box-sizing: border-box;
          /* Fixed, compact size (was 1.7em → ballooned into a big blob on boosted OCR fonts;
             then 30px → too big on small bubbles). */
          width: 24px;
          height: 24px;
          padding: 4px;
          display: flex;
          align-items: center;
          justify-content: center;
          border: none;
          border-radius: 5px;
          background: #1b1b1b;
          color: #fff;
          cursor: pointer;
          -webkit-user-select: none;
          user-select: none;
        }
        .ocr-action-btn svg {
          width: 100%;
          height: 100%;
          display: block;
          pointer-events: none;
        }
        /* The copy icon is stroke-only; its stroke-width is in viewBox units (24) but the svg
           renders at ~14px, scaling a 2-unit stroke down to a ~1px hairline that reads as
           invisible over the dark button. Pin the stroke to screen pixels so it stays a crisp,
           visible line at any rendered size. The selector targets only the copy svg (it carries
           the `stroke` attribute); the AI icon is fill-based with no `stroke` attr, so it is
           untouched. vector-effect/stroke-width are inherited by the child rect+path. */
        .ocr-action-btn svg[stroke] {
          vector-effect: non-scaling-stroke;
          stroke-width: 2px;
        }
        .ocr-action-btn svg[stroke] rect,
        .ocr-action-btn svg[stroke] path {
          vector-effect: non-scaling-stroke;
        }
        ::selection { background: rgba(70, 130, 220, 0.45); }
        \(matchedWordHighlight)
        """
    }

    private static func textBoxHtml(
        _ box: MokuroTextBox,
        imageWidth: Int,
        imageHeight: Int,
        fitScale: Double
    ) -> String {
        let leftPct = percent(box.left, imageWidth)
        let topPct = percent(box.top, imageHeight)
        let widthPct = percent(box.width, imageWidth)
        let heightPct = percent(box.height, imageHeight)
        // Readability zoom, computed in RENDERED points (fitScale = rendered pt per image px;
        // the viewport is initial-scale=1, so CSS px == pt). `box.fontSize` is the art's
        // measured glyph size (see MokuroRaw.clampMokuroFontSize); small-on-screen text is
        // lifted toward the readable target, big text reveals at art size:
        //
        //   revealPt = drawnPt + max(0, target - drawnPt) × boost
        //
        // The lift is additive-only, so the reveal is NEVER smaller than the drawn art, and
        // the zoom multiplier strictly decreases as drawn size grows (smaller art zooms more).
        // Defined in pt so it self-adjusts across scan resolutions and devices.
        let drawnPt = Double(max(1, box.fontSize)) * fitScale
        let revealPt = drawnPt + max(0, MangaFontTuning.targetRevealPt - drawnPt) * MangaFontTuning.revealBoost
        // fitScale > 0 always (build() clamps image and viewport dims to >= 1).
        let revealImagePx = revealPt / fitScale
        // Express relative to image width so it scales with the rendered frame
        // (cqw = 1% of the container's width). The UNREVEALED box renders at the art's drawn
        // size — its transparent text must hug the box for elementFromPoint hit-testing, or
        // boosted invisible glyphs from one bubble would steal taps meant for a neighbour.
        // The readability zoom kicks in via `.revealed` (--hoshi-reveal-fs in the CSS).
        let drawnCqw = percent(box.fontSize, imageWidth)
        let revealCqw = formatNumber(revealImagePx * 100.0 / Double(imageWidth))
        let verticalClass = box.vertical ? " vertical" : ""
        // Join with literal `\n` so the shared selection scanner sees mokuro's line boundaries
        // as sentence delimiters; `.ocr-box`'s `white-space: pre` renders it as a real break.
        let text = box.lines.map(escapeHtmlText).joined(separator: "\n")
        return """
            <div class="ocr-box\(verticalClass)" role="button" tabindex="0" \
        aria-pressed="false" style="left: \(leftPct)%; top: \(topPct)%; \
        width: \(widthPct)%; height: \(heightPct)%; --hoshi-drawn-fs: \(drawnCqw)cqw; \
        --hoshi-reveal-fs: \(revealCqw)cqw;">\
        <p>\(text)</p>\(actionButtonsHtml)</div>
        """
    }

    /// The action buttons baked into every box; CSS keeps them hidden until `.revealed`.
    ///  - sparkles glyph → `window.webkit.messageHandlers.hoshiMangaAi`
    ///  - copy glyph → `window.webkit.messageHandlers.hoshiMangaClipboard`
    private static let actionButtonsHtml: String =
        #"<div class="ocr-actions">"# +
        #"<button class="ocr-action-btn ocr-ai-btn" type="button" "# +
        #"aria-label="Ask about this bubble">"# +
        #"<svg viewBox="0 0 24 24" fill="currentColor">"# +
        #"<path d="M11 2.5l1.8 4.7L17.5 9l-4.7 1.8L11 15.5l-1.8-4.7L4.5 9l4.7-1.8L11 2.5z"></path>"# +
        #"<path d="M18 13l.95 2.05L21 16l-2.05.95L18 19l-.95-2.05L15 16l2.05-.95L18 13z"></path>"# +
        #"</svg></button>"# +
        #"<button class="ocr-action-btn ocr-copy-btn" type="button" "# +
        #"aria-label="Copy bubble text">"# +
        #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" "# +
        #"stroke-linecap="round" stroke-linejoin="round">"# +
        #"<rect x="9" y="9" width="11" height="11" rx="2"></rect>"# +
        #"<path d="M5 15V5a2 2 0 0 1 2-2h10"></path></svg></button>"# +
        #"</div>"#

    /// The single tap entry point for the manga page. It inspects the element under the tap and
    /// picks one of: AI button (ask about bubble → '__ai__'), copy button (copy text →
    /// '__copied__'), an unrevealed box (reveal → '__revealed__'), an already-revealed box (run
    /// the shared `selectText` lookup), or empty artwork (clear reveals + notify native).
    private static let mangaTapHandlerScript: String = """
    (function() {
      function handlers() { return window.webkit && window.webkit.messageHandlers; }
      window.hoshiManga = {
        hostScaleValue: 1,
        singleTapLookupValue: false,
        setHostScale: function(scale) {
          if (typeof scale === 'number' && isFinite(scale) && scale > 0) {
            this.hostScaleValue = scale;
          }
        },
        setSingleTapLookup: function(enabled) {
          this.singleTapLookupValue = !!enabled;
        },
        hostScale: function() {
          var scale = this.hostScaleValue;
          return isFinite(scale) && scale > 0 ? scale : 1;
        },
        hostRectFromViewportRect: function(rect) {
          var scale = this.hostScale();
          var viewport = window.visualViewport;
          var offsetLeft = viewport && typeof viewport.offsetLeft === 'number'
            ? viewport.offsetLeft
            : 0;
          var offsetTop = viewport && typeof viewport.offsetTop === 'number'
            ? viewport.offsetTop
            : 0;
          return {
            x: (rect.x - offsetLeft) * scale,
            y: (rect.y - offsetTop) * scale,
            width: rect.width * scale,
            height: rect.height * scale
          };
        },
        imageCropFromHostRect: function(left, top, right, bottom, hostWidth, hostHeight) {
          var frame = document.querySelector('.frame');
          if (!frame) return null;
          var viewport = window.visualViewport;
          var scale = this.hostScale();
          var viewportWidth = viewport && typeof viewport.width === 'number'
            ? viewport.width
            : window.innerWidth / scale;
          var viewportHeight = viewport && typeof viewport.height === 'number'
            ? viewport.height
            : window.innerHeight / scale;
          var offsetLeft = viewport && typeof viewport.offsetLeft === 'number'
            ? viewport.offsetLeft
            : 0;
          var offsetTop = viewport && typeof viewport.offsetTop === 'number'
            ? viewport.offsetTop
            : 0;
          var frameRect = frame.getBoundingClientRect();
          var pageIndex = parseInt(frame.dataset.pageIndex || '-1', 10);
          var imageWidth = parseInt(frame.dataset.imageWidth || '0', 10);
          var imageHeight = parseInt(frame.dataset.imageHeight || '0', 10);
          if (!isFinite(scale) || scale <= 0 ||
              !isFinite(hostWidth) || hostWidth <= 0 ||
              !isFinite(hostHeight) || hostHeight <= 0 ||
              !isFinite(viewportWidth) || viewportWidth <= 0 ||
              !isFinite(viewportHeight) || viewportHeight <= 0 ||
              !isFinite(pageIndex) || pageIndex < 0 ||
              !isFinite(imageWidth) || imageWidth <= 0 ||
              !isFinite(imageHeight) || imageHeight <= 0 ||
              frameRect.width <= 0 || frameRect.height <= 0) {
            return null;
          }
          function hostX(x) { return x / hostWidth * viewportWidth + offsetLeft; }
          function hostY(y) { return y / hostHeight * viewportHeight + offsetTop; }
          var cropLeft = Math.min(hostX(left), hostX(right));
          var cropRight = Math.max(hostX(left), hostX(right));
          var cropTop = Math.min(hostY(top), hostY(bottom));
          var cropBottom = Math.max(hostY(top), hostY(bottom));
          cropLeft = Math.max(cropLeft, frameRect.left);
          cropRight = Math.min(cropRight, frameRect.right);
          cropTop = Math.max(cropTop, frameRect.top);
          cropBottom = Math.min(cropBottom, frameRect.bottom);
          if (cropRight <= cropLeft || cropBottom <= cropTop) return null;
          return {
            pageIndex: pageIndex,
            left: Math.max(0, Math.floor((cropLeft - frameRect.left) / frameRect.width * imageWidth)),
            top: Math.max(0, Math.floor((cropTop - frameRect.top) / frameRect.height * imageHeight)),
            right: Math.min(imageWidth, Math.ceil((cropRight - frameRect.left) / frameRect.width * imageWidth)),
            bottom: Math.min(imageHeight, Math.ceil((cropBottom - frameRect.top) / frameRect.height * imageHeight))
          };
        },
        clearRevealed: function() {
          var revealed = document.querySelectorAll('.ocr-box.revealed');
          for (var i = 0; i < revealed.length; i++) {
            revealed[i].classList.remove('revealed');
            revealed[i].setAttribute('aria-pressed', 'false');
            // Drop any inline font the wrap fallback pinned at reveal size, so the
            // unrevealed box returns to drawn size (keeps hit-testing honest).
            revealed[i].style.fontSize = '';
            revealed[i].classList.remove('wrap');
            delete revealed[i].dataset.wrapTried;
          }
          if (window.hoshiSelection) {
            window.hoshiSelection.clearSelection();
          }
        },
        tryWrapFallback: function(box) {
          if (box.dataset.wrapTried === '1') return;
          box.dataset.wrapTried = '1';
          if (box.classList.contains('vertical')) return;
          var initialPx = parseFloat(window.getComputedStyle(box).fontSize);
          if (!isFinite(initialPx) || initialPx <= 0) return;
          var clientW = box.clientWidth;
          var clientH = box.clientHeight;
          if (clientW <= 0 || clientH <= 0) return;
          var MIN_FS = 1;
          var MAX_FS = 400;
          var originalInlineFontSize = box.style.fontSize;
          function overflowing() {
            return box.scrollWidth > box.clientWidth ||
              box.scrollHeight > box.clientHeight;
          }
          function setFs(px) { box.style.fontSize = px + 'px'; }
          function findMaxFitting(start) {
            if (start < MIN_FS) start = MIN_FS;
            if (start > MAX_FS) start = MAX_FS;
            setFs(start);
            var low, high;
            if (!overflowing()) {
              low = start;
              high = Math.min(start * 2, MAX_FS);
              setFs(high);
              while (!overflowing() && high < MAX_FS) {
                low = high;
                high = Math.min(high * 2, MAX_FS);
                setFs(high);
              }
              if (!overflowing()) {
                return Math.floor(high);
              }
            } else {
              setFs(MIN_FS);
              if (overflowing()) return MIN_FS;
              low = MIN_FS;
              high = start;
            }
            while (high - low > 1) {
              var mid = Math.floor((low + high) / 2);
              setFs(mid);
              if (overflowing()) {
                high = mid;
              } else {
                low = mid;
              }
            }
            return Math.floor(low);
          }
          box.classList.add('wrap');
          var wrapFs = findMaxFitting(initialPx);
          var WRAP_WIN_RATIO = 1.3;
          if (wrapFs >= initialPx * WRAP_WIN_RATIO) {
            setFs(wrapFs);
          } else {
            box.classList.remove('wrap');
            box.style.fontSize = originalInlineFontSize;
          }
        },
        placeActions: function(box) {
          var actions = box.querySelector('.ocr-actions');
          if (!actions) return;
          var boxRect = box.getBoundingClientRect();
          var viewport = window.visualViewport;
          var viewportLeft = viewport && typeof viewport.offsetLeft === 'number'
            ? viewport.offsetLeft
            : 0;
          var viewportTop = viewport && typeof viewport.offsetTop === 'number'
            ? viewport.offsetTop
            : 0;
          var viewportWidth = viewport && typeof viewport.width === 'number'
            ? viewport.width
            : window.innerWidth;
          var viewportHeight = viewport && typeof viewport.height === 'number'
            ? viewport.height
            : window.innerHeight;
          var gap = 4;
          var actionsWidth = actions.offsetWidth || 52;
          var actionsHeight = actions.offsetHeight || 24;
          var left = boxRect.right - actionsWidth;
          var top = boxRect.top - actionsHeight - gap;

          if (top < viewportTop + gap) {
            top = boxRect.bottom + gap;
          }
          if (top + actionsHeight > viewportTop + viewportHeight - gap) {
            top = Math.max(viewportTop + gap, boxRect.top - actionsHeight - gap);
          }

          left = Math.max(
            viewportLeft + gap,
            Math.min(left, viewportLeft + viewportWidth - actionsWidth - gap)
          );

          actions.style.left = Math.round(left) + 'px';
          actions.style.top = Math.round(top) + 'px';
        },
        installTapListener: function(maxLength) {
          if (this.tapListenerInstalled) return;
          this.tapListenerInstalled = true;
          document.addEventListener('click', function(event) {
            if (!window.hoshiManga) return;
            event.preventDefault();
            var result = window.hoshiManga.handleTap(event.clientX, event.clientY, maxLength);
            if (result === null || typeof result === 'undefined') {
              var h = handlers();
              if (h && h.hoshiManga) {
                h.hoshiManga.postMessage({ event: 'selectedNothing' });
              }
            }
          }, true);
        },
        handleTap: function(x, y, maxLength) {
          var el = document.elementFromPoint(x, y);
          var aiBtn = el && el.closest && el.closest('.ocr-ai-btn');
          if (aiBtn) {
            var aiBox = aiBtn.closest('.ocr-box');
            var aiText = aiBox && aiBox.querySelector('p');
            var h = handlers();
            if (aiText && h && h.hoshiMangaAi) {
              h.hoshiMangaAi.postMessage({ text: aiText.textContent || '' });
            }
            return '__ai__';
          }
          var copyBtn = el && el.closest && el.closest('.ocr-copy-btn');
          if (copyBtn) {
            var copyBox = copyBtn.closest('.ocr-box');
            var copyText = copyBox && copyBox.querySelector('p');
            var hc = handlers();
            if (copyText && hc && hc.hoshiMangaClipboard) {
              hc.hoshiMangaClipboard.postMessage({ text: copyText.textContent || '' });
            }
            return '__copied__';
          }
          var box = el && el.closest && el.closest('.ocr-box');
          if (box) {
            var alreadyRevealed = box.classList.contains('revealed');
            if (!alreadyRevealed) {
              // Reveal BEFORE the wrap fallback: the fallback fits from the computed
              // font-size, which only becomes the boosted reveal size once .revealed applies.
              box.classList.add('revealed');
              window.hoshiManga.tryWrapFallback(box);
              box.setAttribute('aria-pressed', 'true');
              window.hoshiManga.placeActions(box);
            }
            if (alreadyRevealed || window.hoshiManga.singleTapLookupValue) {
              return window.hoshiSelection.selectText(x, y, maxLength);
            }
            return '__revealed__';
          }
          window.hoshiManga.clearRevealed();
          return null;
        }
      };
    })();
    """

    private static func percent(_ value: Int, _ total: Int) -> String {
        formatNumber(percentValue(value, total))
    }

    /// Readability zoom tuning for the OCR reveal, in RENDERED points (see `textBoxHtml`).
    /// The only two knobs: raise/lower `targetRevealPt` (sane band 24–28) for the floor small
    /// text is lifted toward; `revealBoost` (0.55–0.7) for how firmly the gap is closed.
    nonisolated enum MangaFontTuning {
        static let targetRevealPt = 26.0
        static let revealBoost = 0.65
    }

    private static func percentValue(_ value: Int, _ total: Int) -> Double {
        total <= 0 ? 0 : Double(value) * 100.0 / Double(total)
    }

    private static func formatNumber(_ value: Double) -> String {
        let rounded = (value * 1000.0).rounded() / 1000.0
        if rounded == rounded.rounded() && abs(rounded) < 1e15 {
            return String(Int64(rounded))
        }
        return String(rounded)
    }

    private static func escapeHtmlText(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeAttribute(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Percent-encodes a book-root-relative image path (per `/`-separated segment) so it
    /// survives URL resolution against the base URL: a `#`, `?`, `%` or space in an image
    /// filename would otherwise be parsed as URL syntax. The scheme handler decodes the
    /// request URL's path back to the original on-disk relative path.
    static func encodeImagePath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map { segment -> String in
                var encoded = ""
                for byte in segment.utf8 {
                    let code = Int(byte)
                    let ch = Character(UnicodeScalar(byte))
                    if pathSegmentSafe.contains(ch) {
                        encoded.append(ch)
                    } else {
                        encoded.append("%")
                        encoded.append(hexDigits[code >> 4])
                        encoded.append(hexDigits[code & 0x0F])
                    }
                }
                return encoded
            }
            .joined(separator: "/")
    }

    private static let hexDigits = Array("0123456789ABCDEF")

    /// RFC 3986 unreserved characters — safe to leave un-encoded in a URL path segment.
    private static let pathSegmentSafe: Set<Character> = {
        var set = Set<Character>()
        set.formUnion("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        set.formUnion("abcdefghijklmnopqrstuvwxyz")
        set.formUnion("0123456789")
        set.formUnion(["-", "_", ".", "~"])
        return set
    }()
}
