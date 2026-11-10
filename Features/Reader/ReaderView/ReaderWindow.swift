//
//  ReaderWindow.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

private struct DismissReaderKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

/// A full-screen reading mode hides its presenting view without ending the reader session.
/// Cleanup belongs to the containing window, including when it closes with a mode still open.
@MainActor final class ReaderWindowLifetime {
    var onDismiss: (() -> Void)?
    private(set) var isClosed = false
    func close() {
        guard !isClosed else { return }
        isClosed = true
        let action = onDismiss
        onDismiss = nil
        action?()
    }
}

private struct ReaderWindowLifetimeKey: EnvironmentKey {
    static let defaultValue: ReaderWindowLifetime? = nil
}

extension EnvironmentValues {
    var dismissReader: (() -> Void)? {
        get { self[DismissReaderKey.self] }
        set { self[DismissReaderKey.self] = newValue }
    }
    var readerWindowLifetime: ReaderWindowLifetime? {
        get { self[ReaderWindowLifetimeKey.self] }
        set { self[ReaderWindowLifetimeKey.self] = newValue }
    }
}

@MainActor
final class ReaderWindow {
    private weak var hostController: UIViewController?
    private(set) var lifetime: ReaderWindowLifetime?
    
    func present<Content: View>(@ViewBuilder content: () -> Content, onDismiss: @escaping () -> Void) {
        guard hostController == nil,
              let presenter = topPresenter() else { return }
        
        // The shelf section that owns this window can leave the screen while its reader is open:
        // its last book was finished, moved or removed by a sync. The reader must still be able
        // to close, so its own back action keeps the window alive. Nothing here retains that
        // action in return; the host is held weakly.
        let dismiss: () -> Void = { self.dismiss(onDismiss: onDismiss) }
        let lifetime = ReaderWindowLifetime()
        self.lifetime = lifetime
        let host = UIHostingController(rootView: AnyView(content()
            .environment(\.dismissReader, dismiss)
            .environment(\.readerWindowLifetime, lifetime)))
        host.modalPresentationStyle = .overFullScreen
        host.modalPresentationCapturesStatusBarAppearance = true
        host.view.alpha = 0
        self.hostController = host
        ScreenAwake.readerOpened()
        
        presenter.present(host, animated: false) {
            UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]) {
                host.view.alpha = 1
            }
        }
    }
    
    func dismiss(onDismiss: (() -> Void)? = nil) {
        guard let host = hostController else { return }
        self.hostController = nil
        ScreenAwake.readerClosed()
        lifetime?.close()
        lifetime = nil
        UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState, .curveEaseIn]) {
            host.view.alpha = 0
        } completion: { _ in
            // Dismiss the whole reader stack even if the host is presenting sentence mode.
            (host.presentingViewController ?? host).dismiss(animated: false) {
                WebViewPreloader.shared.warmup()
                onDismiss?()
            }
        }
    }
    
    private func topPresenter() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first,
              let root = window.rootViewController else { return nil }
        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}
