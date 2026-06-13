//
//  MangaReaderWebView.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  The WKWebView that renders one mokuro manga page at a time. Ported from Android
//  `features/mangareader/MangaReaderWebView.kt` + `MangaWebResourceBridge.kt`, adapted for
//  WebKit:
//   - A `WKURLSchemeHandler` for `hoshi-img` serves page images off disk from the book's
//     `images/` folder, with path-traversal containment + an allow-list of the current page's
//     declared image paths.
//   - WKScriptMessageHandlers (hoshiManga, hoshiMangaAi, hoshiMangaClipboard, textSelected)
//     route in-page taps. selection.js posts directly to `textSelected`; the manga tap handler
//     posts to the others.
//   - Per-page HTML is loaded via `loadHTMLString(_, baseURL: hoshi-img://manga/)`.
//   - Pinch-zoom is the scrollView's own min/max zoom; when zoomed/scrollable, swipe-to-turn is
//     gated, and the scrollView's zoomScale/contentOffset feed JS for correct popup/crop mapping.
//

import SwiftUI
import WebKit

/// Drives the manga WebView from SwiftUI: load a page, clear reveals before a crop, and request
/// the image-pixel crop rect for a host-pixel drag rectangle.
@Observable
@MainActor
final class MangaWebViewController {
    /// Bumped to request a (re)load of the current page HTML.
    fileprivate(set) var loadToken = 0
    fileprivate var pendingHtml: String?
    fileprivate var allowedImagePaths: Set<String> = []
    fileprivate weak var webView: WKWebView?

    /// Book root used by the scheme handler to resolve `hoshi-img://` requests off disk.
    var bookRootForScheme: URL?

    /// True while the page is zoomed or panned, so the host should gate swipe-to-turn.
    private(set) var isZoomedOrScrollable = false

    /// Replaces the rendered page. `allowedImagePaths` is the allow-list of book-root-relative
    /// image paths the scheme handler may serve for this page (normally just the page's image).
    @discardableResult
    func load(html: String, allowedImagePaths: Set<String>) -> Int {
        self.pendingHtml = html
        self.allowedImagePaths = allowedImagePaths
        loadToken += 1
        return loadToken
    }

    /// Hides any revealed OCR plates/buttons before a raw page crop.
    func clearRevealedBubbles() {
        webView?.evaluateJavaScript(
            "window.hoshiManga && window.hoshiManga.clearRevealed && window.hoshiManga.clearRevealed()"
        ) { _, _ in }
    }

    /// Snapshots the currently-rendered page into a `UIImage` so it can be slid off-screen while
    /// the WebView reloads to the next page underneath (the directional page-turn animation). Uses
    /// `takeSnapshot`, which captures the out-of-process WebKit content the way `layer.render`
    /// cannot. Returns `nil` when the WebView is not laid out or the snapshot fails — the caller
    /// then swaps the page without a slide.
    func snapshotCurrentPage() async -> UIImage? {
        guard let webView else { return nil }
        let bounds = webView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let config = WKSnapshotConfiguration()
        config.rect = bounds
        config.afterScreenUpdates = false
        return try? await webView.takeSnapshot(configuration: config)
    }

    /// Maps a host-pixel drag rectangle to an image-pixel crop using the page script.
    func imageCropRect(for rect: MangaScreenshotCropRect) async -> MangaImageCropRect? {
        guard let webView else { return nil }
        let hostWidth = Int(webView.bounds.width.rounded())
        let hostHeight = Int(webView.bounds.height.rounded())
        guard hostWidth > 0, hostHeight > 0 else { return nil }
        let script = """
        (function() {
          if (!window.hoshiManga || !window.hoshiManga.imageCropFromHostRect) { return null; }
          return window.hoshiManga.imageCropFromHostRect(\(rect.left), \(rect.top), \(rect.right), \(rect.bottom), \(hostWidth), \(hostHeight));
        })();
        """
        let result = try? await webView.evaluateJavaScript(script)
        return parseMangaImageCropRect(result as? [String: Any])
    }

    fileprivate func syncHostViewport() {
        guard let webView else { return }
        let raw = webView.scrollView.zoomScale
        let scale = raw.isFinite && raw > 0 ? raw : 1
        let contentOffset = webView.scrollView.contentOffset
        let offsetX = contentOffset.x.isFinite ? contentOffset.x : 0
        let offsetY = contentOffset.y.isFinite ? contentOffset.y : 0
        let script = """
        window.hoshiManga && window.hoshiManga.setHostViewport(\(Double(scale)), \(Double(offsetX)), \(Double(offsetY)))
        """
        webView.evaluateJavaScript(script) { _, _ in }
        // Zoomed-in, or panned away from a fitted origin: gate page turns.
        let zoomed = raw > webView.scrollView.minimumZoomScale + 0.01
        let panned = abs(contentOffset.x) > 1 || abs(contentOffset.y) > 1
        isZoomedOrScrollable = zoomed || panned
    }

    func uiTestViewportProbeLabel() -> String {
        guard let webView else { return "zoom=nil;offsetX=nil;offsetY=nil" }
        let scrollView = webView.scrollView
        return String(
            format: "zoom=%.3f;offsetX=%.1f;offsetY=%.1f",
            Double(scrollView.zoomScale),
            Double(scrollView.contentOffset.x),
            Double(scrollView.contentOffset.y)
        )
    }

    fileprivate func attach(_ webView: WKWebView) {
        self.webView = webView
    }
}

struct MangaReaderWebView: UIViewRepresentable {
    let controller: MangaWebViewController
    let backgroundColor: UIColor
    /// Right-to-left manga paging: a right swipe moves forward (matches MangaPageNavigation).
    var onNavigate: (NavigationDirection) -> Void
    /// A revealed OCR word was tapped for lookup — drives the shared PopupView.
    var onTextSelected: (SelectionData) -> Int?
    /// Empty artwork tapped — dismiss any lookup popup.
    var onTapOutside: () -> Void
    /// A bubble's sparkles button was tapped — bubble text for the AI controller.
    var onAskAi: (String) -> Void
    /// A bubble's copy button was tapped — bubble text to copy.
    var onCopy: (String) -> Void
    /// Called once the page HTML finished loading, with the controller load token for that navigation.
    var onPageReady: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Register the image scheme handler BEFORE creating the webview.
        config.setURLSchemeHandler(context.coordinator, forURLScheme: MangaImageScheme.scheme)
        let controllerJS = config.userContentController
        controllerJS.add(context.coordinator, name: "textSelected")
        controllerJS.add(context.coordinator, name: "hoshiManga")
        controllerJS.add(context.coordinator, name: "hoshiMangaAi")
        controllerJS.add(context.coordinator, name: "hoshiMangaClipboard")
        config.defaultWebpagePreferences.preferredContentMode = .mobile

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = backgroundColor
        webView.scrollView.backgroundColor = backgroundColor
        webView.navigationDelegate = context.coordinator
        webView.scrollView.delegate = context.coordinator
        Self.configureZoom(for: webView.scrollView)
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        let coordinator = context.coordinator
        // RTL swipe gestures: a right swipe is forward, a left swipe is backward. These are
        // gated by the coordinator when the page is zoomed/scrollable.
        let swipeLeft = UISwipeGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleSwipeLeft(_:)))
        swipeLeft.direction = .left
        swipeLeft.delegate = coordinator
        swipeLeft.cancelsTouchesInView = false
        webView.addGestureRecognizer(swipeLeft)

        let swipeRight = UISwipeGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleSwipeRight(_:)))
        swipeRight.direction = .right
        swipeRight.delegate = coordinator
        swipeRight.cancelsTouchesInView = false
        webView.addGestureRecognizer(swipeRight)

        let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.handlePinch(_:)))
        pinch.delegate = coordinator
        pinch.cancelsTouchesInView = false
        webView.addGestureRecognizer(pinch)

        controller.attach(webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.bookRoot = controller.bookRootForScheme
        if context.coordinator.lastLoadToken != controller.loadToken, let html = controller.pendingHtml {
            let loadToken = controller.loadToken
            context.coordinator.lastLoadToken = loadToken
            context.coordinator.allowedImagePaths = controller.allowedImagePaths
            webView.scrollView.setZoomScale(1, animated: false)
            if let navigation = webView.loadHTMLString(html, baseURL: URL(string: MangaPageHtml.baseURLString)) {
                context.coordinator.trackNavigation(navigation, loadToken: loadToken)
            }
        }
    }

    private static func configureZoom(for scrollView: UIScrollView) {
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.bouncesZoom = true
        scrollView.pinchGestureRecognizer?.isEnabled = false
        // Allow free diagonal panning when zoomed in. With directional lock on, a drag snaps to one
        // axis ("only left/right/up/down"); we want the page to follow the finger in any direction.
        scrollView.isDirectionalLockEnabled = false
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        let controllerJS = webView.configuration.userContentController
        controllerJS.removeScriptMessageHandler(forName: "textSelected")
        controllerJS.removeScriptMessageHandler(forName: "hoshiManga")
        controllerJS.removeScriptMessageHandler(forName: "hoshiMangaAi")
        controllerJS.removeScriptMessageHandler(forName: "hoshiMangaClipboard")
        webView.scrollView.delegate = nil
        webView.navigationDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler,
                             WKURLSchemeHandler, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parent: MangaReaderWebView
        var lastLoadToken = 0
        var allowedImagePaths: Set<String> = []
        /// Snapshotted from the controller in updateUIView so the scheme handler never reaches
        /// into MainActor-isolated state from its (main-thread) callback.
        var bookRoot: URL?
        /// In-flight scheme tasks by identity; a task that WebKit has `stop`ped is removed, so we
        /// never call back into a cancelled task (which throws).
        private var activeSchemeTasks = Set<ObjectIdentifier>()
        /// WKNavigation -> controller load token. `didFinish` can arrive out of order during fast
        /// page turns, so the host only trusts completions for the navigation it asked to load.
        private var navigationLoadTokens: [ObjectIdentifier: Int] = [:]

        init(_ parent: MangaReaderWebView) {
            self.parent = parent
        }

        // MARK: Navigation

        func trackNavigation(_ navigation: WKNavigation, loadToken: Int) {
            navigationLoadTokens[ObjectIdentifier(navigation)] = loadToken
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let navigation else { return }
            guard let finishedLoadToken = navigationLoadTokens.removeValue(forKey: ObjectIdentifier(navigation)) else {
                return
            }
            MangaReaderWebView.configureZoom(for: webView.scrollView)
            parent.controller.syncHostViewport()
            parent.onPageReady(finishedLoadToken)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if let navigation {
                navigationLoadTokens.removeValue(forKey: ObjectIdentifier(navigation))
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if let navigation {
                navigationLoadTokens.removeValue(forKey: ObjectIdentifier(navigation))
            }
        }

        // MARK: Script messages

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "textSelected":
                guard let body = message.body as? [String: Any],
                      let text = body["text"] as? String,
                      let sentence = body["sentence"] as? String,
                      let rectData = body["rect"] as? [String: Any],
                      let x = numeric(rectData["x"]),
                      let y = numeric(rectData["y"]),
                      let w = numeric(rectData["width"]),
                      let h = numeric(rectData["height"]) else {
                    return
                }
                let rect = CGRect(x: x, y: y, width: w, height: h)
                let normalizedOffset = body["normalizedOffset"] as? Int
                let verticalBlock = body["verticalBlock"] as? Bool
                let selection = SelectionData(text: text, sentence: sentence, rect: rect,
                                              normalizedOffset: normalizedOffset, verticalBlock: verticalBlock)
                if let count = parent.onTextSelected(selection) {
                    highlightSelection(count: count, in: message.webView)
                }
            case "hoshiManga":
                // Only event currently routed: "selectedNothing" (empty artwork tap).
                if let body = message.body as? [String: Any], (body["event"] as? String) == "selectedNothing" {
                    parent.onTapOutside()
                }
            case "hoshiMangaAi":
                if let body = message.body as? [String: Any], let text = body["text"] as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { parent.onAskAi(trimmed) }
                }
            case "hoshiMangaClipboard":
                if let body = message.body as? [String: Any], let text = body["text"] as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { parent.onCopy(trimmed) }
                }
            default:
                break
            }
        }

        private func highlightSelection(count: Int, in webView: WKWebView?) {
            webView?.evaluateJavaScript("window.hoshiSelection.highlightSelection(\(count))") { _, _ in }
        }

        // MARK: URL scheme handler (serves page images off disk)

        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            let taskId = ObjectIdentifier(urlSchemeTask)
            activeSchemeTasks.insert(taskId)

            guard let url = urlSchemeTask.request.url,
                  let fileURL = MangaImageScheme.resolveFile(
                      url: url,
                      bookRoot: bookRoot,
                      allowedImagePaths: allowedImagePaths
                  ),
                  let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
                guard activeSchemeTasks.contains(taskId) else { return }
                activeSchemeTasks.remove(taskId)
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                return
            }

            let response = URLResponse(
                url: url,
                mimeType: MangaImageScheme.mimeType(for: fileURL),
                expectedContentLength: data.count,
                textEncodingName: nil
            )
            guard activeSchemeTasks.contains(taskId) else { return }
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
            activeSchemeTasks.remove(taskId)
        }

        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
            activeSchemeTasks.remove(ObjectIdentifier(urlSchemeTask))
        }

        // MARK: Zoom / pan

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            scrollView.subviews.first
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            parent.controller.syncHostViewport()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            parent.controller.syncHostViewport()
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard let webView = gesture.view as? WKWebView else { return }
            let scrollView = webView.scrollView
            MangaReaderWebView.configureZoom(for: scrollView)

            switch gesture.state {
            case .began, .changed:
                let currentScale = scrollView.zoomScale
                let rawScale = currentScale * gesture.scale
                let newScale = min(max(rawScale, scrollView.minimumZoomScale), scrollView.maximumZoomScale)
                if abs(newScale - currentScale) > 0.001 {
                    let anchor = gesture.location(in: webView)
                    zoom(scrollView, to: newScale, anchoredAt: anchor)
                }
                gesture.scale = 1
                parent.controller.syncHostViewport()
            case .ended, .cancelled, .failed:
                parent.controller.syncHostViewport()
            default:
                break
            }
        }

        private func zoom(_ scrollView: UIScrollView, to scale: CGFloat, anchoredAt anchor: CGPoint) {
            let oldScale = max(scrollView.zoomScale, 0.001)
            let contentPoint = CGPoint(
                x: (anchor.x + scrollView.contentOffset.x) / oldScale,
                y: (anchor.y + scrollView.contentOffset.y) / oldScale
            )
            scrollView.setZoomScale(scale, animated: false)
            let proposedOffset = CGPoint(
                x: contentPoint.x * scale - anchor.x,
                y: contentPoint.y * scale - anchor.y
            )
            scrollView.setContentOffset(clamped(proposedOffset, in: scrollView), animated: false)
        }

        private func clamped(_ offset: CGPoint, in scrollView: UIScrollView) -> CGPoint {
            let inset = scrollView.adjustedContentInset
            let minX = -inset.left
            let minY = -inset.top
            let maxX = max(minX, scrollView.contentSize.width - scrollView.bounds.width + inset.right)
            let maxY = max(minY, scrollView.contentSize.height - scrollView.bounds.height + inset.bottom)
            return CGPoint(
                x: min(max(offset.x, minX), maxX),
                y: min(max(offset.y, minY), maxY)
            )
        }

        // MARK: Swipe navigation (gated when zoomed/scrollable)

        @objc func handleSwipeLeft(_ gesture: UISwipeGestureRecognizer) {
            guard !parent.controller.isZoomedOrScrollable else { return }
            parent.onNavigate(MangaPageNavigation.direction(for: .left))
        }

        @objc func handleSwipeRight(_ gesture: UISwipeGestureRecognizer) {
            guard !parent.controller.isZoomedOrScrollable else { return }
            parent.onNavigate(MangaPageNavigation.direction(for: .right))
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        /// Keep the page-turn swipe recognizers from starting while the page is zoomed/panned. They
        /// already no-op in that state, but as long as they *begin* they contest the horizontal axis
        /// of a diagonal pan, which made zoomed panning snap to one axis. With them disabled while
        /// zoomed, the scroll view's pan is unobstructed and follows the finger in any direction. At
        /// fit scale (not zoomed) they begin normally so left/right swipes still turn the page.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer is UISwipeGestureRecognizer {
                return !parent.controller.isZoomedOrScrollable
            }
            return true
        }

        private func numeric(_ value: Any?) -> CGFloat? {
            if let n = value as? NSNumber { return CGFloat(n.doubleValue) }
            if let d = value as? Double { return CGFloat(d) }
            if let i = value as? Int { return CGFloat(i) }
            return nil
        }
    }
}

/// Page-index math for right-to-left manga paging. Mirrors Android `MangaPageNavigation`: a
/// right swipe slides the current page off and pulls the next page in from the left → forward;
/// a left swipe → backward.
enum MangaPageNavigation {
    enum SwipeDirection { case left, right }

    static func direction(for swipe: SwipeDirection) -> NavigationDirection {
        switch swipe {
        case .left: return .backward
        case .right: return .forward
        }
    }

    /// The page index reached by moving `direction` from `currentIndex`, or `nil` at a limit.
    static func targetIndex(currentIndex: Int, pageCount: Int, direction: NavigationDirection) -> Int? {
        if pageCount <= 0 { return nil }
        let next = direction == .forward ? currentIndex + 1 : currentIndex - 1
        return (0..<pageCount).contains(next) ? next : nil
    }
}

/// Resolves `hoshi-img://manga/<percent-encoded relative path>` URLs to on-disk image files
/// under the book's directory, with path-traversal containment + an allow-list. The Swift
/// counterpart of Android's `MangaWebResourceBridge`.
enum MangaImageScheme {
    static let scheme = "hoshi-img"
    static let host = "manga"

    /// Resolves a request URL to the on-disk image file, or `nil` if it is not a manga-image
    /// request, names an image the page does not declare, or escapes the book root.
    static func resolveFile(url: URL, bookRoot: URL?, allowedImagePaths: Set<String>) -> URL? {
        guard let bookRoot,
              url.scheme == scheme,
              url.host == host else {
            return nil
        }
        // URLComponents percent-decodes `path`, round-tripping the encoded segments back to the
        // original on-disk relative path.
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var relative = components.path
        while relative.hasPrefix("/") { relative.removeFirst() }
        guard !relative.isEmpty, allowedImagePaths.contains(relative) else { return nil }

        let canonicalRoot = bookRoot.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = canonicalRoot.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        // Containment: candidate must live strictly inside the book root.
        let rootPath = canonicalRoot.path
        let candidatePath = candidate.path
        guard candidatePath != rootPath,
              candidatePath.hasPrefix(rootPath + "/") else {
            return nil
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidatePath, isDirectory: &isDir), !isDir.boolValue else {
            return nil
        }
        return candidate
    }

    static func mimeType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        case "avif": return "image/avif"
        case "bmp": return "image/bmp"
        default: return "application/octet-stream"
        }
    }
}
