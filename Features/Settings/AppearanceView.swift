//
//  AppearanceView.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import UniformTypeIdentifiers

struct AppearanceView: View {
    let userConfig: UserConfig
    let showDismiss: Bool
    /// Native transcript rows share reader fonts and readings, without pagination-only controls.
    var textOnly = false
    @Environment(\.dismiss) var dismiss
    @State private var isImportingFont = false
    @State private var importedFonts: [String] = []
    @State private var downloadingFont: String? = nil
    @State private var showingDeleteConfirmation = false
    @State private var fontToDelete: String? = nil
    
    var body: some View {
        @Bindable var userConfig = userConfig
        let fontSelection = Binding<String>(
            get: { userConfig.selectedFont },
            set: { newFont in
                guard downloadingFont == nil else { return }
                
                guard FontManager.downloadableFonts.contains(newFont),
                      !FontManager.shared.hasDownloadedFont(name: newFont) else {
                    userConfig.selectedFont = newFont
                    return
                }
                
                let previousFont = userConfig.selectedFont
                downloadingFont = newFont
                
                Task {
                    let success = await FontManager.downloadFont(newFont)
                    downloadingFont = nil
                    userConfig.selectedFont = success ? newFont : previousFont
                }
            }
        )
        NavigationStack {
            List {
                Section("Text") {
                    if !textOnly {
                    HStack {
                        Text("Text Orientation")
                        Spacer()
                        Picker("", selection: $userConfig.verticalWriting) {
                            Text("縦").tag(true)
                            Text("横").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 100)
                    }
                    }

                    HStack {
                        Picker("Font", selection: fontSelection) {
                            ForEach(FontManager.defaultFonts, id: \.self) { font in
                                Text(font).tag(font)
                            }
                            ForEach(FontManager.downloadableFonts, id: \.self) { font in
                                Text(font).tag(font)
                            }
                            ForEach(importedFonts, id: \.self) { font in
                                Text(font).tag(font)
                            }
                        }
                        .disabled(downloadingFont != nil)
                        
                        if !FontManager.shared.isDefaultFont(name: userConfig.selectedFont) {
                            Button {
                                fontToDelete = userConfig.selectedFont
                                showingDeleteConfirmation = true
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Delete this font")
                            .confirmationDialog("", isPresented: $showingDeleteConfirmation, titleVisibility: .hidden) {
                                Button("Delete", role: .destructive) {
                                    if let fontName = fontToDelete {
                                        try? FontManager.shared.deleteFont(name: fontName)
                                        userConfig.selectedFont = FontManager.defaultFonts[0]
                                        importedFonts = (try? FontManager.shared.storedFonts())?.map { $0.deletingPathExtension().lastPathComponent } ?? []
                                    }
                                }
                            } message: {
                                if let fontName = fontToDelete {
                                    Text("Delete \"\(fontName)\"?")
                                }
                            }
                        }
                        
                        if downloadingFont != nil {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    
                    Button {
                        isImportingFont = true
                    } label: {
                        Text("Import Font")
                    }
                    .fileImporter(
                        isPresented: $isImportingFont,
                        allowedContentTypes: [.font],
                        onCompletion: { result in
                            if case .success(let url) = result {
                                FontManager.shared.importFont(from: url)
                                importedFonts = (try? FontManager.shared.storedFonts())?.map { $0.deletingPathExtension().lastPathComponent } ?? []
                            }
                        }
                    )
                    
                    HStack {
                        Text("Font Size")
                        Spacer()
                        Text("\(userConfig.fontSize)")
                            .fontWeight(.semibold)
                        Stepper("", value: $userConfig.fontSize, in: 16...40)
                            .labelsHidden()
                    }

                    Toggle("Hide Furigana", isOn: $userConfig.readerHideFurigana)

                    if !textOnly {
                        Toggle("Sentence translations", isOn: $userConfig.readerShowSentenceTranslations)
                    }
                }
                
                if !textOnly {
                Section("Layout") {
                    HStack {
                        Text("Mode")
                        Spacer()
                        Picker("", selection: $userConfig.continuousMode) {
                            Text("Paginated").tag(false)
                            Text("Continuous").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                    }
                    
                    if userConfig.continuousMode {
                        VStack {
                            HStack {
                                Text("Chapter Swipe Distance")
                                Spacer()
                                Text("\(userConfig.chapterSwipeDistance)")
                                    .fontWeight(.semibold)
                            }
                            Slider(value: .init(
                                get: { Double(userConfig.chapterSwipeDistance) },
                                set: { userConfig.chapterSwipeDistance = Int($0) }
                            ), in: 10...60, step: 5)
                        }
                    }
                    
                    HStack {
                        Text("Horizontal Padding")
                        Spacer()
                        Text("\(userConfig.horizontalPadding)%")
                            .fontWeight(.semibold)
                        Stepper("", value: $userConfig.horizontalPadding, in: 0...50, step: 1)
                            .labelsHidden()
                    }
                    
                    HStack {
                        Text("Vertical Padding")
                        Spacer()
                        Text("\(userConfig.verticalPadding)%")
                            .fontWeight(.semibold)
                        Stepper("", value: $userConfig.verticalPadding, in: 0...50, step: 1)
                            .labelsHidden()
                    }
                    
                    Toggle("Avoid Page Break", isOn: $userConfig.avoidPageBreak)
                    
                    Toggle("Justify Text", isOn: $userConfig.justifyText)
                    
                    Toggle("Blur Images", isOn: $userConfig.blurImages)
                    
                    Toggle("Advanced", isOn: $userConfig.layoutAdvanced)
                    if userConfig.layoutAdvanced {
                        VStack {
                            HStack {
                                Text("Line Height")
                                Spacer()
                                Text("\(userConfig.lineHeight, specifier: "%.2f")")
                                    .fontWeight(.semibold)
                            }
                            Slider(value: $userConfig.lineHeight, in: 1.0...2.5, step: 0.05)
                        }
                        VStack {
                            HStack {
                                Text("Character Spacing")
                                Spacer()
                                Text("\(Int(userConfig.characterSpacing))%")
                                    .fontWeight(.semibold)
                            }
                            Slider(value: $userConfig.characterSpacing, in: -10...10, step: 1)
                        }
                        VStack {
                            HStack {
                                Text("Paragraph Spacing")
                                Spacer()
                                Text("\(userConfig.paragraphSpacing, specifier: "%.1f")em")
                                    .fontWeight(.semibold)
                            }
                            Slider(value: $userConfig.paragraphSpacing, in: 0...3, step: 0.1)
                        }
                    }
                }
                
                Section("Display") {
                    Toggle("Show Title", isOn: $userConfig.readerShowTitle)
                    Toggle("Show Character Count", isOn: $userConfig.readerShowCharacters)
                    Toggle("Show Percentage", isOn: $userConfig.readerShowPercentage)
                    
                    if userConfig.readerShowCharacters || userConfig.readerShowPercentage {
                        HStack {
                            Text("Progress Position")
                            Spacer()
                            Picker("", selection: $userConfig.readerShowProgressTop) {
                                Text("Top").tag(true)
                                Text("Bottom").tag(false)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 120)
                        }
                    }
                    
                    if userConfig.enableStatistics {
                        Toggle("Show Statistics Toggle", isOn: $userConfig.readerShowStatisticsToggle)
                        Toggle("Show Reading Speed", isOn: $userConfig.readerShowReadingSpeed)
                        Toggle("Show Reading Time", isOn: $userConfig.readerShowReadingTime)
                    }
                    
                    if userConfig.enableSasayaki {
                        Toggle("Show Sasayaki Toggle", isOn: $userConfig.readerShowSasayakiToggle)
                    }
                }
                
                Section("Page turning") {
                    Toggle("Disable page-turn animation", isOn: $userConfig.disablePageTurnAnimation)
                }

                Section("Related settings") {
                    NavigationLink("App & reading") { AppReadingSettingsView(userConfig: userConfig) }
                    NavigationLink("Popup Cards") { PopupCardsView(userConfig: userConfig) }
                    NavigationLink("Sasayaki") { SasayakiSettingsView() }
                }
                }
            }
            .navigationTitle(textOnly ? "Transcript text" : "EPUB")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showDismiss {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel(textOnly ? "Close transcript text settings" : "Close EPUB settings")
                        .accessibilityIdentifier("close-reader-settings")
                    }
                }
            }
            .onAppear {
                importedFonts = (try? FontManager.shared.storedFonts())?.map { $0.deletingPathExtension().lastPathComponent } ?? []
            }
        }
    }
}
