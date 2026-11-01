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

import QuartzCore
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
    var imageLoader: MangaImageLoader?
    private var readyLoadToken: Int?
    private var pendingPredecode: (token: Int, script: String)?

    /// True while the page is zoomed or panned, so the host should gate swipe-to-turn.
    private(set) var isZoomedOrScrollable = false
    /// Top host-pixel area where OCR action buttons should not be placed because native chrome or
    /// system gestures can make visible WebView content unreliable to tap.
    fileprivate var tappableTopInset: CGFloat = 0

    /// Replaces the rendered page. `allowedImagePaths` is the allow-list of book-root-relative
    /// image paths the scheme handler may serve for this page (normally just the page's image).
    @discardableResult
    func load(html: String, allowedImagePaths: Set<String>) -> Int {
        webView?.evaluateJavaScript("window.hoshiMangaImageCache && window.hoshiMangaImageCache.cancel()") { _, _ in }
        readyLoadToken = nil
        pendingPredecode = nil
        self.pendingHtml = html
        self.allowedImagePaths = allowedImagePaths
        loadToken += 1
        return loadToken
    }

    func setPredecodeScript(_ script: String, for token: Int) {
        guard token == loadToken else { return }
        pendingPredecode = (token, script)
        startPredecodeIfReady()
    }

    fileprivate func pageReady(_ token: Int) {
        guard token == loadToken else { return }
        readyLoadToken = token
        startPredecodeIfReady()
    }

    private func startPredecodeIfReady() {
        guard let pendingPredecode, pendingPredecode.token == readyLoadToken else { return }
        self.pendingPredecode = nil
        webView?.evaluateJavaScript(pendingPredecode.script) { _, _ in }
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
        let topInset = tappableTopInset.isFinite ? max(0, tappableTopInset) : 0
        let script = """
        window.hoshiManga && window.hoshiManga.setHostViewport(\(Double(scale)), \(Double(offsetX)), \(Double(offsetY)), \(Double(topInset)))
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

    func uiTestActionLayoutProbeLabel() async -> String {
        guard let webView else { return "actions=nil" }
        let script = """
        (function() {
          if (!window.hoshiManga || !window.hoshiManga.actionLayoutProbe) { return "actions=nil"; }
          return JSON.stringify(window.hoshiManga.actionLayoutProbe());
        })();
        """
        let result = try? await webView.evaluateJavaScript(script)
        return result as? String ?? "actions=nil"
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
    var onTextSelected: (SelectionData) async -> Int?
    /// Empty artwork tapped — dismiss any lookup popup.
    var onTapOutside: () -> Void
    /// A bubble's sparkles button was tapped — bubble text for the AI controller.
    /// Bubble OCR text plus its mokuro address (`p{page}b{block}`), or nil when the page render
    /// predates block ids. The address resolves the bubble's pre-computed offline translation.
    var onAskAi: (String, String?) -> Void
    /// A bubble's copy button was tapped — bubble text to copy.
    var onCopy: (String) -> Void
    /// Called once the page HTML finished loading, with the controller load token for that navigation.
    var onPageReady: (Int) -> Void
    /// Host-pixel top inset that is visible but not reliably tappable inside the full-bleed WebView.
    var tappableTopInset: CGFloat = 0
    /// Gates hardware-keyboard ← / → and trackpad two-finger page turns. Off during the screenshot
    /// crop overlay and the go-to-page dialog so those aren't disturbed by a stray key/drag.
    var onBubbleRevealed: (String, String?) -> Void = { _, _ in }
    var pageTurnEnabled: Bool = true

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

        let webView = MangaKeyCommandWebView(frame: .zero, configuration: config)
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

        // UIScrollView already owns a coordinated pinch + pan pair. Observe its pinch for
        // telemetry and state syncing, but never write zoomScale/contentOffset from this callback;
        // doing so fights UIScrollView's pan recognizer and produces visible oscillation.
        if let nativePinch = webView.scrollView.pinchGestureRecognizer {
            nativePinch.addTarget(
                coordinator,
                action: #selector(Coordinator.observeNativePinch(_:))
            )
            coordinator.nativePinchRecognizer = nativePinch
        }

        // Keep UIScrollView's own pan recognizer paired with its own pinch recognizer. This target
        // only observes native pan state for telemetry; UIKit remains the sole writer of the
        // viewport.
        let nativePan = webView.scrollView.panGestureRecognizer
        nativePan.addTarget(
            coordinator,
            action: #selector(Coordinator.observeNativePan(_:))
        )
        coordinator.nativePanRecognizer = nativePan

        // UIScrollView's built-in indirect pan reports zero translation when the fitted page cannot
        // scroll, so it cannot drive a trackpad page turn. A read-only recognizer supplies that
        // translation only at fit scale. It is rejected once the viewport is zoomed/pannable, where
        // UIScrollView's native pan must remain the sole owner.
        let trackpadPageTurn = UIPanGestureRecognizer(
            target: coordinator,
            action: #selector(Coordinator.handleTrackpadPageTurn(_:))
        )
        trackpadPageTurn.allowedScrollTypesMask = .continuous
        trackpadPageTurn.allowedTouchTypes = []
        trackpadPageTurn.cancelsTouchesInView = false
        trackpadPageTurn.delegate = coordinator
        webView.scrollView.addGestureRecognizer(trackpadPageTurn)
        coordinator.trackpadPageTurnRecognizer = trackpadPageTurn

        // Hardware keyboard (iPad), RTL manga: ← next page, → previous page (the next page sits to
        // the left in right-to-left reading). Routed through the same `onNavigate` the swipes use,
        // and gated identically via `pageTurnEnabled`.
        webView.onArrowLeft = { [weak coordinator] in
            guard let coordinator, coordinator.parent.pageTurnEnabled else { return }
            coordinator.parent.onNavigate(.forward)
        }
        webView.onArrowRight = { [weak coordinator] in
            guard let coordinator, coordinator.parent.pageTurnEnabled else { return }
            coordinator.parent.onNavigate(.backward)
        }

        controller.attach(webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.bookRoot = controller.bookRootForScheme
        let topInset = tappableTopInset.isFinite ? max(0, tappableTopInset) : 0
        if controller.tappableTopInset != topInset {
            controller.tappableTopInset = topInset
            controller.syncHostViewport()
        }
        if context.coordinator.lastLoadToken != controller.loadToken, let html = controller.pendingHtml {
            let loadToken = controller.loadToken
            context.coordinator.lastLoadToken = loadToken
            context.coordinator.allowedImagePaths = controller.allowedImagePaths
            if let navigation = webView.loadHTMLString(html, baseURL: URL(string: MangaPageHtml.baseURLString)) {
                context.coordinator.trackNavigation(navigation, loadToken: loadToken)
            }
        }
    }

    private static func configureZoom(for scrollView: UIScrollView) {
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.bouncesZoom = true
        scrollView.pinchGestureRecognizer?.isEnabled = true
        // UIScrollView's native pan must receive continuous trackpad scroll events so UIKit can
        // coordinate them with native transform events from its pinch recognizer.
        scrollView.panGestureRecognizer.allowedScrollTypesMask = .all
        // Allow free diagonal panning when zoomed in. With directional lock on, a drag snaps to one
        // axis ("only left/right/up/down"); we want the page to follow the finger in any direction.
        scrollView.isDirectionalLockEnabled = false
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.selectionTask?.cancel()
        coordinator.cancelImageReads()
        let controllerJS = webView.configuration.userContentController
        controllerJS.removeScriptMessageHandler(forName: "textSelected")
        controllerJS.removeScriptMessageHandler(forName: "hoshiManga")
        controllerJS.removeScriptMessageHandler(forName: "hoshiMangaAi")
        controllerJS.removeScriptMessageHandler(forName: "hoshiMangaClipboard")
        if let nativePinch = coordinator.nativePinchRecognizer {
            nativePinch.removeTarget(
                coordinator,
                action: #selector(Coordinator.observeNativePinch(_:))
            )
        }
        if let nativePan = coordinator.nativePanRecognizer {
            nativePan.removeTarget(
                coordinator,
                action: #selector(Coordinator.observeNativePan(_:))
            )
        }
        if let trackpadPageTurn = coordinator.trackpadPageTurnRecognizer {
            webView.scrollView.removeGestureRecognizer(trackpadPageTurn)
        }
        webView.scrollView.delegate = nil
        webView.navigationDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler,
                             WKURLSchemeHandler, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var selectionTask: Task<Void, Never>?
        var parent: MangaReaderWebView
        var lastLoadToken = 0
        var allowedImagePaths: Set<String> = []
        private var scrollableBubbleRegions: [CGRect] = []
        /// Native trackpad debounce — held here so it survives the per-page HTML reload a turn
        /// triggers (a JS-side debounce gets wiped by the reload → multi-page jumps).
        var wheelDebouncer = MangaWheelDebouncer()
        /// Snapshotted from the controller in updateUIView so the scheme handler never reaches
        /// into MainActor-isolated state from its (main-thread) callback.
        var bookRoot: URL?
        /// In-flight scheme tasks by identity; a task that WebKit has `stop`ped is removed, so we
        /// never call back into a cancelled task (which throws).
        private var activeSchemeTasks = Set<ObjectIdentifier>()
        private var schemeReads: [ObjectIdentifier: Task<Void, Never>] = [:]
        /// WKNavigation -> controller load token. `didFinish` can arrive out of order during fast
        /// page turns, so the host only trusts completions for the navigation it asked to load.
        private var navigationLoadTokens: [ObjectIdentifier: Int] = [:]
        weak var nativePinchRecognizer: UIPinchGestureRecognizer?
        weak var nativePanRecognizer: UIPanGestureRecognizer?
        weak var trackpadPageTurnRecognizer: UIPanGestureRecognizer?
        private var previousPinchLocation: CGPoint?
        private var pinchUsesIndirectInput = false
        private var indirectPinchTransform: MangaIndirectPinchTransform?
        private var trackpadPanSession: TrackpadPanSession?
#if DEBUG
        private var gestureTelemetrySequence = 0
#endif

        private struct TrackpadPanSession {
            var totalTranslation: CGPoint = .zero
            var appliedTranslation: CGPoint = .zero
            /// Once any part of this sequence participates in zoom/pan, it can never become a page
            /// turn—even if the pinch returns to 1x before the fingers leave the trackpad.
            var usedForViewport = false
        }

        init(_ parent: MangaReaderWebView) {
            self.parent = parent
        }

        // MARK: Navigation

        func trackNavigation(_ navigation: WKNavigation, loadToken: Int) {
            scrollableBubbleRegions = []
            navigationLoadTokens[ObjectIdentifier(navigation)] = loadToken
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let navigation else { return }
            guard let finishedLoadToken = navigationLoadTokens.removeValue(forKey: ObjectIdentifier(navigation)) else {
                return
            }
            guard finishedLoadToken == parent.controller.loadToken else { return }
            // WebKit can restore the previous document's viewport during navigation. Reset only
            // after the current document loads, before exposing it for page-turn gestures.
            MangaReaderWebView.configureZoom(for: webView.scrollView)
            webView.scrollView.setZoomScale(webView.scrollView.minimumZoomScale, animated: false)
            webView.scrollView.setContentOffset(.zero, animated: false)
            previousPinchLocation = nil
            indirectPinchTransform = nil
            trackpadPanSession = nil
            parent.controller.syncHostViewport()
            parent.onPageReady(finishedLoadToken)
            parent.controller.pageReady(finishedLoadToken)
            // Re-assert first responder so hardware-keyboard arrows keep turning pages after a
            // load (loadHTMLString can drop it). No-op cost when already first responder; safe here
            // because a page turn has already cleared any text selection / popups.
            if webView.window != nil { webView.becomeFirstResponder() }
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
                selectionTask?.cancel()
                selectionTask = Task {
                    if let count = await parent.onTextSelected(selection), !Task.isCancelled { highlightSelection(count: count, in: message.webView) }
                }
            case "hoshiManga":
                guard let body = message.body as? [String: Any] else { return }
                switch body["event"] as? String {
                case "scrollableBubbleRegions":
                    let values = body["regions"] as? [[String: Any]] ?? []
                    scrollableBubbleRegions = values.prefix(256).compactMap { value in
                        guard let x = numeric(value["x"]), let y = numeric(value["y"]),
                              let width = numeric(value["width"]), let height = numeric(value["height"]),
                              [x, y, width, height].allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }),
                              width > 0, height > 0 else { return nil }
                        return CGRect(x: x, y: y, width: width, height: height)
                    }
                case "bubbleRevealed":
                    parent.onBubbleRevealed(body["text"] as? String ?? "", body["blockId"] as? String)
                case "selectedNothing":
                    selectionTask?.cancel()
                    parent.onTapOutside() // empty artwork tap
                default:
                    break
                }
            case "hoshiMangaAi":
                if let body = message.body as? [String: Any], let text = body["text"] as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let blockId = (body["blockId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    if !trimmed.isEmpty { parent.onAskAi(trimmed, blockId) }
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

        func cancelImageReads() {
            for read in schemeReads.values { read.cancel() }
            schemeReads.removeAll()
            activeSchemeTasks.removeAll()
        }

        // MARK: URL scheme handler (serves page images off disk)

        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            let taskId = ObjectIdentifier(urlSchemeTask)
            activeSchemeTasks.insert(taskId)

            guard let url = urlSchemeTask.request.url else {
                activeSchemeTasks.remove(taskId)
                urlSchemeTask.didFailWithError(URLError(.badURL))
                return
            }
            let loader = parent.controller.imageLoader
            let root = bookRoot, allowed = allowedImagePaths
            schemeReads[taskId] = Task { [weak self] in
                do {
                    let data: Data
                    if let loader { data = try await loader.image(for: url, allowedPaths: allowed) }
                    else {
                        data = try await Task.detached(priority: .userInitiated) {
                            guard let file = MangaImageScheme.resolveFile(url: url, bookRoot: root, allowedImagePaths: allowed) else {
                                throw URLError(.fileDoesNotExist)
                            }
                            return try Data(contentsOf: file, options: .mappedIfSafe)
                        }.value
                    }
                    guard let self, !Task.isCancelled, self.activeSchemeTasks.contains(taskId) else { return }
                    let response = URLResponse(url: url, mimeType: MangaImageScheme.mimeType(for: url),
                                               expectedContentLength: data.count, textEncodingName: nil)
                    urlSchemeTask.didReceive(response)
                    urlSchemeTask.didReceive(data)
                    urlSchemeTask.didFinish()
                    self.activeSchemeTasks.remove(taskId)
                    self.schemeReads.removeValue(forKey: taskId)
                } catch {
                    guard let self, !Task.isCancelled, self.activeSchemeTasks.contains(taskId) else { return }
                    self.activeSchemeTasks.remove(taskId)
                    self.schemeReads.removeValue(forKey: taskId)
                    urlSchemeTask.didFailWithError(error)
                }
            }
        }

        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
            let taskId = ObjectIdentifier(urlSchemeTask)
            activeSchemeTasks.remove(taskId)
            schemeReads.removeValue(forKey: taskId)?.cancel()
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

        @objc func observeNativePinch(_ gesture: UIPinchGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            let rawLocation = gesture.location(in: scrollView)
            let viewportLocation = CGPoint(
                x: rawLocation.x - scrollView.bounds.minX,
                y: rawLocation.y - scrollView.bounds.minY
            )
            gestureTelemetry(
                "NATIVE_PINCH touches=\(gesture.numberOfTouches) " +
                "scale=\(telemetryNumber(gesture.scale)) " +
                "velocity=\(telemetryNumber(gesture.velocity)) " +
                "raw=\(telemetryPoint(rawLocation)) " +
                "viewport=\(telemetryPoint(viewportLocation))",
                gesture: gesture,
                scrollView: scrollView
            )
            if gesture.state == .began || gesture.state == .changed {
                wheelDebouncer.suppressCurrentGesture(now: CACurrentMediaTime())
                trackpadPanSession?.usedForViewport = true
            }
            parent.controller.syncHostViewport()
        }

        @objc func observeNativePan(_ gesture: UIPanGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            let translation = gesture.translation(in: scrollView)
            gestureTelemetry(
                "NATIVE_PAN touches=\(gesture.numberOfTouches) " +
                "translation=\(telemetryPoint(translation)) " +
                "velocity=\(telemetryPoint(gesture.velocity(in: scrollView)))",
                gesture: gesture,
                scrollView: scrollView
            )
            parent.controller.syncHostViewport()
        }

        @objc func handleTrackpadPageTurn(_ gesture: UIPanGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            let translation = gesture.translation(in: scrollView)
            gestureTelemetry(
                "TRACKPAD_PAGE_TURN translation=\(telemetryPoint(translation)) " +
                "velocity=\(telemetryPoint(gesture.velocity(in: scrollView)))",
                gesture: gesture,
                scrollView: scrollView
            )
            guard gesture.state == .ended else { return }
            commitTrackpadPageTurn(translation: translation)
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            MangaReaderWebView.configureZoom(for: scrollView)
            let rawLocation = gesture.location(in: scrollView)
            // A UIScrollView's bounds origin follows contentOffset. Normalize the recognizer's
            // indirect-input location back into viewport coordinates; otherwise our own scrolling
            // would look like extra trackpad movement and feed back into the gesture.
            let viewportLocation = CGPoint(
                x: rawLocation.x - scrollView.bounds.minX,
                y: rawLocation.y - scrollView.bounds.minY
            )
            let eventUsesIndirectInput = gesture.state == .began
                ? gesture.numberOfTouches == 0
                : pinchUsesIndirectInput
            // Preserve the already-verified direct-touch path; the viewport normalization is for
            // the zero-touch trackpad event stream identified by device telemetry.
            let currentLocation = eventUsesIndirectInput ? viewportLocation : rawLocation
            gestureTelemetry(
                "PINCH_IN touches=\(gesture.numberOfTouches) scale=\(telemetryNumber(gesture.scale)) " +
                "velocity=\(telemetryNumber(gesture.velocity)) raw=\(telemetryPoint(rawLocation)) " +
                "viewport=\(telemetryPoint(viewportLocation))",
                gesture: gesture,
                scrollView: scrollView
            )

            switch gesture.state {
            case .began:
                pinchUsesIndirectInput = gesture.numberOfTouches == 0
                if pinchUsesIndirectInput {
                    let pendingPan = claimPendingTrackpadTranslation()
                    indirectPinchTransform = MangaIndirectPinchTransform(
                        currentOffset: scrollView.contentOffset,
                        scale: max(scrollView.zoomScale, 0.001),
                        anchor: currentLocation,
                        initialPanTranslation: pendingPan
                    )
                    indirectPinchTransform?.setScaleFactor(gesture.scale)
                    wheelDebouncer.suppressCurrentGesture(now: CACurrentMediaTime())
                    applyIndirectPinch(in: scrollView)
                } else {
                    previousPinchLocation = currentLocation
                    applyDirectPinchDelta(gesture, in: scrollView, currentLocation: currentLocation)
                }
                parent.controller.syncHostViewport()
            case .changed:
                if pinchUsesIndirectInput {
                    trackpadPanSession?.usedForViewport = true
                    indirectPinchTransform?.setScaleFactor(gesture.scale)
                    indirectPinchTransform?.setCurrentAnchor(currentLocation)
                    wheelDebouncer.suppressCurrentGesture(now: CACurrentMediaTime())
                    applyIndirectPinch(in: scrollView)
                } else {
                    if previousPinchLocation == nil {
                        previousPinchLocation = currentLocation
                    }
                    applyDirectPinchDelta(gesture, in: scrollView, currentLocation: currentLocation)
                }
                parent.controller.syncHostViewport()
            case .ended:
                if pinchUsesIndirectInput {
                    trackpadPanSession?.usedForViewport = true
                    indirectPinchTransform?.setScaleFactor(gesture.scale)
                    indirectPinchTransform?.setCurrentAnchor(currentLocation)
                    wheelDebouncer.suppressCurrentGesture(now: CACurrentMediaTime())
                    applyIndirectPinch(in: scrollView)
                } else {
                    applyDirectPinchDelta(gesture, in: scrollView, currentLocation: currentLocation)
                }
                previousPinchLocation = nil
                indirectPinchTransform = nil
                pinchUsesIndirectInput = false
                parent.controller.syncHostViewport()
            case .cancelled, .failed:
                if pinchUsesIndirectInput {
                    trackpadPanSession?.usedForViewport = true
                    wheelDebouncer.suppressCurrentGesture(now: CACurrentMediaTime())
                }
                previousPinchLocation = nil
                indirectPinchTransform = nil
                pinchUsesIndirectInput = false
                parent.controller.syncHostViewport()
            default:
                break
            }
            gestureTelemetry(
                "PINCH_OUT indirect=\(pinchUsesIndirectInput) transform=\(indirectPinchTransform != nil)",
                gesture: gesture,
                scrollView: scrollView
            )
        }

        private func applyDirectPinchDelta(
            _ gesture: UIPinchGestureRecognizer,
            in scrollView: UIScrollView,
            currentLocation: CGPoint
        ) {
            let previousLocation = previousPinchLocation ?? currentLocation
            let oldScale = max(scrollView.zoomScale, 0.001)
            let rawScale = oldScale * gesture.scale
            let newScale = min(max(rawScale, scrollView.minimumZoomScale), scrollView.maximumZoomScale)
            let proposedOffset = MangaViewportGestureMath.zoomOffset(
                currentOffset: scrollView.contentOffset,
                oldScale: oldScale,
                newScale: newScale,
                previousAnchor: previousLocation,
                currentAnchor: currentLocation
            )
            scrollView.setZoomScale(newScale, animated: false)
            scrollView.setContentOffset(clamped(proposedOffset, in: scrollView), animated: false)
            previousPinchLocation = currentLocation
            gesture.scale = 1
        }

        private func applyIndirectPinch(in scrollView: UIScrollView) {
            guard let transform = indirectPinchTransform else { return }
            let newScale = min(
                max(transform.unclampedScale, scrollView.minimumZoomScale),
                scrollView.maximumZoomScale
            )
            let proposedOffset = transform.offset(atScale: newScale)
            scrollView.setZoomScale(newScale, animated: false)
            scrollView.setContentOffset(clamped(proposedOffset, in: scrollView), animated: false)
        }

        private func claimPendingTrackpadTranslation() -> CGPoint {
            guard var session = trackpadPanSession else { return .zero }
            let pending = CGPoint(
                x: session.totalTranslation.x - session.appliedTranslation.x,
                y: session.totalTranslation.y - session.appliedTranslation.y
            )
            session.appliedTranslation = session.totalTranslation
            session.usedForViewport = true
            trackpadPanSession = session
            return pending
        }

        @objc func handleTrackpadPan(_ gesture: UIPanGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            MangaReaderWebView.configureZoom(for: scrollView)
            gestureTelemetry(
                "TRACKPAD_PAN_IN translation=\(telemetryPoint(gesture.translation(in: scrollView))) " +
                "velocity=\(telemetryPoint(gesture.velocity(in: scrollView)))",
                gesture: gesture,
                scrollView: scrollView
            )

            switch gesture.state {
            case .began:
                trackpadPanSession = TrackpadPanSession(
                    usedForViewport: pinchUsesIndirectInput || viewportNeedsPan(scrollView)
                )
                consumeTrackpadTranslation(from: gesture, in: scrollView)
            case .changed:
                if trackpadPanSession == nil {
                    trackpadPanSession = TrackpadPanSession(
                        usedForViewport: pinchUsesIndirectInput || viewportNeedsPan(scrollView)
                    )
                }
                consumeTrackpadTranslation(from: gesture, in: scrollView)
            case .ended:
                consumeTrackpadTranslation(from: gesture, in: scrollView)
                let completed = trackpadPanSession
                trackpadPanSession = nil
                guard let completed, !completed.usedForViewport else { return }
                commitTrackpadPageTurn(translation: completed.totalTranslation)
            case .cancelled, .failed:
                trackpadPanSession = nil
            default:
                break
            }
            let session = trackpadPanSession
            gestureTelemetry(
                "TRACKPAD_PAN_OUT total=\(telemetryPoint(session?.totalTranslation ?? .zero)) " +
                "applied=\(telemetryPoint(session?.appliedTranslation ?? .zero)) " +
                "viewport=\(session?.usedForViewport ?? false) transform=\(indirectPinchTransform != nil)",
                gesture: gesture,
                scrollView: scrollView
            )
        }

        private func consumeTrackpadTranslation(
            from gesture: UIPanGestureRecognizer,
            in scrollView: UIScrollView
        ) {
            guard var session = trackpadPanSession else { return }
            let translation = gesture.translation(in: scrollView)
            session.totalTranslation = translation
            let pending = CGPoint(
                x: session.totalTranslation.x - session.appliedTranslation.x,
                y: session.totalTranslation.y - session.appliedTranslation.y
            )

            if indirectPinchTransform != nil || viewportNeedsPan(scrollView) {
                session.usedForViewport = true
            }
            if session.usedForViewport {
                wheelDebouncer.suppressCurrentGesture(now: CACurrentMediaTime())
                session.appliedTranslation = session.totalTranslation
                if var transform = indirectPinchTransform {
                    transform.addPanTranslation(pending)
                    indirectPinchTransform = transform
                    trackpadPanSession = session
                    applyIndirectPinch(in: scrollView)
                } else {
                    let proposedOffset = MangaViewportGestureMath.panOffset(
                        currentOffset: scrollView.contentOffset,
                        translationDelta: pending
                    )
                    scrollView.setContentOffset(clamped(proposedOffset, in: scrollView), animated: false)
                }
                parent.controller.syncHostViewport()
            }
            trackpadPanSession = session
        }

        private func commitTrackpadPageTurn(translation: CGPoint) {
            guard parent.pageTurnEnabled,
                  abs(translation.x) > abs(translation.y) else { return }
            // UIPan reports finger direction; the previous WheelEvent path reported the opposite
            // scroll direction. Negating preserves RTL behavior: fingers right means forward.
            if let direction = wheelDebouncer.feed(
                deltaX: -translation.x,
                now: CACurrentMediaTime()
            ) {
                parent.onNavigate(direction)
            }
        }

        private func viewportNeedsPan(_ scrollView: UIScrollView) -> Bool {
            if scrollView.zoomScale > scrollView.minimumZoomScale + 0.001 {
                return true
            }
            let inset = scrollView.adjustedContentInset
            return abs(scrollView.contentOffset.x + inset.left) > 1 ||
                abs(scrollView.contentOffset.y + inset.top) > 1 ||
                scrollView.contentSize.width > scrollView.bounds.width + 1 ||
                scrollView.contentSize.height > scrollView.bounds.height + 1
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
            guard parent.pageTurnEnabled, !parent.controller.isZoomedOrScrollable else { return }
            parent.onNavigate(MangaPageNavigation.direction(for: .left))
        }

        @objc func handleSwipeRight(_ gesture: UISwipeGestureRecognizer) {
            guard parent.pageTurnEnabled, !parent.controller.isZoomedOrScrollable else { return }
            parent.onNavigate(MangaPageNavigation.direction(for: .right))
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            gestureTelemetry(
                "SIMULTANEOUS yes first=\(telemetryRecognizerName(gestureRecognizer)):" +
                "\(gestureRecognizer.state.rawValue) second=\(telemetryRecognizerName(otherGestureRecognizer)):" +
                "\(otherGestureRecognizer.state.rawValue)"
            )
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive event: UIEvent
        ) -> Bool {
            gestureTelemetry(
                "EVENT recognizer=\(telemetryRecognizerName(gestureRecognizer)) " +
                "type=\(event.type.rawValue) subtype=\(event.subtype.rawValue)"
            )
            return true
        }

        /// Keep the page-turn swipe recognizers from starting while the page is zoomed/panned. They
        /// already no-op in that state, but as long as they *begin* they contest the horizontal axis
        /// of a diagonal pan, which made zoomed panning snap to one axis. With them disabled while
        /// zoomed, the scroll view's pan is unobstructed and follows the finger in any direction. At
        /// fit scale (not zoomed) they begin normally so left/right swipes still turn the page.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard gestureRecognizer is UISwipeGestureRecognizer,
                  let webView = parent.controller.webView else { return true }
            return !scrollableBubbleRegions.contains { $0.contains(touch.location(in: webView)) }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer is UISwipeGestureRecognizer {
                return !parent.controller.isZoomedOrScrollable
            }
            if gestureRecognizer === trackpadPageTurnRecognizer {
                if let webView = parent.controller.webView,
                   scrollableBubbleRegions.contains(where: { $0.contains(gestureRecognizer.location(in: webView)) }) { return false }
                guard let scrollView = gestureRecognizer.view as? UIScrollView else { return false }
                let pinchState = nativePinchRecognizer?.state
                let pinchIsActive = pinchState == .began || pinchState == .changed
                return !pinchIsActive && !viewportNeedsPan(scrollView)
            }
            return true
        }

        private func numeric(_ value: Any?) -> CGFloat? {
            if let n = value as? NSNumber { return CGFloat(n.doubleValue) }
            if let d = value as? Double { return CGFloat(d) }
            if let i = value as? Int { return CGFloat(i) }
            return nil
        }

        private func telemetryRecognizerName(_ gesture: UIGestureRecognizer) -> String {
            if gesture === nativePinchRecognizer { return "nativePinch" }
            if gesture === nativePanRecognizer { return "nativePan" }
            if gesture === trackpadPageTurnRecognizer { return "trackpadPageTurn" }
            return String(describing: type(of: gesture))
        }

        private func telemetryNumber(_ value: CGFloat) -> String {
            String(format: "%.4f", Double(value))
        }

        private func telemetryPoint(_ point: CGPoint) -> String {
            "(\(telemetryNumber(point.x)),\(telemetryNumber(point.y)))"
        }

        private func gestureTelemetry(
            _ event: String,
            gesture: UIGestureRecognizer? = nil,
            scrollView: UIScrollView? = nil
        ) {
#if DEBUG
            gestureTelemetrySequence += 1
            var fields = [
                "HOSHI_GESTURE",
                "seq=\(gestureTelemetrySequence)",
                "t=\(String(format: "%.6f", CACurrentMediaTime()))",
                event
            ]
            if let gesture {
                fields.append("state=\(gesture.state.rawValue)")
            }
            if let scrollView {
                let contentSize = CGPoint(
                    x: scrollView.contentSize.width,
                    y: scrollView.contentSize.height
                )
                let boundsSize = CGPoint(
                    x: scrollView.bounds.width,
                    y: scrollView.bounds.height
                )
                fields.append("zoom=\(telemetryNumber(scrollView.zoomScale))")
                fields.append("offset=\(telemetryPoint(scrollView.contentOffset))")
                fields.append("content=\(telemetryPoint(contentSize))")
                fields.append("bounds=\(telemetryPoint(boundsSize))")
            }
            let line = fields.joined(separator: " ") + "\n"
            if let data = line.data(using: .utf8) {
                FileHandle.standardError.write(data)
            }
#endif
        }
    }
}

/// A `WKWebView` that turns the iPad hardware keyboard's ← / → into page turns. The closures fire
/// on the main thread whenever the WebView (or its web content) is the first responder;
/// `MangaReaderWebView` re-asserts first responder after each page load so arrows keep working
/// across turns. `wantsPriorityOverSystemBehavior` ensures the arrows beat WebKit's own caret /
/// scroll handling.
final class MangaKeyCommandWebView: WKWebView {
    var onArrowLeft: (() -> Void)?
    var onArrowRight: (() -> Void)?

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Grab first responder as soon as the view is on screen so the very first arrow press
        // (before the page's first `didFinish`) still routes here. Re-asserted after each load too.
        if window != nil { becomeFirstResponder() }
    }

    override var keyCommands: [UIKeyCommand]? {
        let left = UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [],
                                action: #selector(handleLeftArrowKey(_:)))
        let right = UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [],
                                 action: #selector(handleRightArrowKey(_:)))
        left.wantsPriorityOverSystemBehavior = true
        right.wantsPriorityOverSystemBehavior = true
        return [left, right]
    }

    @objc private func handleLeftArrowKey(_ sender: UIKeyCommand) { onArrowLeft?() }
    @objc private func handleRightArrowKey(_ sender: UIKeyCommand) { onArrowRight?() }
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
