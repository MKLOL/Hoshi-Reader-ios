//
//  OfflineTranslationSettingsStore.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Persisted settings for on-device (offline) translation: whether the reader routes bubble
//  translations through the bundled local model instead of the OpenAI client, and which downloaded
//  model is active. Ported from Android `features/ai/offline/OfflineTranslationSettings.kt`.
//
//  Deliberately NOT synced across devices: downloaded models and device capability are inherently
//  per-device, so the chosen model id is local state only (plain UserDefaults, no `lastEditedAt`).
//

import Foundation

@Observable
final class OfflineTranslationSettingsStore {
    static let shared = OfflineTranslationSettingsStore()

    private let defaults: UserDefaults

    /// When `true`, the reader prefers the on-device model over the OpenAI chat client for bubble
    /// translation. Defaults to `false`.
    var useOnDeviceTranslation: Bool {
        didSet { defaults.set(useOnDeviceTranslation, forKey: Keys.useOnDevice) }
    }

    /// Id of the active catalog model (see `LlmModelCatalog`). `nil` means "fall back to the
    /// catalog default", matching Android's behavior of seeding the default id.
    var selectedModelId: String? {
        didSet {
            if let selectedModelId, !selectedModelId.isEmpty {
                defaults.set(selectedModelId, forKey: Keys.selectedModelId)
            } else {
                defaults.removeObject(forKey: Keys.selectedModelId)
            }
        }
    }

    /// The catalog model the user has selected, falling back to the catalog default when the stored
    /// id is missing or unknown (e.g. after a catalog change).
    var selectedModel: LlmModel {
        if let id = selectedModelId, let model = LlmModelCatalog.byId(id) { return model }
        return LlmModelCatalog.default
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        useOnDeviceTranslation = defaults.bool(forKey: Keys.useOnDevice)
        let stored = defaults.string(forKey: Keys.selectedModelId)
        selectedModelId = (stored?.isEmpty == false) ? stored : nil
    }

    private enum Keys {
        static let useOnDevice = "offlineTranslation.useOnDevice"
        static let selectedModelId = "offlineTranslation.selectedModelId"
    }
}
