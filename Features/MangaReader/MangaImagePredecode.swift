// Copyright © 2026 Manhhao.
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

nonisolated struct MangaImageDecodeCandidate: Sendable {
    let url: String
    let width: Int
    let height: Int
}

/// Best-effort WebKit decoding is sequential and bounded separately from encoded bytes.
/// A navigation or backgrounding the document immediately releases its speculative images.
nonisolated enum MangaImagePredecode {
    static func script(pageIndex: Int, candidates: [MangaImageDecodeCandidate], budget: Int = 64 * 1024 * 1024) -> String {
        let urls = (try? JSONEncoder().encode(candidates.map(\.url))).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let sizes = (try? JSONEncoder().encode(candidates.map { estimatedBytes(width: $0.width, height: $0.height) }))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return """
        (function() {
          if (!document.querySelector('.frame[data-page-index="\(pageIndex)"]')) return;
          if (window.hoshiMangaImageCache) window.hoshiMangaImageCache.cancel();
          var urls = \(urls), sizes = \(sizes), budget = \(max(0, budget));
          var state = {images:[], decoded:[], failed:[], skipped:[], bytes:0, done:false};
          var stopped = false, pending = null, timer = null;
          state.cancel = function() {
            stopped = true;
            window.removeEventListener('pagehide', state.cancel);
            document.removeEventListener('visibilitychange', visibilityChanged);
            clearTimeout(timer);
            if (pending) pending();
            state.images.forEach(function(image) { image.removeAttribute('src'); });
            state.images = []; state.bytes = 0;
          };
          window.hoshiMangaImageCache = state;
          window.addEventListener('pagehide', state.cancel, {once:true});
          function visibilityChanged() { if (document.hidden) state.cancel(); }
          document.addEventListener('visibilitychange', visibilityChanged);
          function prepare(url, estimate) {
            return new Promise(function(resolve) {
              var image = new Image(), settled = false;
              var timeout = setTimeout(function() { finish(false); }, 10000);
              function finish(ok) {
                if (settled) return;
                settled = true; clearTimeout(timeout);
                image.onload = image.onerror = null; pending = null;
                if (ok && !stopped) { state.images.push(image); state.decoded.push(url); state.bytes += estimate; }
                else { image.removeAttribute('src'); if (!stopped) state.failed.push(url); }
                resolve();
              }
              pending = function() { finish(false); };
              image.onload = function() {
                estimate = image.naturalWidth * image.naturalHeight * 4;
                if (estimate <= 0 || estimate > budget - state.bytes) { finish(false); return; }
                if (image.decode) image.decode().then(function() { finish(true); }, function() { finish(false); });
                else finish(false);
              };
              image.onerror = function() { finish(false); };
              image.decoding = 'async'; image.src = url;
            });
          }
          async function run() {
            for (var i = 0; i < urls.length && !stopped; i++) {
              if (document.hidden) break;
              if (sizes[i] <= 0 || sizes[i] > budget - state.bytes) { state.skipped.push(urls[i]); continue; }
              await prepare(urls[i], sizes[i]);
            }
            state.done = true;
          }
          timer = setTimeout(run, 0);
        })();
        """
    }

    static func estimatedBytes(width: Int, height: Int) -> Int {
        guard width > 0, height > 0 else { return 0 }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
        return overflow || byteOverflow ? Int.max : bytes
    }
}
