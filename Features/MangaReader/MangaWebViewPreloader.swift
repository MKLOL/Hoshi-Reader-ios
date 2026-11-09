import UIKit
import WebKit

/// WebKit retains a configuration's scheme handler for the WebView's lifetime. A weak
/// forwarding target lets one warmed view move between readers without retaining a book's
/// coordinator, root URL, image loader or script handlers in its configuration.
@MainActor
final class MangaImageSchemeProxy: NSObject, WKURLSchemeHandler {
    weak var receiver: (any WKURLSchemeHandler)?

    private final class Route {
        weak var receiver: (any WKURLSchemeHandler)?
        init(_ receiver: any WKURLSchemeHandler) { self.receiver = receiver }
    }

    private var routes: [ObjectIdentifier: Route] = [:]

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let receiver else {
            urlSchemeTask.didFailWithError(URLError(.cancelled))
            return
        }
        routes[ObjectIdentifier(urlSchemeTask)] = Route(receiver)
        receiver.webView(webView, start: urlSchemeTask)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        // A cancelled request belongs to the coordinator that started it. Never send a late
        // cancellation to the next reader after the view has been returned to the pool.
        let route = routes.removeValue(forKey: ObjectIdentifier(urlSchemeTask))
        route?.receiver?.webView(webView, stop: urlSchemeTask)
    }

    /// The coordinator calls this after either terminal scheme-task callback. Completed
    /// requests do not necessarily receive `stop`, so they cannot stay in this routing table.
    func complete(_ task: any WKURLSchemeTask) {
        routes.removeValue(forKey: ObjectIdentifier(task))
    }

    fileprivate func detach() {
        receiver = nil
        routes.removeAll(keepingCapacity: false)
    }
}

/// Retains one idle, already-navigated manga WebView. Warming an unrelated dummy WebView
/// does not remove the first custom-scheme navigation's content-process startup cost.
/// The active reader owns its checkout; the pool never creates a second idle view while a
/// checkout is active. A returned view has no reader delegates, scripts or active document.
@MainActor
final class MangaWebViewPreloader {
    static let shared = MangaWebViewPreloader()

    struct Prepared {
        let webView: MangaKeyCommandWebView
        let schemeHandler: MangaImageSchemeProxy
    }

    private var idle: Prepared?
    private var checkedOut: Set<ObjectIdentifier> = []

    func warmup() {
        guard idle == nil, checkedOut.isEmpty else { return }
        let prepared = makePrepared()
        resetDocument(prepared)
        idle = prepared
    }

    /// EPUB can release the idle manga view after benefiting from WebKit process warmup.
    /// An active reader's checkout is owned by that reader and remains untouched.
    func discardIdle() {
        idle?.schemeHandler.detach()
        idle?.webView.stopLoading()
        idle = nil
    }

    func take() -> Prepared {
        let prepared: Prepared
        if let warmed = idle {
            idle = nil
            prepared = warmed
        } else {
            prepared = makePrepared()
        }
        checkedOut.insert(ObjectIdentifier(prepared.webView))
        // The blank navigation may still be in flight. Its delegate/token is not a reader
        // page, and the reader's first load will supersede it without displaying old content.
        prepared.webView.stopLoading()
        prepared.webView.isHidden = true
        return prepared
    }

    /// Call after cancelling image/selection work, removing reader gestures and script
    /// message handlers, and detaching the old controller's weak WebView reference.
    func recycle(_ prepared: Prepared) {
        guard checkedOut.remove(ObjectIdentifier(prepared.webView)) != nil else { return }
        prepared.schemeHandler.detach()
        let webView = prepared.webView
        webView.isHidden = true
        webView.stopLoading()
        webView.resignFirstResponder()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.scrollView.delegate = nil
        webView.onArrowLeft = nil
        webView.onArrowRight = nil
        webView.configuration.userContentController.removeAllUserScripts()
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        // Multiple scene readers can coexist; only the final return retains one idle view.
        guard idle == nil, checkedOut.isEmpty else { return }
        resetDocument(prepared)
        idle = prepared
    }

    private func makePrepared() -> Prepared {
        let schemeHandler = MangaImageSchemeProxy()
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: MangaImageScheme.scheme)
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        let webView = MangaKeyCommandWebView(
            frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration
        )
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.isHidden = true
        return Prepared(webView: webView, schemeHandler: schemeHandler)
    }

    private func resetDocument(_ prepared: Prepared) {
        // Resource-free local HTML launches this exact view's content process and replaces
        // any prior book DOM. Keep it hidden until the reader's current navigation finishes.
        let blank = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1"></head>
        <body style="margin:0;background:#000"></body></html>
        """
        prepared.webView.loadHTMLString(blank, baseURL: URL(string: MangaPageHtml.baseURLString))
    }
}
