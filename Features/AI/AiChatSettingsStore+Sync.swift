//
//  AiChatSettingsStore+Sync.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Phase 2 glue: makes the ChatGPT settings store satisfy the HTTP KV sync layer's
//  `AiSettingsSyncing` protocol, so the reconciler can push/pull the model + prompts (never the
//  API key). `AiChatSettingsStore` already exposes `currentBlob()` and `applyFromSync(...)` with
//  matching signatures, so this conformance is declaration-only.
//

import Foundation

extension AiChatSettingsStore: AiSettingsSyncing {}
