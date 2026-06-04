//
//  MangaReaderSettingsView.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Settings for the mokuro manga reader. Mirrors the Android reader toggles
//  (`features/reader/ReaderSettings.kt`): single-tap lookup, the Noto Sans JP OCR font, and
//  scanning non-Japanese text. Each is persisted in `UserConfig` and read by
//  `MangaReaderViewModel` when building each page's HTML.
//

import SwiftUI

struct MangaReaderSettingsView: View {
    @Environment(UserConfig.self) private var userConfig

    var body: some View {
        @Bindable var userConfig = userConfig
        List {
            Section {
                Toggle("Single-tap Lookup", isOn: $userConfig.mangaSingleTapLookup)
            } footer: {
                Text("Look up a bubble on the first tap. When off, the first tap reveals the text and a second tap looks it up.")
            }

            Section {
                Toggle("Use Japanese sans-serif font", isOn: $userConfig.mangaUseNotoSansJpFont)
            } footer: {
                Text("Render OCR text with a Japanese sans-serif font.")
            }

            Section {
                Toggle("Scan Non-Japanese Text", isOn: $userConfig.mangaScanNonJapaneseText)
            } footer: {
                Text("Allow the dictionary scanner to select non-Japanese text in bubbles.")
            }
        }
        .navigationTitle("Manga Reader")
    }
}
