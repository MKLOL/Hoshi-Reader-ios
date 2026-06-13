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
//  wrap-fallback binary-search JS, the crop/host-rect mapping JS, and host zoom/pan geometry.
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
        leftPage: MokuroPage? = nil,
        backgroundCssColor: String,
        selectionScript: String,
        scanNonJapaneseText: Bool,
        viewportCssWidth: Int,
        viewportCssHeight: Int,
        singleTapLookup: Bool = false,
        useNotoSansJpFont: Bool = false
    ) -> String {
        // Each page is fitted with `object-fit: contain` into its share of the viewport, baked into
        // the CSS as definite px sizes (no vw/vh, no JS). In a two-page spread (`leftPage != nil`)
        // the earlier page (`page`) sits on the RIGHT and the later page (`leftPage`) on the LEFT —
        // right-to-left manga reading — each fitted into half the viewport width. DOM order is
        // left→right, so the left (later) frame is emitted first. Per-frame data attributes +
        // geometry make taps/selection/crop work per page with no other changes.
        let viewportWidth = max(viewportCssWidth, 1)
        let viewportHeight = max(viewportCssHeight, 1)
        let shortSide = Double(min(viewportWidth, viewportHeight))
        let longSide = Double(max(viewportWidth, viewportHeight))
        let gap = 2
        let perPageWidth = leftPage == nil ? viewportWidth : max(1, (viewportWidth - gap) / 2)

        var frames = ""
        if let leftPage {
            frames += frameHtml(page: leftPage, availableWidth: perPageWidth,
                                viewportHeight: viewportHeight, shortSide: shortSide, longSide: longSide)
            frames += "\n"
        }
        frames += frameHtml(page: page, availableWidth: perPageWidth,
                            viewportHeight: viewportHeight, shortSide: shortSide, longSide: longSide)

        let css = pageCss(
            backgroundCssColor: backgroundCssColor,
            viewportCssWidth: viewportWidth,
            viewportCssHeight: viewportHeight,
            useNotoSansJpFont: useNotoSansJpFont
        )

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
        \(frames)
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

    /// One page's `<div class="frame">` (image + OCR overlay), fitted into `availableWidth` ×
    /// `viewportHeight` with `object-fit: contain`. The frame size is inline so a single page (full
    /// width) and a spread page (half width) share one CSS rule. `shortSide`/`longSide` are the FULL
    /// viewport's dimensions: the readability zoom stays anchored to the portrait-orientation fit, so
    /// text zooms the same relative to the art whether the page is shown full-width or half-width.
    private static func frameHtml(
        page: MokuroPage,
        availableWidth: Int,
        viewportHeight: Int,
        shortSide: Double,
        longSide: Double
    ) -> String {
        let imageWidth = max(page.imageWidth, 1)
        let imageHeight = max(page.imageHeight, 1)
        let fitScale = min(
            Double(availableWidth) / Double(imageWidth),
            Double(viewportHeight) / Double(imageHeight)
        )
        let frameWidthCss = formatNumber(Double(imageWidth) * fitScale)
        let frameHeightCss = formatNumber(Double(imageHeight) * fitScale)
        let readabilityFitScale = min(
            shortSide / Double(imageWidth),
            longSide / Double(imageHeight)
        )
        let boxes = page.textBoxes
            .map { textBoxHtml($0, imageWidth: imageWidth, imageHeight: imageHeight, readabilityFitScale: readabilityFitScale) }
            .joined(separator: "\n")
        let imageSrc = escapeAttribute(encodeImagePath(page.imagePath))
        return """
          <div class="frame" style="width: \(frameWidthCss)px; height: \(frameHeightCss)px;" data-page-index="\(page.index)" data-image-width="\(imageWidth)" data-image-height="\(imageHeight)">
            <img class="page-image" src="\(imageSrc)" alt="">
            <div class="ocr-layer">
        \(boxes)
            </div>
          </div>
        """
    }

    private static func pageCss(
        backgroundCssColor: String,
        viewportCssWidth: Int,
        viewportCssHeight: Int,
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
          /* Hairline gap between the two pages of a spread; no effect on a single page. */
          gap: 2px;
        }
        .frame {
          position: relative;
          /* width/height are set inline per frame: full width for a single page, half each for a
             two-page spread. */
          flex: 0 0 auto;
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
          /* Absolutely positioned within its own bubble (an `position: absolute` box), so the
             toolbar lives inside the zoomable page content and stays attached to the bubble when
             the host zooms/pans. `position: fixed` pinned it to the visual viewport, so WebKit
             detached it from the bubble under pinch-zoom. `writing-mode: horizontal-tb` keeps the
             two controls side by side even inside a vertical-rl bubble; JS sets physical left/top
             relative to the box's padding box, which is orientation-independent. */
          position: absolute;
          left: 0;
          top: 0;
          margin: 0;
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
        readabilityFitScale: Double
    ) -> String {
        let leftPct = percent(box.left, imageWidth)
        let topPct = percent(box.top, imageHeight)
        let widthPct = percent(box.width, imageWidth)
        let heightPct = percent(box.height, imageHeight)
        // Readability zoom, computed in RENDERED points (readabilityFitScale = rendered pt per
        // image px at the PORTRAIT-orientation fit, so the zoom is image-relative and identical in
        // portrait and landscape; the viewport is initial-scale=1, so CSS px == pt). `box.fontSize`
        // is the art's measured glyph size (see MokuroRaw.clampMokuroFontSize); small-on-screen text
        // is lifted toward the readable target, big text reveals at art size:
        //
        //   revealPt = drawnPt + max(0, target - drawnPt) × boost
        //
        // The lift is additive-only, so the reveal is NEVER smaller than the drawn art, and
        // the zoom multiplier strictly decreases as drawn size grows (smaller art zooms more).
        // Defined in pt so it self-adjusts across scan resolutions and devices.
        let drawnPt = Double(max(1, box.fontSize)) * readabilityFitScale
        let revealPt = drawnPt + max(0, MangaFontTuning.targetRevealPt - drawnPt) * MangaFontTuning.revealBoost
        // readabilityFitScale > 0 always (build() clamps image and viewport dims to >= 1). Dividing
        // back out yields an image-space reveal size; the cqw unit below then renders it against the
        // real frame width, so on screen it tracks the displayed image in either orientation.
        let revealImagePx = revealPt / readabilityFitScale
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
        hostOffsetLeftValue: 0,
        hostOffsetTopValue: 0,
        singleTapLookupValue: false,
        setHostScale: function(scale) {
          this.setHostViewport(scale, this.hostOffsetLeftValue, this.hostOffsetTopValue);
        },
        setHostViewport: function(scale, offsetLeft, offsetTop) {
          this.hostScaleValue = (typeof scale === 'number' && isFinite(scale) && scale > 0)
            ? scale
            : 1;
          this.hostOffsetLeftValue = (typeof offsetLeft === 'number' && isFinite(offsetLeft))
            ? offsetLeft
            : 0;
          this.hostOffsetTopValue = (typeof offsetTop === 'number' && isFinite(offsetTop))
            ? offsetTop
            : 0;
        },
        setSingleTapLookup: function(enabled) {
          this.singleTapLookupValue = !!enabled;
        },
        hostScale: function() {
          var scale = this.hostScaleValue;
          return isFinite(scale) && scale > 0 ? scale : 1;
        },
        hostOffsetLeft: function() {
          var offset = this.hostOffsetLeftValue;
          return isFinite(offset) ? offset : 0;
        },
        hostOffsetTop: function() {
          var offset = this.hostOffsetTopValue;
          return isFinite(offset) ? offset : 0;
        },
        isHostZoomedOrPanned: function() {
          return this.hostScale() > 1.01 ||
            Math.abs(this.hostOffsetLeft()) > 1 ||
            Math.abs(this.hostOffsetTop()) > 1;
        },
        hostRectFromViewportRect: function(rect) {
          var scale = this.hostScale();
          var x = typeof rect.x === 'number' ? rect.x : rect.left;
          var y = typeof rect.y === 'number' ? rect.y : rect.top;
          // WKWebView's DOM viewport rects already include the native UIScrollView pan, but
          // their dimensions are still in unzoomed CSS pixels. Map to host pixels by scale only.
          return {
            x: x * scale,
            y: y * scale,
            width: rect.width * scale,
            height: rect.height * scale
          };
        },
        imageCropFromHostRect: function(left, top, right, bottom, hostWidth, hostHeight) {
          var scale = this.hostScale();
          if (!isFinite(scale) || scale <= 0 ||
              !isFinite(hostWidth) || hostWidth <= 0 ||
              !isFinite(hostHeight) || hostHeight <= 0) {
            return null;
          }
          function hostX(x) { return x / scale; }
          function hostY(y) { return y / scale; }
          var cropLeft = Math.min(hostX(left), hostX(right));
          var cropRight = Math.max(hostX(left), hostX(right));
          var cropTop = Math.min(hostY(top), hostY(bottom));
          var cropBottom = Math.max(hostY(top), hostY(bottom));
          // Pick the page frame containing the crop's centre so a two-page spread crops the page the
          // user dragged over (single page: there is only one frame, so this is unchanged).
          var centreX = (cropLeft + cropRight) / 2;
          var centreY = (cropTop + cropBottom) / 2;
          var frames = document.querySelectorAll('.frame');
          var frame = null;
          for (var i = 0; i < frames.length; i++) {
            var r = frames[i].getBoundingClientRect();
            if (centreX >= r.left && centreX <= r.right && centreY >= r.top && centreY <= r.bottom) {
              frame = frames[i];
              break;
            }
          }
          if (!frame) {
            // Centre landed in the inter-page gap or letterbox margin: pick the horizontally
            // nearest frame so the crop maps to the page the drag mostly covered, not always the
            // left one. (Single page: the one frame is the nearest.)
            var best = Infinity;
            for (var k = 0; k < frames.length; k++) {
              var fr = frames[k].getBoundingClientRect();
              var dx = centreX < fr.left ? fr.left - centreX : (centreX > fr.right ? centreX - fr.right : 0);
              if (dx < best) { best = dx; frame = frames[k]; }
            }
          }
          if (!frame) return null;
          var frameRect = frame.getBoundingClientRect();
          var pageIndex = parseInt(frame.dataset.pageIndex || '-1', 10);
          var imageWidth = parseInt(frame.dataset.imageWidth || '0', 10);
          var imageHeight = parseInt(frame.dataset.imageHeight || '0', 10);
          if (!isFinite(pageIndex) || pageIndex < 0 ||
              !isFinite(imageWidth) || imageWidth <= 0 ||
              !isFinite(imageHeight) || imageHeight <= 0 ||
              frameRect.width <= 0 || frameRect.height <= 0) {
            return null;
          }
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
          // Position the toolbar relative to its OWN bubble (the `.ocr-actions` is an absolutely
          // positioned child of the box), so it sits inside the zoomable page content and stays
          // attached to the bubble when the host zooms/pans — instead of being pinned to the visual
          // viewport. Physical left/top resolve against the box's padding box for both horizontal
          // and vertical (writing-mode: vertical-rl) bubbles, so no viewport / host-scale math.
          var gap = 4;
          var actionsWidth = actions.offsetWidth || 52;
          var actionsHeight = actions.offsetHeight || 24;
          var boxWidth = box.clientWidth;
          var boxHeight = box.clientHeight;
          // Default: just above the bubble, right-aligned to it.
          var left = Math.max(0, boxWidth - actionsWidth);
          var top = -actionsHeight - gap;
          // If the bubble sits too close to the top of the frame to fit the toolbar above it,
          // drop the toolbar below the bubble instead. `offsetTop` is the box's top within the
          // ocr-layer (its positioned offset parent).
          if (box.offsetTop + top < 0) {
            top = boxHeight + gap;
          }
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
