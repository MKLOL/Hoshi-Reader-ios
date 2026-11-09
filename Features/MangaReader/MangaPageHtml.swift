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
    private static let furiganaScript = Bundle.main.url(forResource: "furigana", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""

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
    ///   - showActionButtons: when `true`, revealed bubbles show Copy / AI quick actions.
    static func build(
        page: MokuroPage,
        leftPage: MokuroPage? = nil,
        backgroundCssColor: String,
        selectionScript: String,
        scanNonJapaneseText: Bool,
        viewportCssWidth: Int,
        viewportCssHeight: Int,
        singleTapLookup: Bool = false,
        useNotoSansJpFont: Bool = false,
        showActionButtons: Bool = true,
        showCopyButton: Bool = false,
        enlargeSmallText: Bool = true,
        showFurigana: Bool = true,
        imageSources: [String: String] = [:]
    ) -> String {
        // Each page is fitted with `object-fit: contain` into its share of the viewport, baked into
        // the CSS as definite px sizes (no vw/vh, no JS). In a two-page spread (`leftPage != nil`)
        // the earlier page (`page`) sits on the RIGHT and the later page (`leftPage`) on the LEFT —
        // right-to-left manga reading — each fitted into half the viewport width. DOM order is
        // left→right, so the left (later) frame is emitted first. Per-frame data attributes +
        // geometry make taps/selection/crop work per page with no other changes.
        let viewportWidth = max(viewportCssWidth, 1)
        let viewportHeight = max(viewportCssHeight, 1)
        let gap = 2
        let perPageWidth = leftPage == nil ? viewportWidth : max(1, (viewportWidth - gap) / 2)

        var frames = ""
        if let leftPage {
            frames += frameHtml(page: leftPage, availableWidth: perPageWidth,
                                viewportHeight: viewportHeight,
                                showActionButtons: showActionButtons, enlargeSmallText: enlargeSmallText, showFurigana: showFurigana, imageURL: imageSources[leftPage.imagePath])
            frames += "\n"
        }
        frames += frameHtml(page: page, availableWidth: perPageWidth,
                            viewportHeight: viewportHeight,
                            showActionButtons: showActionButtons, enlargeSmallText: enlargeSmallText, showFurigana: showFurigana, imageURL: imageSources[page.imagePath])

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
        <meta name="viewport" content="width=device-width, initial-scale=1, minimum-scale=1, maximum-scale=5, user-scalable=yes">
        <style>
        \(css)
        .translate-only .ocr-copy-btn { display: none; }
        /* 1.14 times each paired dimension is approximately 30% more area. */
        .translate-only .ocr-ai-btn {
          width: 29.64px; height: 29.64px;
          min-width: 29.64px; min-height: 29.64px;
          padding: 5.7px; border-radius: 5.7px;
        }
        </style>
        </head>
        <body class="\(showCopyButton ? "" : "translate-only")" data-enlarge-text="\(enlargeSmallText)">
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
        \(furiganaScript)
        \(mangaTapHandlerScript)
        window.hoshiManga && window.hoshiManga.applyFurigana();
        window.hoshiManga && window.hoshiManga.setSingleTapLookup(\(singleTapLookup));
        window.hoshiManga && window.hoshiManga.installTapListener(\(mangaMaxSelectionLength));
        </script>
        </body>
        </html>
        """
    }

    /// One page's `<div class="frame">` (image + OCR overlay), fitted into `availableWidth` ×
    /// `viewportHeight` with `object-fit: contain`. The frame size is inline so a single page (full
    /// width) and a spread page (half width) share one CSS rule. OCR font sizes remain relative to
    /// the image, matching Android in portrait, landscape, and two-page spreads.
    private static func frameHtml(
        page: MokuroPage,
        availableWidth: Int,
        viewportHeight: Int,
        showActionButtons: Bool,
        enlargeSmallText: Bool,
        showFurigana: Bool,
        imageURL: String?
    ) -> String {
        let imageWidth = max(page.imageWidth, 1)
        let imageHeight = max(page.imageHeight, 1)
        let fitScale = min(
            Double(availableWidth) / Double(imageWidth),
            Double(viewportHeight) / Double(imageHeight)
        )
        let frameWidthCss = formatNumber(Double(imageWidth) * fitScale)
        let frameHeightCss = formatNumber(Double(imageHeight) * fitScale)
        let boxes = page.textBoxes
            .map { textBoxHtml($0, imageWidth: imageWidth, imageHeight: imageHeight,
                               pageIndex: page.index, enlargeSmallText: enlargeSmallText, showFurigana: showFurigana) }
            .joined(separator: "\n")
        let uiTestBoxes = uiTestActionBoxesHtml(
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            enlargeSmallText: enlargeSmallText
        )
        let actionButtons = showActionButtons ? actionButtonsHtml : ""
        let imageSrc = escapeAttribute(imageURL ?? encodeImagePath(page.imagePath))
        return """
          <div class="frame" style="width: \(frameWidthCss)px; height: \(frameHeightCss)px;" data-page-index="\(page.index)" data-image-width="\(imageWidth)" data-image-height="\(imageHeight)">
            <img class="page-image" src="\(imageSrc)" alt="">
            <div class="ocr-layer">
        \(boxes)
        \(uiTestBoxes)
            </div>
            \(actionButtons)
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
          overflow: hidden;
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
          padding: 0.08em;
          \(ocrBoxFontFamilyRule)
          -webkit-user-select: text;
          user-select: text;
        }
        .ocr-box::before {
          content: "";
          position: absolute;
          inset: -20px;
        }
        .ocr-box.wrap {
          white-space: pre-wrap;
          word-break: normal;
          overflow-wrap: break-word;
        }
        .ocr-box.wrap::before {
          /* Wrap fitting must measure text overflow, not the expanded pseudo-element.
             Programmatic hit slop still keeps thin and wrapped bubbles easy to tap. */
          display: none;
        }
        .ocr-box.revealed {
          z-index: 30;
          color: #000;
          background: #fff;
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
        .ocr-box.has-furigana { line-height: 1.7; padding: 0.5em 0.15em 0.15em; }
        .ocr-box.has-furigana.vertical { padding: 0.15em 0.5em 0.15em 0.15em; }
        .ocr-box.has-furigana:not(.revealed) { overflow: hidden; }
        .ocr-box.has-furigana ruby { ruby-position: over; }
        .ocr-box.has-furigana rt {
          font-size: 0.5em; line-height: 1; -webkit-user-select: none; user-select: none;
        }
        .ocr-box.revealed.has-furigana p, .ocr-box.revealed.has-furigana rt { background: #fff; }
        .ocr-box.furigana-scroll p { width: 100%; height: 100%; overflow: auto; overscroll-behavior: contain; }
        .ocr-actions {
          display: none;
          /* One frame-level toolbar host, not a child of the OCR box. Ultra-thin OCR boxes can be
             1-2 CSS px wide, so children positioned outside them can still get clipped or expose a
             tiny hit target through WebKit accessibility. JS anchors this host near the active box. */
          position: absolute;
          left: 0;
          top: 0;
          margin: 0;
          writing-mode: horizontal-tb;
          gap: 4px;
          align-items: center;
          z-index: 50;
          overflow: visible;
          pointer-events: auto;
          touch-action: manipulation;
        }
        .ocr-actions.is-visible {
          display: flex;
        }
        .ocr-action-btn {
          box-sizing: border-box;
          width: 26px;
          height: 26px;
          min-width: 26px;
          min-height: 26px;
          padding: 5px;
          display: flex;
          align-items: center;
          justify-content: center;
          border: none;
          border-radius: 5px;
          background: #1b1b1b;
          color: #fff;
          cursor: pointer;
          pointer-events: auto;
          touch-action: manipulation;
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
        extraAttributes: String = "",
        pageIndex: Int? = nil,
        enlargeSmallText: Bool = true,
        showFurigana: Bool = false
    ) -> String {
        let leftPct = percent(box.left, imageWidth)
        let topPct = percent(box.top, imageHeight)
        let widthPct = percent(box.width, imageWidth)
        let heightPct = percent(box.height, imageHeight)
        // Match Android: the selected image-space font scales with the artwork (cqw = 1%
        // of the frame width). The reveal CSS changes visibility without an extra device-size
        // boost; the shared wrap fallback can still repair a misidentified horizontal bubble.
        let fontCqw = percent(box.revealFontSize(enlargeSmallText: enlargeSmallText), imageWidth)
        let verticalClass = box.vertical ? " vertical" : ""
        // Join with literal `\n` so the shared selection scanner sees mokuro's line boundaries
        // as sentence delimiters; `.ocr-box`'s `white-space: pre` renders it as a real break.
        let canonicalText = box.lines.joined(separator: "\n")
        let text = escapeHtmlText(canonicalText)
        // The render cache runs off the main actor. Readings address the unmodified OCR UTF-16
        // text; the established shared segmenter aligns kana when constructing native ruby.
        let annotations = showFurigana ? (try? JapaneseFurigana.annotations(for: canonicalText)) ?? [] : []
        let readings = annotations.map { ["start": $0.start, "length": $0.length, "reading": $0.reading] as [String: Any] }
        let readingsJSON = (try? JSONSerialization.data(withJSONObject: readings))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        // The bubble's mokuro address, used to look up its pre-computed offline translation. Same
        // form on every platform and in the desktop tool: `p{pageIndex}b{blockIndex}`.
        let blockAttribute = pageIndex.map { " data-hoshi-block=\"p\($0)b\(box.blockIndex)\"" } ?? ""
        return """
            <div class="ocr-box\(verticalClass)"\(blockAttribute) \(extraAttributes) role="button" tabindex="0" \
        data-ocr-text="\(escapeAttribute(canonicalText))" data-readings="\(escapeAttribute(readingsJSON))" \
        aria-label="\(escapeAttribute(canonicalText))" aria-pressed="false" style="left: \(leftPct)%; top: \(topPct)%; \
        width: \(widthPct)%; height: \(heightPct)%; font-size: \(fontCqw)cqw;">\
        <p>\(text)</p></div>
        """
    }

    private static func uiTestActionBoxesHtml(
        imageWidth: Int,
        imageHeight: Int,
        enlargeSmallText: Bool
    ) -> String {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["HOSHI_UI_TESTING"] == "1" else { return "" }
        let w = max(imageWidth, 10)
        let h = max(imageHeight, 10)
        let boxes: [(String, MokuroTextBox)] = [
            ("thin-right", MokuroTextBox(
                left: max(0, w - 2), top: max(0, h / 2), width: 1, height: max(40, h / 28),
                fontSize: 18, vertical: false, lines: ["UI_THIN_RIGHT doesn't split words"]
            )),
            ("thin-left", MokuroTextBox(
                left: 0, top: max(0, h / 2 + h / 12), width: 1, height: max(40, h / 28),
                fontSize: 18, vertical: false, lines: ["UI_THIN_LEFT copy target"]
            )),
            ("thin-top-right", MokuroTextBox(
                left: max(0, w - 2), top: max(0, h / 8), width: 1, height: max(40, h / 32),
                fontSize: 18, vertical: false, lines: ["UI_THIN_TOP_RIGHT"]
            )),
            ("wide-top-overflow", MokuroTextBox(
                left: 40, top: max(0, h / 9), width: max(80, w - 80), height: max(12, h / 140),
                fontSize: 8, vertical: false, lines: ["上段広い", "下段広い選択"]
            )),
            ("thin-bottom-right", MokuroTextBox(
                left: max(0, w - 2), top: max(0, h - max(50, h / 28)), width: 1, height: max(40, h / 28),
                fontSize: 18, vertical: false, lines: ["UI_THIN_BOTTOM_RIGHT"]
            )),
            ("vertical-right", MokuroTextBox(
                left: max(0, w - 4), top: max(0, h / 3), width: 2, height: max(80, h / 16),
                fontSize: 18, vertical: true, lines: ["細"]
            )),
            ("lower-select", MokuroTextBox(
                left: max(0, w / 3), top: max(0, h / 2 + h / 5), width: max(120, w / 8), height: max(12, h / 120),
                fontSize: 8, vertical: false, lines: ["上段", "下段選択"]
            ))
        ]
        return boxes.map { id, box in
            textBoxHtml(
                box,
                imageWidth: imageWidth,
                imageHeight: imageHeight,
                extraAttributes: "data-hoshi-ui-test=\"\(id)\"",
                enlargeSmallText: enlargeSmallText
            )
        }.joined(separator: "\n")
        #else
        return ""
        #endif
    }

    /// The frame-level action buttons; CSS keeps the host hidden until JS anchors it to a revealed box.
    ///  - sparkles glyph → `window.webkit.messageHandlers.hoshiMangaAi`
    ///  - copy glyph → `window.webkit.messageHandlers.hoshiMangaClipboard`
    private static let actionButtonsHtml: String =
        #"<div class="ocr-actions" aria-hidden="true">"# +
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
        hostTappableTopInsetValue: 0,
        singleTapLookupValue: false,
        setHostScale: function(scale) {
          this.setHostViewport(scale, this.hostOffsetLeftValue, this.hostOffsetTopValue, this.hostTappableTopInsetValue);
        },
        setHostViewport: function(scale, offsetLeft, offsetTop, tappableTopInset) {
          this.hostScaleValue = (typeof scale === 'number' && isFinite(scale) && scale > 0)
            ? scale
            : 1;
          this.hostOffsetLeftValue = (typeof offsetLeft === 'number' && isFinite(offsetLeft))
            ? offsetLeft
            : 0;
          this.hostOffsetTopValue = (typeof offsetTop === 'number' && isFinite(offsetTop))
            ? offsetTop
            : 0;
          this.hostTappableTopInsetValue = (typeof tappableTopInset === 'number' && isFinite(tappableTopInset))
            ? Math.max(0, tappableTopInset)
            : 0;
          this.notifyScrollableBubbleRegions();
        },
        setSingleTapLookup: function(enabled) {
          this.singleTapLookupValue = !!enabled;
        },
        hideActions: function(actions) {
          if (!actions) return;
          actions.classList.remove('is-visible');
          actions.setAttribute('aria-hidden', 'true');
          actions.dataset.placement = 'hidden';
          delete actions.dataset.bubbleText;
          delete actions.dataset.blockId;
          actions.style.left = '-9999px';
          actions.style.top = '-9999px';
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
        hostTappableTopInset: function() {
          var inset = this.hostTappableTopInsetValue;
          return isFinite(inset) && inset > 0 ? inset : 0;
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
        // Canonical source remains separate from ruby so copy, translation, stats and lookup
        // all use exactly the original OCR, including line boundaries and Unicode offsets.
        bubbleText: function(box) {
          return box && typeof box.dataset.ocrText === 'string' ? box.dataset.ocrText : '';
        },
        applyFurigana: function() {
          if (typeof segmentFurigana !== 'function') return;
          document.querySelectorAll('.ocr-box[data-readings]').forEach(function(box) {
            var original = box.dataset.ocrText, annotations;
            try { annotations = JSON.parse(box.dataset.readings); } catch (_) { return; }
            if (typeof original !== 'string' || !Array.isArray(annotations)) return;
            var paragraph = box.querySelector('p'), content = document.createDocumentFragment(), offset = 0;
            annotations.forEach(function(annotation) {
              var start = annotation.start, length = annotation.length, reading = annotation.reading;
              if (!Number.isInteger(start) || !Number.isInteger(length) || start < offset || length <= 0 ||
                  start > original.length || length > original.length - start || typeof reading !== 'string') return;
              content.append(document.createTextNode(original.slice(offset, start)));
              segmentFurigana(original.slice(start, start + length), reading, {strict: true}).forEach(function(segment) {
                if (!segment[1]) { content.append(document.createTextNode(segment[0])); return; }
                var ruby = document.createElement('ruby'), base = document.createElement('span'), rt = document.createElement('rt');
                base.textContent = segment[0]; rt.textContent = segment[1];
                ruby.append(base, rt); content.append(ruby);
              });
              offset = start + length;
            });
            content.append(document.createTextNode(original.slice(offset)));
            paragraph.replaceChildren(content);
            box.classList.toggle('has-furigana', paragraph.querySelector('rt') !== null);
            paragraph.addEventListener('scroll', function() {
              if (window.hoshiSelection) window.hoshiSelection.clearSelection();
              window.hoshiManga.placeActions(box);
            }, {passive: true});
          });
        },
        prepareReveal: function(box) {
          if (box.classList.contains('has-furigana')) box.dataset.furiganaOriginalStyle = box.getAttribute('style') || '';
        },
        // Grow the revealed plate for native ruby at the user's chosen glyph size. Oversized
        // text scrolls inside its own paragraph instead of turning the surrounding manga page.
        fitFurigana: function(box) {
          if (!box.classList.contains('has-furigana') || box.dataset.furiganaFitted === '1') return;
          box.dataset.furiganaFitted = '1';
          var text = box.querySelector('p'), vv = window.visualViewport;
          var viewLeft = (vv ? vv.offsetLeft : 0) + 2, viewTop = (vv ? vv.offsetTop : 0) + 2;
          var viewWidth = Math.max(1, (vv ? vv.width : window.innerWidth) - 4);
          var frame = box.closest('.frame'), actions = frame && frame.querySelector('.ocr-actions');
          var actionHeight = 0;
          if (actions) {
            var previousDisplay = actions.style.display;
            actions.style.display = 'flex'; actionHeight = actions.getBoundingClientRect().height;
            actions.style.display = previousDisplay;
          }
          var viewHeight = Math.max(1, (vv ? vv.height : window.innerHeight) - 10 - actionHeight);
          var vertical = box.classList.contains('vertical');
          var range = document.createRange(); range.selectNodeContents(text);
          function paintedRect() {
            var rect = range.getBoundingClientRect();
            var result = {left:rect.left, top:rect.top, right:rect.right, bottom:rect.bottom};
            text.querySelectorAll('rt').forEach(function(rt) {
              Array.from(rt.getClientRects()).forEach(function(r) {
                result.left = Math.min(result.left, r.left); result.top = Math.min(result.top, r.top);
                result.right = Math.max(result.right, r.right); result.bottom = Math.max(result.bottom, r.bottom);
              });
            });
            return result;
          }
          var painted = paintedRect();
          if ((!vertical && painted.right - painted.left > viewWidth) || (vertical && painted.bottom - painted.top > viewHeight)) {
            box.classList.add('wrap');
            if (vertical) box.style.height = viewHeight + 'px'; else box.style.width = viewWidth + 'px';
          }
          for (var i = 0; i < 3; i++) {
            var rect = box.getBoundingClientRect(); painted = paintedRect();
            var style = window.getComputedStyle(box);
            var width = Math.max(rect.width, vertical ? rect.right - painted.left + parseFloat(style.paddingLeft)
              : painted.right - rect.left + parseFloat(style.paddingRight));
            var height = Math.max(rect.height, painted.bottom - rect.top + parseFloat(style.paddingBottom));
            box.style.width = Math.min(viewWidth, width) + 'px'; box.style.height = Math.min(viewHeight, height) + 'px';
          }
          var rect = box.getBoundingClientRect();
          var left = Math.max(viewLeft, Math.min(rect.left, viewLeft + viewWidth - rect.width));
          var top = Math.max(viewTop, Math.min(rect.top, viewTop + viewHeight - rect.height));
          box.style.left = (box.offsetLeft + left - rect.left) + 'px'; box.style.top = (box.offsetTop + top - rect.top) + 'px';
          painted = paintedRect(); rect = box.getBoundingClientRect();
          if (painted.left < rect.left - 0.5 || painted.top < rect.top - 0.5 || painted.right > rect.right + 0.5 || painted.bottom > rect.bottom + 0.5) {
            box.classList.add('furigana-scroll'); text.scrollLeft = 0; text.scrollTop = 0;
          }
        },
        notifyScrollableBubbleRegions: function() {
          var h = handlers();
          if (!h || !h.hoshiManga) return;
          var regions = [], manga = this;
          document.querySelectorAll('.ocr-box.revealed.furigana-scroll p').forEach(function(p) {
            if (p.scrollWidth <= p.clientWidth + 1 && p.scrollHeight <= p.clientHeight + 1) return;
            regions.push(manga.hostRectFromViewportRect(p.getBoundingClientRect()));
          });
          h.hoshiManga.postMessage({event:'scrollableBubbleRegions', regions:regions});
        },
        annotationBaseHit: function(box, x, y) {
          var annotations = box.querySelectorAll('rt');
          for (var i = 0; i < annotations.length; i++) {
            var rects = annotations[i].getClientRects();
            for (var j = 0; j < rects.length; j++) {
              var r = rects[j];
              if (x < r.left || x > r.right || y < r.top || y > r.bottom) continue;
              var base = annotations[i].parentElement.querySelector('span');
              var node = base && base.firstChild;
              if (node && node.nodeType === Node.TEXT_NODE && node.textContent) return {node:node, offset:0};
            }
          }
          return null;
        },
        selectBaseHit: function(hit, maxLength) {
          var range = document.createRange();
          range.setStart(hit.node, hit.offset);
          range.setEnd(hit.node, hit.offset + String.fromCodePoint(hit.node.textContent.codePointAt(hit.offset)).length);
          var rect = range.getBoundingClientRect();
          return window.hoshiSelection.selectText(rect.left + rect.width / 2, rect.top + rect.height / 2, maxLength);
        },
        clearRevealed: function() {
          var revealed = document.querySelectorAll('.ocr-box.revealed');
          for (var i = 0; i < revealed.length; i++) {
            var paragraph = revealed[i].querySelector('p');
            if (paragraph) { paragraph.scrollLeft = 0; paragraph.scrollTop = 0; }
            if (typeof revealed[i].dataset.furiganaOriginalStyle === 'string') {
              revealed[i].setAttribute('style', revealed[i].dataset.furiganaOriginalStyle);
              delete revealed[i].dataset.furiganaOriginalStyle;
              delete revealed[i].dataset.furiganaFitted;
            }
            revealed[i].classList.remove('furigana-scroll');
            revealed[i].classList.remove('revealed');
            revealed[i].setAttribute('aria-pressed', 'false');
            // Restore the image-relative font after a wrap-fallback enlargement.
            if (typeof revealed[i].dataset.wrapOriginalFontSize === 'string') {
              revealed[i].style.fontSize = revealed[i].dataset.wrapOriginalFontSize;
              delete revealed[i].dataset.wrapOriginalFontSize;
            }
            revealed[i].classList.remove('wrap');
            delete revealed[i].dataset.wrapTried;
          }
          this.notifyScrollableBubbleRegions();
          var hosts = document.querySelectorAll('.ocr-actions');
          for (var h = 0; h < hosts.length; h++) {
            this.hideActions(hosts[h]);
          }
          if (window.hoshiSelection) {
            window.hoshiSelection.clearSelection();
          }
        },
        tryWrapFallback: function(box) {
          if (document.body.dataset.enlargeText === 'false' || box.dataset.wrapTried === '1') return;
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
          box.dataset.wrapOriginalFontSize = originalInlineFontSize;
          function overflowing() {
            return box.scrollWidth > box.clientWidth ||
              box.scrollHeight > box.clientHeight;
          }
          function setFs(px) { box.style.fontSize = px + 'px'; }
          function findMaxFitting(start) {
            // Integer bounds make every floored midpoint advance, including fractional cqw sizes.
            start = Math.floor(start);
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
        renderedTextRects: function(box) {
          var text = box.querySelector('p');
          if (!text) {
            return [];
          }
          var rects = [];
          function addRect(rect) {
            if (!rect || rect.width <= 0 || rect.height <= 0) return;
            rects.push(rect);
          }
          if (document.createRange) {
            var range = document.createRange();
            range.selectNodeContents(text);
            var clientRects = range.getClientRects();
            for (var i = 0; i < clientRects.length; i++) {
              addRect(clientRects[i]);
            }
            var annotations = text.querySelectorAll('rt');
            for (var r = 0; r < annotations.length; r++) {
              var rubyRects = annotations[r].getClientRects();
              for (var j = 0; j < rubyRects.length; j++) addRect(rubyRects[j]);
            }
            range.detach && range.detach();
          }
          if (!rects.length) {
            addRect(text.getBoundingClientRect());
          }
          if (box.classList.contains('furigana-scroll')) {
            var clip = text.getBoundingClientRect();
            rects = rects.map(function(rect) {
              var left = Math.max(clip.left, rect.left), top = Math.max(clip.top, rect.top);
              var right = Math.min(clip.right, rect.right), bottom = Math.min(clip.bottom, rect.bottom);
              return {left:left, top:top, right:right, bottom:bottom, width:right-left, height:bottom-top};
            }).filter(function(rect) { return rect.width > 0 && rect.height > 0; });
          }
          return rects;
        },
        renderedBoxRect: function(box) {
          var rect = box.getBoundingClientRect();
          if (!box.classList.contains('revealed')) {
            return rect;
          }
          var rects = this.renderedTextRects(box);
          var unionLeft = rect.left;
          var unionTop = rect.top;
          var unionRight = rect.right;
          var unionBottom = rect.bottom;
          for (var i = 0; i < rects.length; i++) {
            unionLeft = Math.min(unionLeft, rects[i].left);
            unionTop = Math.min(unionTop, rects[i].top);
            unionRight = Math.max(unionRight, rects[i].right);
            unionBottom = Math.max(unionBottom, rects[i].bottom);
          }
          return {
            x: unionLeft,
            y: unionTop,
            left: unionLeft,
            top: unionTop,
            right: unionRight,
            bottom: unionBottom,
            width: unionRight - unionLeft,
            height: unionBottom - unionTop
          };
        },
        placeActions: function(box) {
          var frame = box.closest('.frame');
          var actions = frame && frame.querySelector('.ocr-actions');
          if (!actions) return;
          var gap = 4;
          var bubbleText = box.querySelector('p');
          actions.dataset.bubbleText = this.bubbleText(box);
          // Carry the bubble's mokuro address so the AI request can find its pre-computed
          // offline translation without re-matching on text.
          actions.dataset.blockId = (box.dataset && box.dataset.hoshiBlock) || '';
          var aiButton = actions.querySelector('.ocr-ai-btn');
          var copyButton = actions.querySelector('.ocr-copy-btn');
          var uiTestSuffix = box.dataset && box.dataset.hoshiUiTest ? (' ' + actions.dataset.bubbleText) : '';
          if (aiButton) {
            aiButton.setAttribute('aria-label', 'Ask about this bubble' + uiTestSuffix);
          }
          if (copyButton) {
            copyButton.setAttribute('aria-label', 'Copy bubble text' + uiTestSuffix);
          }
          // A hidden toolbar has no layout dimensions. Measure its actual buttons before
          // choosing an anchor, so first reveal and subsequent lookup taps use the same size.
          var previousDisplay = actions.style.display;
          actions.style.display = 'flex';
          var actionsWidth = actions.offsetWidth;
          var actionsHeight = actions.offsetHeight;
          actions.style.display = previousDisplay;
          if (actionsWidth <= 0 || actionsHeight <= 0) return;
          var boxWidth = box.clientWidth;
          var boxHeight = box.clientHeight;
          // Position in frame-local coordinates so the toolbar is not clipped by an ultra-thin box.
          var left = box.offsetLeft + (boxWidth / 2) - (actionsWidth / 2);
          var top = -actionsHeight - gap;
          if (frame) {
            var minLeft = gap;
            var maxLeft = frame.clientWidth - actionsWidth - gap;
            if (isFinite(minLeft) && isFinite(maxLeft) && minLeft <= maxLeft) {
              left = Math.max(minLeft, Math.min(left, maxLeft));
            }
            var minGlobalTop = gap;
            var minTop = minGlobalTop;
            var maxTop = frame.clientHeight - actionsHeight - gap;
            var frameTop = frame.offsetTop || 0;
            if (window.hoshiManga && window.hoshiManga.hostTappableTopInset) {
              var hostMinTop = (
                window.hoshiManga.hostOffsetTop() + window.hoshiManga.hostTappableTopInset()
              ) / window.hoshiManga.hostScale();
              if (isFinite(hostMinTop)) {
                minGlobalTop = Math.max(minGlobalTop, hostMinTop + gap);
                minTop = minGlobalTop - frameTop;
              }
            }
            var belowClearance = Math.max(gap + 10, Math.ceil(actionsHeight * 0.65));
            var renderedTop = box.offsetTop;
            var renderedBottom = box.offsetTop + boxHeight;
            if (window.getComputedStyle) {
              var boxStyle = window.getComputedStyle(box);
              var boxFontSize = boxStyle ? parseFloat(boxStyle.fontSize) : NaN;
              if (isFinite(boxFontSize)) {
                belowClearance = Math.max(belowClearance, Math.ceil(boxFontSize * 0.35));
              }
            }
            if (window.hoshiManga && window.hoshiManga.renderedBoxRect &&
                frame.getBoundingClientRect) {
              var frameRect = frame.getBoundingClientRect();
              var renderedRect = window.hoshiManga.renderedBoxRect(box);
              if (frameRect && renderedRect && isFinite(renderedRect.top) && isFinite(renderedRect.bottom)) {
                renderedTop = renderedRect.top - frameRect.top;
                renderedBottom = renderedRect.bottom - frameRect.top;
              }
            }
            var renderedLeft = box.offsetLeft;
            var renderedRight = box.offsetLeft + boxWidth;
            var avoidRects = [];
            if (frame.getBoundingClientRect && window.hoshiManga && window.hoshiManga.renderedBoxRect) {
              var localFrameRect = frame.getBoundingClientRect();
              var localRenderedRect = window.hoshiManga.renderedBoxRect(box);
              if (localFrameRect && localRenderedRect &&
                  isFinite(localRenderedRect.left) && isFinite(localRenderedRect.right)) {
                renderedLeft = localRenderedRect.left - localFrameRect.left;
                renderedRight = localRenderedRect.right - localFrameRect.left;
              }
              if (window.hoshiManga.renderedTextRects) {
                var lineRects = window.hoshiManga.renderedTextRects(box);
                for (var lr = 0; lr < lineRects.length; lr++) {
                  if (lineRects[lr] && isFinite(lineRects[lr].left) && isFinite(lineRects[lr].right) &&
                      isFinite(lineRects[lr].top) && isFinite(lineRects[lr].bottom)) {
                    avoidRects.push({
                      left: lineRects[lr].left - localFrameRect.left,
                      right: lineRects[lr].right - localFrameRect.left,
                      top: lineRects[lr].top - localFrameRect.top,
                      bottom: lineRects[lr].bottom - localFrameRect.top
                    });
                  }
                }
              }
            }
            if (!avoidRects.length) {
              avoidRects.push({
                left: renderedLeft,
                right: renderedRight,
                top: renderedTop,
                bottom: renderedBottom
              });
            }
            var avoidGap = Math.max(gap + 10, Math.ceil(actionsHeight * 0.55));
            var aboveTop = renderedTop - actionsHeight - avoidGap;
            var belowTop = renderedBottom + Math.max(belowClearance, avoidGap);
            var sideTop = renderedTop + ((renderedBottom - renderedTop) / 2) - (actionsHeight / 2);
            var rightLeft = renderedRight + avoidGap;
            var leftLeft = renderedLeft - actionsWidth - avoidGap;
            function clampTop(value) {
              if (isFinite(minTop) && isFinite(maxTop) && minTop <= maxTop) {
                return Math.max(minTop, Math.min(value, maxTop));
              }
              return value;
            }
            function clampLeft(value) {
              if (isFinite(minLeft) && isFinite(maxLeft) && minLeft <= maxLeft) {
                return Math.max(minLeft, Math.min(value, maxLeft));
              }
              return value;
            }
            function overlapArea(leftValue, topValue) {
              var total = 0;
              for (var ar = 0; ar < avoidRects.length; ar++) {
                var overlapLeft = Math.max(leftValue, avoidRects[ar].left - avoidGap);
                var overlapRight = Math.min(leftValue + actionsWidth, avoidRects[ar].right + avoidGap);
                var overlapTop = Math.max(topValue, avoidRects[ar].top - avoidGap);
                var overlapBottom = Math.min(topValue + actionsHeight, avoidRects[ar].bottom + avoidGap);
                var overlapWidth = Math.max(0, overlapRight - overlapLeft);
                var overlapHeight = Math.max(0, overlapBottom - overlapTop);
                total += overlapWidth * overlapHeight;
              }
              return total;
            }
            function makeCandidate(name, leftValue, topValue) {
              var candidateLeft = clampLeft(leftValue);
              var candidateTop = clampTop(topValue);
              return {
                name: name,
                left: candidateLeft,
                top: candidateTop,
                overlap: overlapArea(candidateLeft, candidateTop),
                distance: Math.abs(candidateLeft - leftValue) + Math.abs(candidateTop - topValue),
                topClamped: Math.abs(candidateTop - topValue) > 0.5
              };
            }
            var preferRight = frame.clientWidth - renderedRight >= renderedLeft;
            var sideA = preferRight
              ? makeCandidate('right', rightLeft, sideTop)
              : makeCandidate('left', leftLeft, sideTop);
            var sideB = preferRight
              ? makeCandidate('left', leftLeft, sideTop)
              : makeCandidate('right', rightLeft, sideTop);
            var candidates = [
              makeCandidate('above', left, aboveTop),
              sideA,
              sideB,
              makeCandidate('below', left, belowTop)
            ];
            var selected = null;
            for (var c = 0; c < candidates.length; c++) {
              var requiresFreeTop = candidates[c].name === 'above' || candidates[c].name === 'below';
              if (candidates[c].overlap <= 0 && (!requiresFreeTop || !candidates[c].topClamped)) {
                selected = candidates[c];
                break;
              }
            }
            if (!selected) {
              window.hoshiManga.hideActions(actions);
              return;
            }
            left = selected.left;
            top = selected.top;
            actions.dataset.placement = selected.name;
            if (frameTop + top < minGlobalTop) {
              top = minGlobalTop - frameTop;
            }
            top = clampTop(top);
            if (overlapArea(left, top) > 0) {
              window.hoshiManga.hideActions(actions);
              return;
            }
          }
          actions.style.left = Math.round(left) + 'px';
          actions.style.top = Math.round(top) + 'px';
          actions.classList.add('is-visible');
          actions.setAttribute('aria-hidden', 'false');
        },
        actionLayoutProbe: function() {
          var boxes = document.querySelectorAll('.ocr-box[data-hoshi-ui-test]');
          var results = [];
          for (var i = 0; i < boxes.length; i++) {
            var box = boxes[i];
            this.clearRevealed();
            box.classList.add('revealed');
            this.tryWrapFallback(box);
            box.setAttribute('aria-pressed', 'true');
            this.placeActions(box);
            var frame = box.closest('.frame');
            var actions = frame && frame.querySelector('.ocr-actions');
            var ai = actions && actions.querySelector('.ocr-ai-btn');
            var copy = actions && actions.querySelector('.ocr-copy-btn');
            function rectFor(element) {
              if (!element) return null;
              var rect = element.getBoundingClientRect();
              return window.hoshiManga.hostRectFromViewportRect(rect);
            }
            function hostRect(rect) {
              if (!rect) return null;
              return window.hoshiManga.hostRectFromViewportRect(rect);
            }
            var aiRect = rectFor(ai);
            var copyRect = rectFor(copy);
            var boxRect = hostRect(box.getBoundingClientRect());
            var text = box.querySelector('p');
            var textRects = [];
            var rawTextRects = window.hoshiManga.renderedTextRects(box);
            for (var tr = 0; tr < rawTextRects.length; tr++) {
              var mappedTextRect = hostRect(rawTextRects[tr]);
              if (mappedTextRect) textRects.push(mappedTextRect);
            }
            var textRect = hostRect(window.hoshiManga.renderedBoxRect(box));
            results.push({
              id: box.dataset.hoshiUiTest || '',
              text: this.bubbleText(box),
              box: boxRect,
              textRect: textRect,
              textRects: textRects,
              ai: aiRect,
              copy: copyRect,
              placement: actions && actions.dataset ? (actions.dataset.placement || '') : '',
              topInset: this.hostTappableTopInset()
            });
          }
          this.clearRevealed();
          return results;
        },
        installTapListener: function(maxLength) {
          if (this.tapListenerInstalled) return;
          this.tapListenerInstalled = true;
          var touchStart = null;
          var lastHandledTouchAt = 0;
          function dispatchTap(x, y, event) {
            if (!window.hoshiManga) return;
            if (event) {
              event.preventDefault();
              event.stopPropagation();
            }
            var result = window.hoshiManga.handleTap(x, y, maxLength);
            if (result === null || typeof result === 'undefined') {
              var h = handlers();
              if (h && h.hoshiManga) {
                h.hoshiManga.postMessage({ event: 'selectedNothing' });
              }
            }
          }
          document.addEventListener('touchstart', function(event) {
            if (!event.touches || event.touches.length !== 1) {
              touchStart = null;
              return;
            }
            var touch = event.touches[0];
            touchStart = {
              x: touch.clientX,
              y: touch.clientY,
              time: Date.now()
            };
          }, { capture: true, passive: true });
          document.addEventListener('touchend', function(event) {
            if (!touchStart || !event.changedTouches || event.changedTouches.length !== 1) {
              touchStart = null;
              return;
            }
            if (event.touches && event.touches.length > 0) {
              touchStart = null;
              return;
            }
            var touch = event.changedTouches[0];
            var dx = touch.clientX - touchStart.x;
            var dy = touch.clientY - touchStart.y;
            var distance = Math.sqrt(dx * dx + dy * dy);
            var elapsed = Date.now() - touchStart.time;
            touchStart = null;
            if (distance > 14 || elapsed > 900) {
              return;
            }
            lastHandledTouchAt = Date.now();
            dispatchTap(touch.clientX, touch.clientY, event);
          }, { capture: true, passive: false });
          document.addEventListener('touchcancel', function() {
            touchStart = null;
          }, { capture: true, passive: true });
          document.addEventListener('click', function(event) {
            if (Date.now() - lastHandledTouchAt < 700) {
              event.preventDefault();
              event.stopPropagation();
              return;
            }
            dispatchTap(event.clientX, event.clientY, event);
          }, true);
        },
        hitSlopBoxAt: function(x, y) {
          return this.revealedBoxAt(x, y, 12) ||
            this.boxFromHitSlop(document.querySelectorAll('.ocr-box'), x, y);
        },
        revealedBoxAt: function(x, y, slop) {
          var revealed = document.querySelectorAll('.ocr-box.revealed');
          return this.boxFromHitSlop(revealed, x, y, slop || 0);
        },
        boxFromHitSlop: function(boxes, x, y, fixedSlop) {
          var best = null;
          var bestArea = Infinity;
          for (var i = 0; i < boxes.length; i++) {
            var box = boxes[i];
            var rect = this.renderedBoxRect(box);
            var slop = typeof fixedSlop === 'number'
              ? fixedSlop
              : (box.classList.contains('revealed') ? 12 : 8);
            if (rect.width < 10 || rect.height < 10) {
              slop = Math.max(slop, 20);
            }
            var left = rect.left - slop;
            var right = rect.right + slop;
            var top = rect.top - slop;
            var bottom = rect.bottom + slop;
            if (x < left || x > right || y < top || y > bottom) continue;
            var area = Math.max(1, rect.width) * Math.max(1, rect.height);
            if (area < bestArea) {
              best = box;
              bestArea = area;
            }
          }
          return best;
        },
        handleTap: function(x, y, maxLength) {
          var el = document.elementFromPoint(x, y);
          var aiBtn = el && el.closest && el.closest('.ocr-ai-btn');
          if (aiBtn) {
            var aiActions = aiBtn.closest('.ocr-actions');
            var aiText = aiActions && aiActions.dataset ? aiActions.dataset.bubbleText : '';
            var aiBlockId = aiActions && aiActions.dataset ? (aiActions.dataset.blockId || '') : '';
            var h = handlers();
            if (aiText && h && h.hoshiMangaAi) {
              h.hoshiMangaAi.postMessage({ text: aiText, blockId: aiBlockId });
            }
            window.hoshiManga.clearRevealed();
            return '__ai__';
          }
          var copyBtn = el && el.closest && el.closest('.ocr-copy-btn');
          if (copyBtn) {
            var copyActions = copyBtn.closest('.ocr-actions');
            var copyText = copyActions && copyActions.dataset ? copyActions.dataset.bubbleText : '';
            var hc = handlers();
            if (copyText && hc && hc.hoshiMangaClipboard) {
              hc.hoshiMangaClipboard.postMessage({ text: copyText });
            }
            window.hoshiManga.clearRevealed();
            return '__copied__';
          }
          var directBox = el && el.closest && el.closest('.ocr-box');
          var box = window.hoshiManga.revealedBoxAt(x, y) ||
            window.hoshiManga.hitSlopBoxAt(x, y) ||
            directBox;
          if (box) {
            var alreadyRevealed = box.classList.contains('revealed');
            var initialHit = !alreadyRevealed && this.singleTapLookupValue && window.hoshiSelection
              ? (this.annotationBaseHit(box, x, y) || window.hoshiSelection.getCharacterAtPoint(x, y)) : null;
            if (!alreadyRevealed) {
              window.hoshiManga.clearRevealed();
              // The image-relative font is the same before and after reveal.
              window.hoshiManga.prepareReveal(box);
              box.classList.add('revealed');
              var revealedText = box.querySelector('p');
              window.webkit.messageHandlers.hoshiManga.postMessage({event: 'bubbleRevealed', text: window.hoshiManga.bubbleText(box), blockId: box.dataset.hoshiBlock || ''});
              window.hoshiManga.tryWrapFallback(box);
              window.hoshiManga.fitFurigana(box);
              window.hoshiManga.notifyScrollableBubbleRegions();
              box.setAttribute('aria-pressed', 'true');
              window.hoshiManga.placeActions(box);
            } else {
              window.hoshiManga.placeActions(box);
            }
            if (alreadyRevealed || window.hoshiManga.singleTapLookupValue) {
              if (initialHit) return this.selectBaseHit(initialHit, maxLength);
              var annotationHit = this.annotationBaseHit(box, x, y);
              return annotationHit ? this.selectBaseHit(annotationHit, maxLength) : window.hoshiSelection.selectText(x, y, maxLength);
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
