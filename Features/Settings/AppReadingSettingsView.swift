// Copyright © 2026 Manhhao.
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Shared app colors live here; Manga and EPUB keep their format-specific controls.
struct AppReadingSettingsView: View {
    let userConfig: UserConfig

    var body: some View {
        @Bindable var userConfig = userConfig
        List {
            Section("Theme") {
                Picker("Appearance", selection: $userConfig.theme) {
                    ForEach(Themes.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                if userConfig.theme == .system {
                    Toggle("Use Sepia as Light Theme", isOn: $userConfig.systemLightSepia)
                }
                if userConfig.theme == .sepia {
                    Toggle("Invert in System Dark Theme", isOn: $userConfig.sepiaInvertInDark)
                }
                if userConfig.theme == .custom {
                    Picker("Interface", selection: $userConfig.uiTheme) {
                        Text("System").tag(Themes.system)
                        Text("Light").tag(Themes.light)
                        Text("Dark").tag(Themes.dark)
                    }
                    ColorPicker("Background Color", selection: $userConfig.customBackgroundColor)
                    ColorPicker("Text Color", selection: $userConfig.customTextColor)
                    ColorPicker("Info Color", selection: $userConfig.customInfoColor)
                }
            }
        }
        .navigationTitle("App & reading")
        .accessibilityIdentifier("app-reading-settings")
    }
}
