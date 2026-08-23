//
//  NetworkReachability.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  A single "is there a usable network right now" answer, used to decide whether a manga bubble
//  tap should be served from the offline pre-translation cache instead of a cloud request.
//
//  Deliberately advisory, not authoritative: a satisfied path can still fail (captive portal,
//  dead uplink), so `MangaAiController` also falls back to the cache when a live request fails
//  with a network error. This just avoids a pointless timeout in the common airplane-mode case.
//

import Foundation
import Network

@MainActor
final class NetworkReachability {
    static let shared = NetworkReachability()

    private let monitor = NWPathMonitor()
    private var isSatisfied = true

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.isSatisfied = satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "hoshi.reachability"))
        // Seed synchronously from the current path. The first `pathUpdateHandler` callback lands on
        // a background queue and then hops to the main actor, so without this the FIRST bubble tap
        // after launch would always read "online" — including in airplane mode, which is exactly
        // when the pre-translation cache is supposed to answer.
        isSatisfied = monitor.currentPath.status == .satisfied
    }

    /// False when the device has no usable route (airplane mode, no Wi-Fi/cellular).
    var isOnline: Bool { isSatisfied }

    /// True when `error` looks like "the network was not reachable", as opposed to a server-side
    /// rejection such as a bad API key — only the former should fall back to the cache.
    nonisolated static func isNetworkFailure(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        switch nsError.code {
        case NSURLErrorNotConnectedToInternet,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorCannotConnectToHost,
             NSURLErrorCannotFindHost,
             NSURLErrorTimedOut,
             NSURLErrorDataNotAllowed,
             NSURLErrorInternationalRoamingOff,
             NSURLErrorSecureConnectionFailed:
            return true
        default:
            return false
        }
    }
}
