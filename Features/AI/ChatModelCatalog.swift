//
//  ChatModelCatalog.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  The set of cloud LLM providers + curated models the manga translation feature can use. The
//  user picks a model from a dropdown; the provider (and its base URL, auth scheme, and request
//  format) is DERIVED from the chosen model id via this catalog. That keeps the synced settings
//  unchanged — only the model-id string syncs, exactly as before — while letting us route to
//  OpenAI, Anthropic, and cheaper OpenAI-compatible providers (DeepSeek, Qwen, Moonshot/Kimi).
//
//  Most providers speak the OpenAI Chat Completions wire format, so they share one client with a
//  swapped base URL (`OpenAiChatClient`). Anthropic has its own Messages API shape + auth, served
//  by `AnthropicChatClient`.
//

import Foundation

/// How a provider's HTTP API is shaped. Drives which client builds/sends the request.
nonisolated enum ChatWireFormat {
    /// OpenAI Chat Completions (`/chat/completions`, `Authorization: Bearer`). Shared by OpenAI and
    /// the OpenAI-compatible providers (DeepSeek, Qwen, Moonshot, …).
    case openAICompatible
    /// Anthropic Messages API (`/v1/messages`, `x-api-key` + `anthropic-version`).
    case anthropic
}

/// A cloud LLM provider: where to send requests, how to authenticate, and which on-device Keychain
/// slot holds its API key.
nonisolated struct ChatProvider: Identifiable, Hashable {
    let id: String
    let displayName: String
    /// Base URL the request is sent under. For `openAICompatible`, `/chat/completions` is appended;
    /// for `anthropic`, `/v1/messages`.
    let baseURL: String
    let wireFormat: ChatWireFormat
    /// Keychain account under which this provider's API key is stored (per-device, never synced).
    let keychainKey: String
    /// Where the user creates a key — shown in the settings footer.
    let keysURL: String

    // Explicit nonisolated init: in the project's default-MainActor isolation mode the synthesized
    // memberwise initializer would be main-actor-isolated, which can't be called from the
    // nonisolated `static let` catalog below.
    nonisolated init(id: String, displayName: String, baseURL: String, wireFormat: ChatWireFormat,
                     keychainKey: String, keysURL: String) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.wireFormat = wireFormat
        self.keychainKey = keychainKey
        self.keysURL = keysURL
    }

    static func == (lhs: ChatProvider, rhs: ChatProvider) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// One selectable model, tied to its provider.
nonisolated struct ChatModelOption: Identifiable, Hashable {
    /// The wire model id sent to the provider (also the value persisted/synced as `settings.model`).
    let id: String
    let displayName: String
    let provider: ChatProvider
    /// Short hint shown in the picker (e.g. "cheapest", "best").
    let note: String?

    nonisolated init(id: String, displayName: String, provider: ChatProvider, note: String?) {
        self.id = id
        self.displayName = displayName
        self.provider = provider
        self.note = note
    }
}

nonisolated enum ChatModelCatalog {
    // MARK: Providers

    static let openAI = ChatProvider(
        id: "openai",
        displayName: "OpenAI (ChatGPT)",
        baseURL: "https://api.openai.com/v1",
        wireFormat: .openAICompatible,
        // Literal must match `SecretKeys.openAIApiKey` — reusing the long-standing Keychain slot so
        // existing users keep their key. (Inlined rather than referenced because `SecretKeys` is
        // main-actor-isolated and this catalog is nonisolated.)
        keychainKey: "moe.antimony.hoshi.openai_api_key",
        keysURL: "https://platform.openai.com/api-keys"
    )

    static let anthropic = ChatProvider(
        id: "anthropic",
        displayName: "Anthropic (Claude)",
        baseURL: "https://api.anthropic.com",
        wireFormat: .anthropic,
        keychainKey: "moe.antimony.hoshi.apikey.anthropic",
        keysURL: "https://console.anthropic.com/settings/keys"
    )

    static let deepSeek = ChatProvider(
        id: "deepseek",
        displayName: "DeepSeek",
        baseURL: "https://api.deepseek.com/v1",
        wireFormat: .openAICompatible,
        keychainKey: "moe.antimony.hoshi.apikey.deepseek",
        keysURL: "https://platform.deepseek.com/api_keys"
    )

    static let qwen = ChatProvider(
        id: "qwen",
        displayName: "Qwen (Alibaba)",
        baseURL: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
        wireFormat: .openAICompatible,
        keychainKey: "moe.antimony.hoshi.apikey.qwen",
        keysURL: "https://bailian.console.alibabacloud.com/"
    )

    static let moonshot = ChatProvider(
        id: "moonshot",
        displayName: "Moonshot (Kimi)",
        baseURL: "https://api.moonshot.ai/v1",
        wireFormat: .openAICompatible,
        keychainKey: "moe.antimony.hoshi.apikey.moonshot",
        keysURL: "https://platform.moonshot.ai/console/api-keys"
    )

    // Google Gemini via its OpenAI-compatible endpoint (`Authorization: Bearer <key>`), so it reuses
    // the same Chat Completions client — no Gemini-specific code needed.
    static let google = ChatProvider(
        id: "google",
        displayName: "Google (Gemini)",
        baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
        wireFormat: .openAICompatible,
        keychainKey: "moe.antimony.hoshi.apikey.google",
        keysURL: "https://aistudio.google.com/apikey"
    )

    static let providers: [ChatProvider] = [openAI, anthropic, google, deepSeek, qwen, moonshot]

    // MARK: Models
    //
    // Curated, current models per provider. The list is intentionally short — the "Custom" option
    // in settings still accepts any model id for power users / new releases. Each id is unique
    // across providers (claude-*, deepseek-*, qwen-*, moonshot-*, gpt-*), so the provider can be
    // recovered from the id alone.

    static let models: [ChatModelOption] = [
        // OpenAI
        .init(id: "gpt-5.5", displayName: "GPT-5.5", provider: openAI, note: "default"),
        .init(id: "gpt-5", displayName: "GPT-5", provider: openAI, note: nil),
        .init(id: "gpt-4o", displayName: "GPT-4o", provider: openAI, note: nil),
        .init(id: "gpt-4o-mini", displayName: "GPT-4o mini", provider: openAI, note: "cheap"),

        // Anthropic
        .init(id: "claude-opus-4-8", displayName: "Claude Opus 4.8", provider: anthropic, note: "best"),
        .init(id: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6", provider: anthropic, note: nil),
        .init(id: "claude-haiku-4-5", displayName: "Claude Haiku 4.5", provider: anthropic, note: "cheap"),

        // Google Gemini (Flash models are fast + cheap, strong at JP→EN)
        .init(id: "gemini-2.5-pro", displayName: "Gemini 2.5 Pro", provider: google, note: "best"),
        .init(id: "gemini-2.5-flash", displayName: "Gemini 2.5 Flash", provider: google, note: nil),
        .init(id: "gemini-2.5-flash-lite", displayName: "Gemini 2.5 Flash-Lite", provider: google, note: "cheap"),
        .init(id: "gemini-2.0-flash", displayName: "Gemini 2.0 Flash", provider: google, note: nil),

        // DeepSeek (very cheap, strong JP→EN)
        .init(id: "deepseek-chat", displayName: "DeepSeek V3", provider: deepSeek, note: "cheapest"),
        .init(id: "deepseek-reasoner", displayName: "DeepSeek R1", provider: deepSeek, note: "reasoning"),

        // Qwen
        .init(id: "qwen-plus", displayName: "Qwen Plus", provider: qwen, note: nil),
        .init(id: "qwen-turbo", displayName: "Qwen Turbo", provider: qwen, note: "cheap"),
        .init(id: "qwen-max", displayName: "Qwen Max", provider: qwen, note: nil),

        // Moonshot / Kimi
        .init(id: "moonshot-v1-8k", displayName: "Kimi (moonshot-v1-8k)", provider: moonshot, note: nil),
        .init(id: "moonshot-v1-32k", displayName: "Kimi (moonshot-v1-32k)", provider: moonshot, note: nil),
    ]

    /// The provider that serves `modelId`. Falls back to OpenAI for unknown / custom ids, preserving
    /// the original free-text behaviour (any unrecognised id is treated as an OpenAI model).
    static func provider(forModelId modelId: String) -> ChatProvider {
        let trimmed = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        return models.first { $0.id == trimmed }?.provider ?? openAI
    }

    /// The catalog entry for `modelId`, or `nil` if it's a custom id not in the list.
    static func option(forModelId modelId: String) -> ChatModelOption? {
        let trimmed = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        return models.first { $0.id == trimmed }
    }

    static func isKnownModel(_ modelId: String) -> Bool {
        option(forModelId: modelId) != nil
    }
}

/// Routes a translation request to the right client for a provider's wire format. `nonisolated` so
/// it can run off the main actor from the controller's background task.
nonisolated enum CloudChat {
    static func complete(provider: ChatProvider, apiKey: String, model: String,
                         prompt: String, bubbleText: String) async throws -> String {
        switch provider.wireFormat {
        case .anthropic:
            return try await AnthropicChatClient()
                .complete(apiKey: apiKey, model: model, prompt: prompt, bubbleText: bubbleText)
        case .openAICompatible:
            return try await OpenAiChatClient(baseURL: provider.baseURL)
                .complete(apiKey: apiKey, model: model, prompt: prompt, bubbleText: bubbleText)
        }
    }

    static func completeImage(provider: ChatProvider, apiKey: String, model: String,
                             prompt: String, image: AiChatImage) async throws -> String {
        switch provider.wireFormat {
        case .anthropic:
            return try await AnthropicChatClient()
                .completeImage(apiKey: apiKey, model: model, prompt: prompt, image: image)
        case .openAICompatible:
            return try await OpenAiChatClient(baseURL: provider.baseURL)
                .completeImage(apiKey: apiKey, model: model, prompt: prompt, image: image)
        }
    }
}
