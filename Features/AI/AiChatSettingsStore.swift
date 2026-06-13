//
//  AiChatSettingsStore.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Settings for the ChatGPT manga features: the OpenAI API key (Keychain, never synced), the
//  prompt sent ahead of a bubble's OCR text, the prompt sent with a screenshot crop, and the model
//  name (UserDefaults). Ported from Android features/ai/AiChatSettings.kt (AiChatSettingsRepository).
//
//  Sync behavior: `model`, `promptText`, and `imagePromptText` sync across devices via the HTTP KV
//  protocol; `apiKey` stays strictly per-device. `lastEditedAt` is the LWW key, stamped on user
//  edits (`update`) via a Lamport-monotonic rule but NOT on sync-applied writes (`applyFromSync`),
//  otherwise a pull would always look newer than the just-pushed remote state and we'd oscillate.
//

import Foundation

@Observable
final class AiChatSettingsStore {
    static let shared = AiChatSettingsStore()

    private let defaults: UserDefaults

    /// API keys are stored per provider, each in its own Keychain slot — never in UserDefaults,
    /// never synced. The settings screen edits the key for the selected model's provider. OpenAI
    /// reuses its long-standing slot, so existing users keep their key.
    func apiKey(for provider: ChatProvider) -> String {
        Keychain.get(provider.keychainKey) ?? ""
    }

    func setApiKey(_ value: String, for provider: ChatProvider) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.set(trimmed.isEmpty ? nil : value, for: provider.keychainKey)
    }

    /// The provider that serves the currently-selected `model` (derived from the model id, so the
    /// synced settings stay a plain model-id string).
    var currentProvider: ChatProvider { ChatModelCatalog.provider(forModelId: model) }

    /// The model name. Free-text (not a fixed list) so the user can enter any OpenAI model id.
    private(set) var model: String
    /// Prompt text sent ahead of a bubble's OCR text.
    private(set) var promptText: String
    /// Prompt text sent with a screenshot crop.
    private(set) var imagePromptText: String
    /// RFC 3339 UTC timestamp of the most recent user-driven edit, or `nil` if never edited.
    private(set) var lastEditedAt: String?

    /// True once an API key has been entered for the currently-selected model's provider.
    var isConfigured: Bool {
        !apiKey(for: currentProvider).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedModel = defaults.string(forKey: Keys.model)
        model = (storedModel?.isEmpty == false) ? storedModel! : AiChatDefaults.model
        promptText = defaults.string(forKey: Keys.promptText) ?? AiChatDefaults.prompt
        imagePromptText = defaults.string(forKey: Keys.imagePromptText) ?? AiChatDefaults.imagePrompt
        lastEditedAt = defaults.string(forKey: Keys.lastEditedAt)
    }

    // MARK: - User-driven edits

    /// User-driven update of `model`. Auto-stamps `lastEditedAt` iff the value actually changed.
    func setModel(_ value: String) {
        update(model: value, promptText: promptText, imagePromptText: imagePromptText)
    }

    /// User-driven update of `promptText`. Auto-stamps `lastEditedAt` iff the value changed.
    func setPromptText(_ value: String) {
        update(model: model, promptText: value, imagePromptText: imagePromptText)
    }

    /// User-driven update of `imagePromptText`. Auto-stamps `lastEditedAt` iff the value changed.
    func setImagePromptText(_ value: String) {
        update(model: model, promptText: promptText, imagePromptText: value)
    }

    /// User-driven update. Auto-stamps `lastEditedAt` iff the sync-relevant fields actually
    /// changed (API-key-only edits don't bump the stamp because the API key doesn't sync).
    ///
    /// Lamport-monotonic stamping: the new stamp is `max(now, currentStamp + 1ms)`, so every
    /// user-driven edit is strictly newer than any prior stamp the device has ever seen — including
    /// a stale or maliciously-future stamp pulled from the server. Without this a single bad blob
    /// (e.g. a "2099" stamp) would wedge the user permanently.
    func update(model newModel: String, promptText newPrompt: String, imagePromptText newImagePrompt: String) {
        let changed = newModel != model || newPrompt != promptText || newImagePrompt != imagePromptText
        model = newModel
        promptText = newPrompt
        imagePromptText = newImagePrompt
        defaults.set(newModel, forKey: Keys.model)
        defaults.set(newPrompt, forKey: Keys.promptText)
        defaults.set(newImagePrompt, forKey: Keys.imagePromptText)
        if changed {
            let stamp = Self.stampStrictlyNewerThan(lastEditedAt)
            lastEditedAt = stamp
            defaults.set(stamp, forKey: Keys.lastEditedAt)
            // Settings edits sync immediately (debounced inside the manager; no-op when off).
            HttpSyncManager.shared.onAiSettingsChanged()
        }
    }

    /// Returns an RFC 3339 stamp strictly later than `previous`. Defaults to "now".
    private static func stampStrictlyNewerThan(_ previous: String?) -> String {
        let now = Date()
        if let previous, let prev = parseRfc3339(previous), prev >= now {
            // Something dragged the previous stamp into the future — step 1ms past it.
            return rfc3339(from: prev.addingTimeInterval(0.001))
        }
        return rfc3339(from: now)
    }

    // MARK: - Sync application

    /// Sync-side application of a remote value. Writes `model` / `promptText` / `imagePromptText` /
    /// `lastEditedAt` exactly as supplied; does NOT touch `apiKey`, which stays per-device.
    ///
    /// Returns `true` if the write was performed, `false` if the local store already had a
    /// `lastEditedAt` strictly newer than `remoteLastEditedAt` (the CAS that resolves the race
    /// between a sync apply and a user edit).
    @discardableResult
    func applyFromSync(model newModel: String, promptText newPrompt: String,
                       imagePromptText newImagePrompt: String, remoteLastEditedAt: String) -> Bool {
        let remoteIsNewer = lastEditedAt == nil || compareRfc3339(remoteLastEditedAt, lastEditedAt) > 0
        guard remoteIsNewer else { return false }
        model = newModel
        promptText = newPrompt
        imagePromptText = newImagePrompt
        lastEditedAt = remoteLastEditedAt
        defaults.set(newModel, forKey: Keys.model)
        defaults.set(newPrompt, forKey: Keys.promptText)
        defaults.set(newImagePrompt, forKey: Keys.imagePromptText)
        defaults.set(remoteLastEditedAt, forKey: Keys.lastEditedAt)
        return true
    }

    /// The current sync blob, or `nil` if the settings have never been user-edited (no
    /// `lastEditedAt` to use as the LWW key, so there is nothing meaningful to push yet).
    func currentBlob() -> HttpSyncAiChatSettingsBlob? {
        guard let lastEditedAt else { return nil }
        return HttpSyncAiChatSettingsBlob(
            model: model,
            promptText: promptText,
            imagePromptText: imagePromptText,
            lastModified: lastEditedAt
        )
    }

    private enum Keys {
        static let model = "aiChat.model"
        static let promptText = "aiChat.promptText"
        static let imagePromptText = "aiChat.imagePromptText"
        static let lastEditedAt = "aiChat.lastEditedAt"
    }
}
