//
//  SyncCore.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Pure, cross-device-critical helpers for the HTTP KV sync protocol, ported byte-for-byte
//  from the Android client (features/sync/http/HttpSyncBlobs.kt) so the two platforms converge
//  on the same server blobs. Getting any of these subtly wrong silently desyncs or duplicates
//  books across platforms, so they are kept dependency-free and unit-verified.
//

import CryptoKit
import Foundation

// MARK: - Sync id derivation

nonisolated private let syncIdMaxSegmentLength = 64
nonisolated private let syncIdHashHexLength = 16 // hex chars -> 8 bytes of the digest

/// Computes a stable, server-safe sync id from a book's title. Lowercase, replace every
/// non-`[a-z0-9]` character with `_`, collapse runs, trim. Titles that produce no ASCII slug
/// (e.g. Japanese-only titles) or an overlong slug get a deterministic short hash suffix.
///
/// Must stay byte-identical to Android `deriveSyncId` — two devices only converge on the same
/// book when this produces the same id. Returns `nil` for a blank title.
nonisolated func deriveSyncId(_ title: String?) -> String? {
    let raw = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if raw.isEmpty { return nil }

    var sanitizedScalars = String.UnicodeScalarView()
    for scalar in raw.lowercased().unicodeScalars {
        let v = scalar.value
        if (v >= 97 && v <= 122) || (v >= 48 && v <= 57) { // a-z, 0-9
            sanitizedScalars.append(scalar)
        } else {
            sanitizedScalars.append("_")
        }
    }
    let sanitized = trimUnderscores(collapseUnderscores(String(sanitizedScalars)))

    if sanitized.isEmpty { return "book_\(shortTitleHash(raw))" }
    if sanitized.count <= syncIdMaxSegmentLength { return sanitized }

    let hash = shortTitleHash(raw)
    let prefixLength = syncIdMaxSegmentLength - hash.count - 1
    var prefix = trimUnderscores(String(sanitized.prefix(prefixLength)))
    if prefix.isEmpty { prefix = "book" }
    return "\(prefix)_\(hash)"
}

nonisolated private func collapseUnderscores(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    var prevUnderscore = false
    for ch in s {
        if ch == "_" {
            if !prevUnderscore { out.append(ch) }
            prevUnderscore = true
        } else {
            out.append(ch)
            prevUnderscore = false
        }
    }
    return out
}

nonisolated private func trimUnderscores(_ s: String) -> String {
    s.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
}

/// First 8 bytes of SHA-256(UTF-8 title), hex-encoded -> 16 hex chars. Hashes the trimmed-but-
/// NOT-lowercased title (matching Android `shortTitleHash`).
nonisolated func shortTitleHash(_ title: String) -> String {
    let digest = SHA256.hash(data: Data(title.utf8))
    return digest.prefix(syncIdHashHexLength / 2).map { String(format: "%02x", $0) }.joined()
}

// MARK: - Chat key

/// Suffix of a chat entry's KV key: `{rfc3339_utc}-{8-hex-content-hash}`, where the timestamp's
/// `:` are replaced with `-`, and the content hash is the first 4 bytes of
/// sha256("bubbleText|response"). Two devices that produced the same entry converge on one blob.
nonisolated func chatEntryKeySuffix(timestampAppleSeconds: Double, bubbleText: String, response: String) -> String {
    let rfc3339 = appleSecondsToRfc3339(timestampAppleSeconds).replacingOccurrences(of: ":", with: "-")
    let digest = SHA256.hash(data: Data("\(bubbleText)|\(response)".utf8))
    let short = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    return "\(rfc3339)-\(short)"
}

// MARK: - Timestamp helpers (Apple-reference seconds <-> RFC 3339)

/// Apple's reference date in Unix epoch seconds (2001-01-01T00:00:00Z). `Date`'s
/// `timeIntervalSinceReferenceDate` is already in this epoch, which keeps the iOS side clean.
nonisolated let appleReferenceEpoch: Double = 978_307_200

// `nonisolated(unsafe)`: the project defaults unannotated globals to `@MainActor`, but the sync
// helpers run off the main actor (detached reconcile + fire-and-forget push hooks). These
// formatters are configured once and only used for thread-safe `string(from:)` / `date(from:)`
// calls (ISO8601DateFormatter is documented safe for concurrent formatting/parsing), so opting
// them out of actor isolation is sound and required for off-main sync work.
nonisolated(unsafe) private let rfc3339SecondsFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime] // yyyy-MM-ddTHH:mm:ssZ (no fraction)
    f.timeZone = TimeZone(identifier: "UTC")
    return f
}()

nonisolated(unsafe) private let rfc3339FractionalFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    f.timeZone = TimeZone(identifier: "UTC")
    return f
}()

/// Formats Apple-reference seconds as RFC 3339 UTC, matching Java's `Instant.toString()`: no
/// fractional part when the millisecond component is zero, otherwise exactly 3 fraction digits.
/// Android always produces millisecond precision (built from `epochMilli`), so this exactly
/// reproduces its output — which matters because the value feeds both chat keys and LWW compares.
nonisolated func appleSecondsToRfc3339(_ appleSeconds: Double) -> String {
    let unixMillis = Int64((appleSeconds + appleReferenceEpoch) * 1000.0)
    var secs = unixMillis / 1000
    var millis = unixMillis % 1000
    if millis < 0 { millis += 1000; secs -= 1 } // floor split, matching Java epochMilli semantics
    let date = Date(timeIntervalSince1970: Double(secs))
    let base = rfc3339SecondsFormatter.string(from: date)
    if millis == 0 { return base }
    return String(base.dropLast()) + String(format: ".%03dZ", millis)
}

nonisolated func rfc3339ToAppleSeconds(_ rfc3339: String) -> Double {
    guard let date = parseRfc3339(rfc3339) else { return 0.0 }
    return date.timeIntervalSinceReferenceDate
}

nonisolated func parseRfc3339(_ s: String) -> Date? {
    rfc3339FractionalFormatter.date(from: s) ?? rfc3339SecondsFormatter.date(from: s)
}

/// RFC 3339 string for "now".
nonisolated func rfc3339Now() -> String { appleSecondsToRfc3339(Date().timeIntervalSinceReferenceDate) }

/// `Date` -> RFC 3339 (millisecond precision, Z suffix).
nonisolated func rfc3339(from date: Date) -> String { appleSecondsToRfc3339(date.timeIntervalSinceReferenceDate) }

/// Chronological comparison of RFC 3339 timestamps. Parses both to instants (so a fraction-less
/// "…56Z" sorts correctly against "…56.001Z"); falls back to lexicographic only if parsing fails.
/// Returns a negative/zero/positive Int like Kotlin `compareTo`.
nonisolated func compareRfc3339(_ a: String?, _ b: String?) -> Int {
    if let da = a.flatMap(parseRfc3339), let db = b.flatMap(parseRfc3339) {
        if da < db { return -1 }
        if da > db { return 1 }
        return 0
    }
    let sa = a ?? "", sb = b ?? ""
    if sa < sb { return -1 }
    if sa > sb { return 1 }
    return 0
}

/// Whichever of two RFC 3339 timestamps is later, or `nil` if both are nil.
nonisolated func maxRfc(_ left: String?, _ right: String?) -> String? {
    guard let left else { return right }
    guard let right else { return left }
    return compareRfc3339(left, right) >= 0 ? left : right
}

/// Re-import-after-tombstone guard: true iff local `importedAt` is strictly later than remote
/// `deletedAt` (the user re-imported after the tombstone was published, so the live copy wins).
/// Conservative on missing/unparseable data — the tombstone wins.
nonisolated func localImportedAtOverridesRemoteDeletion(localImportedAt: String?, remoteDeletedAt: String?) -> Bool {
    guard let localImportedAt, let remoteDeletedAt,
          let local = parseRfc3339(localImportedAt),
          let remote = parseRfc3339(remoteDeletedAt) else { return false }
    return local > remote
}

// MARK: - Key builders

nonisolated enum SyncKeys {
    static let allBooksPrefix = "books/"
    static let aiChatSettingsKey = "app/ai_chat_settings"

    static func bookmark(_ syncId: String) -> String { "books/\(syncId)/bookmark" }
    static func metadata(_ syncId: String) -> String { "books/\(syncId)/metadata" }
    static func chatPrefix(_ syncId: String) -> String { "books/\(syncId)/chat/" }
    static func chat(_ syncId: String, suffix: String) -> String { "books/\(syncId)/chat/\(suffix)" }
    static func payloadZip(_ syncId: String) -> String { "books/\(syncId)/payload.zip" }
    static func payloadManifest(_ syncId: String) -> String { "books/\(syncId)/payload.manifest" }
}
