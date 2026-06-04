//
//  HttpSyncConversions.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Local model ⇄ wire blob conversions for the v2 KV sync, mirroring the `internal` extension
//  helpers in Android HttpSyncBlobs.kt. Kept next to the reconciler/manager so neither has to
//  inline the Bookmark / AiChatEntry shapes.
//

import Foundation

extension Bookmark {
    /// `Bookmark` → wire bookmark blob. A nil `lastModified` maps to the Apple epoch (1970-01-01
    /// in Apple-reference terms is appleSeconds 0.0), matching Android's `appleSecondsToRfc3339(0.0)`.
    func toBlob() -> HttpSyncBookmarkBlob {
        let stamp = lastModified.map { rfc3339(from: $0) } ?? appleSecondsToRfc3339(0.0)
        return HttpSyncBookmarkBlob(
            chapterIndex: chapterIndex,
            progress: progress,
            characterCount: characterCount,
            lastModified: stamp
        )
    }
}

extension AiChatEntry {
    /// `AiChatEntry` → wire chat blob. `debugInfo` is intentionally dropped: the wire chat blob
    /// (HttpSyncChatEntryBlob) has no such field, matching Android, where `debugInfo` is on-device
    /// LLM telemetry that never travels through sync.
    func toBlob() -> HttpSyncChatEntryBlob {
        HttpSyncChatEntryBlob(
            bubbleText: bubbleText,
            prompt: prompt,
            model: model,
            response: response,
            timestampSeconds: timestampSeconds,
            screenshotImage: screenshotImage,
            dictionaryLookup: dictionaryLookup
        )
    }

    /// Same-entry detection for inbound dedup — mirrors the content-addressed chat key shape and
    /// Android's `AiChatEntry.matchesEntry`.
    func matchesEntry(_ other: AiChatEntry) -> Bool {
        bubbleText == other.bubbleText &&
        timestampSeconds == other.timestampSeconds &&
        response == other.response
    }
}

extension HttpSyncChatEntryBlob {
    /// Wire chat blob → `AiChatEntry`. `debugInfo` is left nil (not present on the wire).
    func toEntry() -> AiChatEntry {
        AiChatEntry(
            bubbleText: bubbleText,
            prompt: prompt,
            model: model,
            response: response,
            timestampSeconds: timestampSeconds,
            screenshotImage: screenshotImage,
            dictionaryLookup: dictionaryLookup,
            debugInfo: nil
        )
    }
}
