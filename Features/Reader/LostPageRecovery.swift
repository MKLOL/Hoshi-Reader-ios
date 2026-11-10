//
//  LostPageRecovery.swift
//  Hoshi Reader
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit
import WebKit

/// Decides when a page that lost its WebContent process is loaded again.
///
/// iOS discards a page's process while the app waits in the background. Loading the page again
/// there would only give iOS another one to discard, and a page that is not drawn never reports
/// that it is ready. A lost page is therefore loaded again once it can be seen, and a page that
/// keeps losing its process is not loaded without end.
@MainActor final class LostPageRecovery {
    private var reloads: [TimeInterval] = []
    private var waiting = false
    private let limit: Int
    private let window: TimeInterval
    private let clock: () -> TimeInterval

    init(limit: Int = 3, window: TimeInterval = 30, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.limit = limit
        self.window = window
        self.clock = clock
    }

    /// Whether the lost page may be loaded again now. Otherwise the reload waits for
    /// `becameVisible()`: because the page cannot be seen, or because it has just been loaded
    /// `limit` times and may be one that cannot survive its own load.
    func shouldReload(visible: Bool) -> Bool {
        guard visible else { waiting = true; return false }
        let now = clock()
        reloads.removeAll { now - $0 > window }
        guard reloads.count < limit else { waiting = true; return false }
        waiting = false
        reloads.append(now)
        return true
    }

    /// The page can be seen again. True when a reload was waiting for that and is now due.
    func becameVisible() -> Bool {
        waiting && shouldReload(visible: true)
    }

    static func isVisible(_ webView: WKWebView) -> Bool {
        webView.window?.windowScene?.activationState == .foregroundActive
    }

    /// Sends `selector` to `observer` whenever the app or one of its scenes comes forward.
    static func observeBecomingVisible(_ observer: Any, selector: Selector) {
        for name in [UIScene.didActivateNotification, UIApplication.didBecomeActiveNotification] {
            NotificationCenter.default.addObserver(observer, selector: selector, name: name, object: nil)
        }
    }
}
