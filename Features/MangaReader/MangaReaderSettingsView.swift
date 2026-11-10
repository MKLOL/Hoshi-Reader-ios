// Copyright © 2026 Manhhao.
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Format-specific controls share the same persisted preferences as the live reader.
struct MangaReaderSettingsView: View {
    @Environment(UserConfig.self) private var userConfig
    var previewSource: MangaTextPreviewSource? = nil
    @State private var showPagePreview = false

    var body: some View {
        @Bindable var userConfig = userConfig
        List {
            Section {
                Toggle("Show Furigana", isOn: $userConfig.mangaShowFurigana)
                    .accessibilityIdentifier("manga-show-furigana")
                Toggle("Use Japanese sans-serif font", isOn: $userConfig.mangaUseNotoSansJpFont)
            } header: { Text("Recognized text") } footer: {
                Text("Generate readings offline for revealed Japanese text.")
            }

            Section {
                Button("Preview on a manga page") { showPagePreview = true }
                    .accessibilityIdentifier("manga-open-page-preview")
                Text("Smaller text can match, but never overtake, larger text.").font(.caption).foregroundStyle(.secondary)
            }
            MangaTextEnlargementControls(settings: $userConfig.mangaTextEnlargement)

            Section {
                Toggle("Single-tap Lookup", isOn: $userConfig.mangaSingleTapLookup)
                Toggle("Show translation button", isOn: $userConfig.mangaShowActionButtons)
                Toggle("Show Copy button", isOn: $userConfig.mangaShowCopyButton)
                Toggle("Scan Non-Japanese Text", isOn: $userConfig.mangaScanNonJapaneseText)
            } header: { Text("Bubble actions") } footer: {
                Text("Single-tap lookup reveals and looks up a bubble on the first tap. When off, the first tap reveals the text and a second tap looks it up.")
            }

            Section("Page turning") {
                Toggle("Disable page-turn animation", isOn: $userConfig.disablePageTurnAnimation)
            }

            Section("Related settings") {
                NavigationLink("App & reading") { AppReadingSettingsView(userConfig: userConfig) }
                NavigationLink("Popup Cards") { PopupCardsView(userConfig: userConfig) }
            }
        }
        .fullScreenCover(isPresented: $showPagePreview) { MangaTextPreviewLauncher(source: previewSource).environment(userConfig) }
        .navigationTitle("Manga")
        .accessibilityIdentifier("manga-settings")
    }
}

private struct MangaTextEnlargementControls: View {
    @Binding var settings: MangaTextEnlargement
    private let presets: [(name: LocalizedStringKey, id: String, amount: Int, threshold: Int)] = [
        ("Subtle", "subtle", 25, 24), ("Balanced", "balanced", 50, 30), ("Strong", "strong", 75, 40)
    ]

    var body: some View {
        Section {
            Toggle("Enlarge Small Text", isOn: $settings.enabled)
                .accessibilityIdentifier("manga-text-enlargement-enabled")

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(presets, id: \.id) { preset in
                        presetButton(preset)
                    }
                }
                .disabled(!settings.enabled)

                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Enlargement amount", value: "\(settings.amount)%")
                    Slider(value: Binding(get: { Double(settings.amount) }, set: { settings.amount = Int($0) }), in: 0...100, step: 5)
                        .accessibilityLabel("Enlargement amount")
                        .accessibilityValue("\(settings.amount)%")
                        .accessibilityIdentifier("manga-text-enlargement-amount")
                    Text("Fills this much of the gap between the original size and the cutoff.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .disabled(!settings.enabled)

                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Small-text cutoff", value: "\(settings.threshold) px")
                    Slider(value: Binding(get: { Double(settings.threshold) }, set: { settings.threshold = Int($0) }), in: 10...60, step: 1)
                        .accessibilityLabel("Small-text cutoff")
                        .accessibilityValue("\(settings.threshold) image pixels")
                        .accessibilityIdentifier("manga-text-enlargement-threshold")
                    Text("Only text smaller than this in the source image is enlarged. Larger text keeps its original size.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .disabled(!settings.enabled)

                preview
            }
            .padding(.vertical, 4)
        } header: {
            Text("Small text")
        } footer: {
            Text("Preview uses source-image pixels; page fit and zoom change the displayed size. These settings sync between your iOS devices, separately from Android.")
        }
    }

    private func presetButton(_ preset: (name: LocalizedStringKey, id: String, amount: Int, threshold: Int)) -> some View {
        let value = MangaTextEnlargement(amount: preset.amount, threshold: preset.threshold)
        let selected = settings.enabled && settings.amount == preset.amount && settings.threshold == preset.threshold
        return Button {
            settings = value
        } label: {
            VStack(spacing: 6) {
                Text(verbatim: "学校").font(.system(size: CGFloat(value.fontSize(original: 12))))
                    .frame(height: 36)
                Text(preset.name).font(.subheadline.weight(.semibold))
                Text("\(preset.amount)% · \(preset.threshold) px").font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("manga-text-preset-\(preset.id)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Live preview").font(.subheadline.weight(.semibold))
            HStack {
                Text("Original").frame(maxWidth: .infinity, alignment: .leading)
                Text("With your settings").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption).foregroundStyle(.secondary)

            ForEach([12, 20, 30, 40], id: \.self) { original in
                let result = settings.fontSize(original: original)
                HStack(alignment: .center, spacing: 12) {
                    sample(size: original)
                    sample(size: result)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(original) px becomes \(result) px")
                .accessibilityIdentifier("manga-text-preview-\(original)-\(result)")
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private func sample(size: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "学校").font(.system(size: CGFloat(size)))
            Text("\(size) px").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 46)
    }
}
