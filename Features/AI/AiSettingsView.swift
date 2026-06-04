//
//  AiSettingsView.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  ChatGPT settings: the OpenAI API key (stored in the Keychain, never synced), the model name
//  (free-text), and the prompt / image-prompt text. Ported from Android
//  features/ai/AiChatSettingsView.kt. Edits to the synced fields stamp `lastEditedAt` via the
//  store so the next sync pushes them.
//

import SwiftUI

struct AiSettingsView: View {
    @State private var store = AiChatSettingsStore.shared

    @State private var apiKey = ""
    @State private var model = ""
    @State private var promptText = ""
    @State private var imagePromptText = ""

    var body: some View {
        Form {
            Section {
                SecureField("sk-…", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: apiKey) { _, newValue in store.apiKey = newValue }
            } header: {
                Text("API key")
            } footer: {
                Text("Your OpenAI API key is stored only on this device (Keychain) and is never synced.")
            }

            Section {
                TextField("Model", text: $model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: model) { _, _ in saveSyncedFields() }
            } header: {
                Text("Model")
            } footer: {
                Text("Any OpenAI model id, e.g. \(AiChatDefaults.model). If OpenAI rejects it the error shows in the chat popup.")
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
                    model = AiChatDefaults.model
                    saveSyncedFields()
                }
            }
        }
        .navigationTitle("ChatGPT")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            apiKey = store.apiKey
            model = store.model
            promptText = store.promptText
            imagePromptText = store.imagePromptText
        }
    }

    /// Pushes the three synced fields through the store in one update so `lastEditedAt` is stamped
    /// at most once per edit.
    private func saveSyncedFields() {
        store.update(model: model, promptText: promptText, imagePromptText: imagePromptText)
    }
}
