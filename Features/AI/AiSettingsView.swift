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
    @State private var promptText = ""
    @State private var imagePromptText = ""

    private static let customTag = "__custom__"

    /// Picker row label: "Display name · note" when a note exists, else just the display name.
    private static func label(for m: ChatModelOption) -> String {
        if let note = m.note { return "\(m.displayName) · \(note)" }
        return m.displayName
    }

    private var isCustom: Bool { selectedModelId == Self.customTag }
    private var effectiveModelId: String { isCustom ? customModel : selectedModelId }
    private var provider: ChatProvider { ChatModelCatalog.provider(forModelId: effectiveModelId) }

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
                Text("Cheaper and Chinese providers (DeepSeek, Qwen, Kimi) and Anthropic (Claude) "
                    + "are included alongside OpenAI. A custom id is treated as an OpenAI model.")
            }

            Section {
                SecureField(provider.id == "anthropic" ? "sk-ant-…" : "sk-…", text: $apiKey)
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
                TextEditor(text: $promptText)
                    .frame(minHeight: 120)
                    .onChange(of: promptText) { _, _ in saveSyncedFields() }
            } header: {
                Text("Prompt")
            } footer: {
                Text("Sent ahead of a speech bubble's text.")
            }

            Section {
                TextEditor(text: $imagePromptText)
                    .frame(minHeight: 120)
                    .onChange(of: imagePromptText) { _, _ in saveSyncedFields() }
            } header: {
                Text("Image prompt")
            } footer: {
                Text("Sent with a screenshot crop for vision translation.")
            }

            Section {
                Button("Reset prompts to defaults", role: .destructive) {
                    promptText = AiChatDefaults.prompt
                    imagePromptText = AiChatDefaults.imagePrompt
                    saveSyncedFields()
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
    }

    private func load() {
        promptText = store.promptText
        imagePromptText = store.imagePromptText
        // Seed the picker: a known model selects its row; anything else is "Custom".
        if ChatModelCatalog.isKnownModel(store.model) {
            selectedModelId = store.model
            customModel = ""
        } else {
            selectedModelId = Self.customTag
            customModel = store.model
        }
        reloadKey()
    }

    /// Reloads the key field to the currently-selected provider's stored key.
    private func reloadKey() {
        apiKey = store.apiKey(for: provider)
    }

    /// Persists the chosen model (skips an empty custom id so mid-typing doesn't wipe it).
    private func saveModel() {
        let id = effectiveModelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        store.update(model: id, promptText: promptText, imagePromptText: imagePromptText)
    }

    /// Pushes the synced fields through the store in one update so `lastEditedAt` is stamped at most
    /// once per edit.
    private func saveSyncedFields() {
        store.update(model: effectiveModelId, promptText: promptText, imagePromptText: imagePromptText)
    }
}
