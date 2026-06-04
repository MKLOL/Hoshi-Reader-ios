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
            .map { textBoxHtml($0, imageWidth: imageWidth, imageHeight: imageHeight) }
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
        (function() {
          // Place the dictionary popup clear of the whole OCR text box (the sentence being
          // read), not just the tapped character. selection.js posts the tapped character's
          // tiny rect to webkit.messageHandlers.textSelected; here we substitute the containing
          // .ocr-box's host rect into the payload before it reaches native, so the popup layout
          // positions above/below the entire bubble. We intercept at the `messageHandlers`
          // object so it works regardless of whether the host hands back a fresh wrapper on
          // each property access. This is a cosmetic enhancement — if interception fails for
          // any reason, the popup simply opens at the tapped-character rect instead.
          function substituteRect(payload) {
            try {
              var sel = window.hoshiSelection && window.hoshiSelection.selection;
              var node = sel && sel.startNode;
              var el = node && (node.nodeType === 1 ? node : node.parentElement);
              var box = el && el.closest && el.closest('.ocr-box');
              if (box && payload) {
                var r = box.getBoundingClientRect();
                payload.rect = window.hoshiManga && window.hoshiManga.hostRectFromViewportRect
                  ? window.hoshiManga.hostRectFromViewportRect(r)
                  : { x: r.x, y: r.y, width: r.width, height: r.height };
              }
            } catch (e) {}
            return payload;
          }
          var mh = window.webkit && window.webkit.messageHandlers;
          var nativeTextSelected = mh && mh.textSelected;
          if (!nativeTextSelected || !nativeTextSelected.postMessage) return;
          var shim = {
            postMessage: function(payload) {
              return nativeTextSelected.postMessage(substituteRect(payload));
            }
          };
          // Prefer redefining the property so selection.js's later access returns the shim.
          try {
            Object.defineProperty(mh, 'textSelected', {
              configurable: true,
              get: function() { return shim; }
            });
          } catch (e) {
            // Fall back to mutating the captured wrapper's postMessage in place.
            try {
              var originalPost = nativeTextSelected.postMessage.bind(nativeTextSelected);
              nativeTextSelected.postMessage = function(payload) { originalPost(substituteRect(payload)); };
            } catch (e2) {}
          }
        })();
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
          text-shadow:
            1px 1px 1px #fff, -1px 1px 1px #fff, 1px -1px 1px #fff, -1px -1px 1px #fff,
            2px 0 2px #fff, -2px 0 2px #fff, 0 2px 2px #fff, 0 -2px 2px #fff;
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
          position: absolute;
          bottom: 100%;
          right: 0;
          margin-bottom: 3px;
          writing-mode: horizontal-tb;
          text-orientation: mixed;
          flex-direction: row-reverse;
          gap: 3px;
          z-index: 2;
        }
        .ocr-box.revealed .ocr-actions {
          display: flex;
        }
        .ocr-action-btn {
          box-sizing: border-box;
          width: 1.7em;
          height: 1.7em;
          min-width: 20px;
          min-height: 20px;
          padding: 0.3em;
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
        ::selection { background: rgba(70, 130, 220, 0.45); }
        \(matchedWordHighlight)
        """
    }

    private static func textBoxHtml(
        _ box: MokuroTextBox,
        imageWidth: Int,
        imageHeight: Int
    ) -> String {
        let leftPct = percent(box.left, imageWidth)
        let topPct = percent(box.top, imageHeight)
        let widthPct = percent(box.width, imageWidth)
        let heightPct = percent(box.height, imageHeight)
        // Font size is in image pixels; express it relative to image width so it scales with
        // the rendered frame (cqw = 1% of the container's width).
        let fontCqw = percent(box.fontSize, imageWidth)
        let verticalClass = box.vertical ? " vertical" : ""
        // Join with literal `\n` so the shared selection scanner sees mokuro's line boundaries
        // as sentence delimiters; `.ocr-box`'s `white-space: pre` renders it as a real break.
        let text = box.lines.map(escapeHtmlText).joined(separator: "\n")
        return """
            <div class="ocr-box\(verticalClass)" role="button" tabindex="0" \
        aria-pressed="false" style="left: \(leftPct)%; top: \(topPct)%; \
        width: \(widthPct)%; height: \(heightPct)%; font-size: \(fontCqw)cqw;">\
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
              window.hoshiManga.tryWrapFallback(box);
              box.classList.add('revealed');
              box.setAttribute('aria-pressed', 'true');
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
