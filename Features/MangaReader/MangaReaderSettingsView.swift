// Copyright © 2026 Manhhao.
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Format-specific controls share the same persisted preferences as the live reader.
struct MangaReaderSettingsView: View {
    @Environment(UserConfig.self) private var userConfig

    var body: some View {
        @Bindable var userConfig = userConfig
        List {
            Section {
                Toggle("Show Furigana", isOn: $userConfig.mangaShowFurigana)
                    .accessibilityIdentifier("manga-show-furigana")
                Toggle("Enlarge Small Text", isOn: $userConfig.mangaEnlargeSmallText)
                Toggle("Use Japanese sans-serif font", isOn: $userConfig.mangaUseNotoSansJpFont)
            } header: { Text("Recognized text") } footer: {
                Text("Generate readings offline for revealed Japanese text. Small text can be enlarged for readability; turning enlargement off preserves its original OCR size.")
            }

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
        .navigationTitle("Manga")
        .accessibilityIdentifier("manga-settings")
    }
}
