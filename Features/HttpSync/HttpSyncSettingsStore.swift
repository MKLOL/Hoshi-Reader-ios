//
//  HttpSyncSettingsStore.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Settings + runtime cursor for the v2 KV HTTP sync, ported from the Android
//  HttpSyncSettings/HttpSyncSettingsRepository. Mirrors the Android persistence split:
//   - baseURL, enabled, syncMode, lastSyncedAt cursor live in UserDefaults.
//   - the bearer token lives in the Keychain (SecretKeys.httpSyncToken) — it must never
//     end up in a plist backup the way an API key shouldn't.
//
//  enabled gates the reader-side auto-push hooks (onPageTurnPersisted / onChatEntryPersisted).
//  When off, page turns and chat entries still save locally and the manual "Sync now" button
//  still works; only the silent fire-and-forget pushes are suppressed.
//

import Foundation

/// How "Sync now" / auto hooks behave. Kept as a stored enum so the UI can offer a toggle and the
/// orchestrator can extend behavior later without touching the wire format.
enum HttpSyncMode: String, CaseIterable, Codable, Sendable {
    /// Reconcile only when the user taps "Sync now" (auto push hooks still fire if enabled).
    case manual
    /// Reserved for a future on-resume / periodic auto-reconcile path.
    case automatic
}

@Observable
final class HttpSyncSettingsStore {
    @MainActor static let shared = HttpSyncSettingsStore()

    /// Default base URL the screen pre-fills with. Points at the fork owner's own server; users
    /// can type anything else and that value gets persisted.
    static let defaultBaseURL = "https://dragos.games/api/book_sync"

    private enum Keys {
        static let baseURL = "httpSync.baseURL"
        static let enabled = "httpSync.enabled"
        static let syncMode = "httpSync.syncMode"
        static let lastSyncedAt = "httpSync.lastSyncedAt"
    }

    private let defaults: UserDefaults

    /// Base URL of the sync server, e.g. `https://dragos.games/api/book_sync`. No trailing slash.
    var baseURL: String {
        didSet {
            let normalized = Self.normalizeBaseURL(baseURL)
            if normalized != baseURL { baseURL = normalized; return }
            defaults.set(normalized, forKey: Keys.baseURL)
        }
    }

    /// Whether HTTP sync auto-push hooks are wired up. "Sync now" works regardless.
    var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Keys.enabled) }
    }

    var syncMode: HttpSyncMode {
        didSet { defaults.set(syncMode.rawValue, forKey: Keys.syncMode) }
    }

    /// Highest `lastModified` (RFC 3339 UTC) the client has applied. Drives the inbound
    /// `?since=` filter so we never re-fetch unchanged keys. Managed by the reconciler, not the
    /// UI. `nil` until the first successful reconcile.
    var lastSyncedAt: String? {
        didSet {
            if let lastSyncedAt, !lastSyncedAt.isEmpty {
                defaults.set(lastSyncedAt, forKey: Keys.lastSyncedAt)
            } else {
                defaults.removeObject(forKey: Keys.lastSyncedAt)
            }
        }
    }

    /// Bearer token sent in the `Authorization` header. Stored in the Keychain, NOT UserDefaults.
    /// Reading hits the Keychain each access (cheap; tokens are short and infrequently read).
    var token: String {
        get { Keychain.get(SecretKeys.httpSyncToken) ?? "" }
        set { Keychain.set(newValue.isEmpty ? nil : newValue, for: SecretKeys.httpSyncToken) }
    }

    /// True iff we have a secure base URL and a token — the precondition for any network call.
    var isConfigured: Bool {
        !baseURL.trimmingCharacters(in: .whitespaces).isEmpty &&
        !token.trimmingCharacters(in: .whitespaces).isEmpty &&
        Self.isSecureBaseURL(baseURL)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Fall back to the default URL only when nothing was ever written — once the user has
        // typed (even cleared the field to ""), that explicit value wins. Matches Android.
        if let stored = defaults.string(forKey: Keys.baseURL) {
            self.baseURL = stored
        } else {
            self.baseURL = Self.defaultBaseURL
        }
        self.enabled = defaults.bool(forKey: Keys.enabled)
        self.syncMode = HttpSyncMode(rawValue: defaults.string(forKey: Keys.syncMode) ?? "") ?? .manual
        self.lastSyncedAt = defaults.string(forKey: Keys.lastSyncedAt)
    }

    /// Snapshot of the connection parameters for handing to a transport off the main actor.
    func currentConfig() -> HttpSyncConfig {
        HttpSyncConfig(baseURL: Self.normalizeBaseURL(baseURL), token: token)
    }

    private static func normalizeBaseURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Bearer-token sync must not run over cleartext network links. Plain HTTP is accepted only
    /// for loopback development where the token never leaves the device.
    static func isSecureBaseURL(_ raw: String) -> Bool {
        let normalized = normalizeBaseURL(raw)
        guard let components = URLComponents(string: normalized),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty else { return false }
        if scheme == "https" { return true }
        if scheme == "http" {
            return host == "localhost" || host == "127.0.0.1" || host == "::1"
        }
        return false
    }
}

/// Sendable snapshot of the bits a transport needs, so the reconciler/manager can build a
/// `HttpSyncKvClient` without touching the `@MainActor` store off the main thread.
struct HttpSyncConfig: Sendable {
    let baseURL: String
    let token: String
    var isConfigured: Bool { !baseURL.isEmpty && !token.isEmpty && HttpSyncSettingsStore.isSecureBaseURL(baseURL) }
}
