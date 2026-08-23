//
//  AiSettingsView.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Translation-model settings: pick a model from a dropdown spanning multiple providers (OpenAI,
//  Anthropic, and cheaper / Chinese OpenAI-compatible providers — DeepSeek, Qwen, Moonshot/Kimi),
//  or enter a custom model id. The API key is stored per provider in the Keychain (never synced).
//  Only the model-id string syncs across devices (the provider is derived from it), so the sync
//  wire shape is unchanged from the original free-text model field.
//

import SwiftUI

struct AiSettingsView: View {
    @State private var store = AiChatSettingsStore.shared

    @State private var apiKey = ""
    /// The picker selection — a known model id, or `customTag` when entering a custom id.
    @State private var selectedModelId = ""
    @State private var customModel = ""

    private static let customTag = "__custom__"

    /// Picker row label: "Display name · note" when a note exists, else just the display name.
    private static func label(for m: ChatModelOption) -> String {
        if let note = m.note { return "\(m.displayName) · \(note)" }
        return m.displayName
    }

    private var isCustom: Bool { selectedModelId == Self.customTag }
    private var effectiveModelId: String { isCustom ? customModel : selectedModelId }
    private var provider: ChatProvider { ChatModelCatalog.provider(forModelId: effectiveModelId) }
    private var keyPlaceholder: String {
        switch provider.id {
        case "anthropic": return "sk-ant-…"
        case "google": return "AIza…"
        default: return "sk-…"
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("Model", selection: $selectedModelId) {
                    ForEach(ChatModelCatalog.providers) { p in
                        Section(p.displayName) {
                            ForEach(ChatModelCatalog.models.filter { $0.provider == p }) { m in
                                Text(Self.label(for: m)).tag(m.id)
                            }
                        }
                    }
                    Text("Custom…").tag(Self.customTag)
                }
                if isCustom {
                    TextField("Model id, e.g. \(AiChatDefaults.model)", text: $customModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: customModel) { _, _ in saveModel() }
                }
            } header: {
                Text("Translation model")
            } footer: {
                Text("Gemini, DeepSeek, Qwen, Kimi, and Anthropic are included alongside OpenAI. "
                    + "Known provider prefixes are routed to that provider.")
            }

            Section {
                SecureField(keyPlaceholder, text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: apiKey) { _, newValue in store.setApiKey(newValue, for: provider) }
            } header: {
                Text("\(provider.displayName) API key")
            } footer: {
                Text("Stored only on this device (Keychain) and never synced. Each provider keeps "
                    + "its own key. Get a key at \(provider.keysURL)")
            }

            Section {
                TextEditor(text: Binding(
                    get: { store.promptText },
                    set: { store.setPromptText($0) }
                ))
                    .frame(minHeight: 120)
            } header: {
                Text("Prompt")
            } footer: {
                Text("Sent ahead of a speech bubble's text.")
            }

            Section {
                TextEditor(text: Binding(
                    get: { store.imagePromptText },
                    set: { store.setImagePromptText($0) }
                ))
                    .frame(minHeight: 120)
            } header: {
                Text("Image prompt")
            } footer: {
                Text("Sent with a screenshot crop for vision translation.")
            }

            Section {
                Toggle("Use default Markdown text size", isOn: Binding(
                    get: { store.useUniformMarkdownTextSize },
                    set: { store.setUseUniformMarkdownTextSize($0) }
                ))
            } footer: {
                Text("Keeps Markdown formatting but renders headings and inline code at the normal text size.")
            }

            Section {
                Button("Reset prompts to defaults", role: .destructive) {
                    store.update(
                        model: store.model,
                        promptText: AiChatDefaults.prompt,
                        imagePromptText: AiChatDefaults.imagePrompt
                    )
                }
            }
        }
        .navigationTitle("Translation model")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { load() }
        .onChange(of: selectedModelId) { _, _ in
            saveModel()
            reloadKey()
        }
        // A manual sync can change the selected model while this screen is open. Keep the picker
        // aligned with the store that MangaAiController actually reads.
        .onChange(of: store.model) { _, _ in
            loadModelSelection()
            reloadKey()
        }
    }

    private func load() {
        loadModelSelection()
        reloadKey()
    }

    private func loadModelSelection() {
        // Seed the picker: a known model selects its row; anything else is "Custom".
        if ChatModelCatalog.isKnownModel(store.model) {
            selectedModelId = store.model
            customModel = ""
        } else {
            selectedModelId = Self.customTag
            customModel = store.model
        }
    }

    /// Reloads the key field to the currently-selected provider's stored key.
    private func reloadKey() {
        apiKey = store.apiKey(for: provider)
    }

    /// Persists the chosen model (skips an empty custom id so mid-typing doesn't wipe it).
    private func saveModel() {
        let id = effectiveModelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        store.update(model: id, promptText: store.promptText, imagePromptText: store.imagePromptText)
    }
}
