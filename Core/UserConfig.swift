//
//  UserConfig.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import SwiftUI

enum SyncMode: String, CaseIterable, Codable {
    case auto = "Auto"
    case manual = "Manual"
}

enum AudioPlaybackMode: String, CaseIterable, Codable {
    case interrupt = "interrupt"
    case duck = "duck"
    case mix = "mix"
}

enum Themes: String, CaseIterable, Codable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    case sepia = "Sepia"
    case custom = "Custom"

    var colorScheme: ColorScheme? {
        switch self {
        case .light: .light
        case .dark: .dark
        case .sepia: .light
        default: nil
        }
    }
}

@Observable
class UserConfig {
    var bookshelfSortOption: SortOption {
        didSet { UserDefaults.standard.set(bookshelfSortOption.rawValue, forKey: "bookshelfSortOption") }
    }
    
    var bookshelfShowReading: Bool {
        didSet { UserDefaults.standard.set(bookshelfShowReading, forKey: "bookshelfShowReading") }
    }
    
    var dictionaryTabDefault: Bool {
        didSet { UserDefaults.standard.set(dictionaryTabDefault, forKey: "dictionaryTabDefault") }
    }
    
    var maxResults: Int {
        didSet { UserDefaults.standard.set(maxResults, forKey: "maxResults") }
    }
    
    var scanLength: Int {
        didSet { UserDefaults.standard.set(scanLength, forKey: "scanLength") }
    }
    
    var collapseDictionaries: Bool {
        didSet { UserDefaults.standard.set(collapseDictionaries, forKey: "collapseDictionaries") }
    }
    
    var compactGlossaries: Bool {
        didSet { UserDefaults.standard.set(compactGlossaries, forKey: "compactGlossaries") }
    }
    
    var showExpressionTags: Bool {
        didSet { UserDefaults.standard.set(showExpressionTags, forKey: "showExpressionTags") }
    }
    
    var harmonicFrequency: Bool {
        didSet { UserDefaults.standard.set(harmonicFrequency, forKey: "harmonicFrequency") }
    }
    
    var deduplicatePitchAccents: Bool {
        didSet { UserDefaults.standard.set(deduplicatePitchAccents, forKey: "deduplicatePitchAccents") }
    }
    
    var enableSync: Bool {
        didSet { UserDefaults.standard.set(enableSync, forKey: "enableSync") }
    }
    
    var syncMode: SyncMode {
        didSet { UserDefaults.standard.set(syncMode.rawValue, forKey: "syncMode") }
    }
    
    var enableAutoSync: Bool {
        didSet { UserDefaults.standard.set(enableAutoSync, forKey: "enableAutoSync") }
    }
    
    var googleClientId: String {
        didSet { UserDefaults.standard.set(googleClientId, forKey: "googleClientId") }
    }
    
    var theme: Themes {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "theme"); ReaderPreferencesStore.shared.localDidChange(self) }
    }
    
    var uiTheme: Themes {
        didSet { UserDefaults.standard.set(uiTheme.rawValue, forKey: "uiTheme"); ReaderPreferencesStore.shared.localDidChange(self) }
    }
    
    var systemLightSepia: Bool {
        didSet { UserDefaults.standard.set(systemLightSepia, forKey: "systemLightSepia"); ReaderPreferencesStore.shared.localDidChange(self) }
    }
    
    var sepiaInvertInDark: Bool {
        didSet { UserDefaults.standard.set(sepiaInvertInDark, forKey: "sepiaInvertInDark"); ReaderPreferencesStore.shared.localDidChange(self) }
    }
    
    var customBackgroundColor: Color {
        didSet { Self.saveColor(customBackgroundColor, key: "customBackgroundColor"); ReaderPreferencesStore.shared.localDidChange(self) }
    }
    
    var customTextColor: Color {
        didSet { Self.saveColor(customTextColor, key: "customTextColor"); ReaderPreferencesStore.shared.localDidChange(self) }
    }
    
    var customInfoColor: Color {
        didSet { Self.saveColor(customInfoColor, key: "customInfoColor"); ReaderPreferencesStore.shared.localDidChange(self) }
    }
    
    var verticalWriting: Bool {
        didSet { UserDefaults.standard.set(verticalWriting, forKey: "verticalWriting"); ReaderPreferencesStore.shared.localDidChange(self) }
    }
    
    var selectedFont: String {
        didSet { UserDefaults.standard.set(selectedFont, forKey: "selectedFont"); ReaderPreferencesStore.shared.localDidChange(self) }
    }
    
    var fontSize: Int {
        didSet { UserDefaults.standard.set(fontSize, forKey: "fontSize"); ReaderPreferencesStore.shared.localDidChange(self) }
    }
    
    var readerHideFurigana: Bool {
        didSet { UserDefaults.standard.set(readerHideFurigana, forKey: "readerHideFurigana"); ReaderPreferencesStore.shared.localDidChange(self) }
    }
    
    /// Show a translate button after every pre-translated sentence. Only has an effect on a book
    /// whose `sentence_translations.json` has been synced down.
    var readerShowSentenceTranslations: Bool {
        didSet { UserDefaults.standard.set(readerShowSentenceTranslations, forKey: "readerShowSentenceTranslations"); ReaderPreferencesStore.shared.localDidChange(self) }
    }

    var continuousMode: Bool {
        didSet { UserDefaults.standard.set(continuousMode, forKey: "continuousMode"); ReaderPreferencesStore.shared.localDidChange(self) }
    }
    
    var chapterSwipeDistance: Int {
        didSet { UserDefaults.standard.set(chapterSwipeDistance, forKey: "chapterSwipeDistance"); ReaderPreferencesStore.shared.localDidChange(self) }
    }
    
    var horizontalPadding: Int {
        didSet { UserDefaults.standard.set(horizontalPadding, forKey: "layoutHorizontalPadding"); ReaderPreferencesStore.shared.localDidChange(self) }
    }
    
    var verticalPadding: Int {
        didSet { UserDefaults.standard.set(verticalPadding, forKey: "layoutVerticalPadding"); ReaderPreferencesStore.shared.localDidChange(self) }
    }
    
    var avoidPageBreak: Bool {
        didSet { UserDefaults.standard.set(avoidPageBreak, forKey: "avoidPageBreak"); ReaderPreferencesStore.shared.localDidChange(self) }
    }
    
    var justifyText: Bool {
        didSet { UserDefaults.standard.set(justifyText, forKey: "justifyText"); ReaderPreferencesStore.shared.localDidChange(self) }
    }
    
    var blurImages: Bool {
        didSet { UserDefaults.standard.set(blurImages, forKey: "blurImages"); ReaderPreferencesStore.shared.localDidChange(self) }
    }
    
    var layoutAdvanced: Bool {
        didSet { UserDefaults.standard.set(layoutAdvanced, forKey: "layoutAdvanced"); ReaderPreferencesStore.shared.localDidChange(self) }
    }
    
    var lineHeight: Double {
        didSet { UserDefaults.standard.set(lineHeight, forKey: "lineHeight"); ReaderPreferencesStore.shared.localDidChange(self) }
    }
    
    var characterSpacing: Double {
        didSet { UserDefaults.standard.set(characterSpacing, forKey: "characterSpacing"); ReaderPreferencesStore.shared.localDidChange(self) }
    }
    
    var readerShowTitle: Bool {
        didSet { UserDefaults.standard.set(readerShowTitle, forKey: "readerShowTitle"); ReaderPreferencesStore.shared.localDidChange(self) }
    }
    
    var readerShowCharacters: Bool {
        didSet { UserDefaults.standard.set(readerShowCharacters, forKey: "readerShowCharacters"); ReaderPreferencesStore.shared.localDidChange(self) }
    }
    
    var readerShowPercentage: Bool {
        didSet { UserDefaults.standard.set(readerShowPercentage, forKey: "readerShowPercentage"); ReaderPreferencesStore.shared.localDidChange(self) }
    }
    
    var readerShowProgressTop: Bool {
        didSet { UserDefaults.standard.set(readerShowProgressTop, forKey: "readerShowProgressTop"); ReaderPreferencesStore.shared.localDidChange(self) }
    }
    
    var readerShowStatisticsToggle: Bool {
        didSet { UserDefaults.standard.set(readerShowStatisticsToggle, forKey: "readerShowStatisticsToggle"); ReaderPreferencesStore.shared.localDidChange(self) }
    }
    
    var readerShowReadingSpeed: Bool {
        didSet { UserDefaults.standard.set(readerShowReadingSpeed, forKey: "readerShowReadingSpeed"); ReaderPreferencesStore.shared.localDidChange(self) }
    }
    
    var readerShowReadingTime: Bool {
        didSet { UserDefaults.standard.set(readerShowReadingTime, forKey: "readerShowReadingTime"); ReaderPreferencesStore.shared.localDidChange(self) }
    }
    
    var readerShowSasayakiToggle: Bool {
        didSet { UserDefaults.standard.set(readerShowSasayakiToggle, forKey: "readerShowSasayakiToggle"); ReaderPreferencesStore.shared.localDidChange(self) }
    }
    
    var disablePageTurnAnimation: Bool {
        didSet { UserDefaults.standard.set(disablePageTurnAnimation, forKey: "disablePageTurnAnimation"); ReaderPreferencesStore.shared.localDidChange(self) }
    }

    var keepScreenOnWhileReading: Bool {
        didSet {
            UserDefaults.standard.set(keepScreenOnWhileReading, forKey: ScreenAwake.settingKey)
            ReaderPreferencesStore.shared.localDidChange(self)
            ScreenAwake.settingChanged()
        }
    }

    var mangaShowFurigana: Bool {
        didSet { UserDefaults.standard.set(mangaShowFurigana, forKey: "mangaShowFurigana"); ReaderPreferencesStore.shared.localDidChange(self) }
    }

    var mangaSingleTapLookup: Bool {
        didSet { UserDefaults.standard.set(mangaSingleTapLookup, forKey: "mangaSingleTapLookup"); ReaderPreferencesStore.shared.localDidChange(self) }
    }

    var mangaUseNotoSansJpFont: Bool {
        didSet { UserDefaults.standard.set(mangaUseNotoSansJpFont, forKey: "mangaUseNotoSansJpFont"); ReaderPreferencesStore.shared.localDidChange(self) }
    }

    var mangaScanNonJapaneseText: Bool {
        didSet { UserDefaults.standard.set(mangaScanNonJapaneseText, forKey: "mangaScanNonJapaneseText") }
    }

    var mangaEnlargeSmallText: Bool {
        didSet { UserDefaults.standard.set(mangaEnlargeSmallText, forKey: "mangaEnlargeSmallText"); ReaderPreferencesStore.shared.localDidChange(self) }
    }
    var mangaShowCopyButton: Bool {
        didSet { UserDefaults.standard.set(mangaShowCopyButton, forKey: "mangaShowCopyButton"); ReaderPreferencesStore.shared.localDidChange(self) }
    }
    var mangaShowActionButtons: Bool {
        didSet { UserDefaults.standard.set(mangaShowActionButtons, forKey: "mangaShowActionButtons") }
    }

    var dictionaryCard: PopupCardStyle {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(dictionaryCard.normalized), forKey: "dictionaryCardStyle"); ReaderPreferencesStore.shared.localDidChange(self) }
    }
    var translationCard: PopupCardStyle {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(translationCard.normalized), forKey: "translationCardStyle"); ReaderPreferencesStore.shared.localDidChange(self) }
    }

    var popupWidth: Int {
        didSet { UserDefaults.standard.set(popupWidth, forKey: "popupWidth"); ReaderPreferencesStore.shared.localDidChange(self) }
    }
    
    var popupHeight: Int {
        didSet { UserDefaults.standard.set(popupHeight, forKey: "popupHeight"); ReaderPreferencesStore.shared.localDidChange(self) }
    }
    
    var popupFullWidth: Bool {
        didSet { UserDefaults.standard.set(popupFullWidth, forKey: "popupFullWidth"); ReaderPreferencesStore.shared.localDidChange(self) }
    }
    
    var popupSwipeToDismiss: Bool {
        didSet { UserDefaults.standard.set(popupSwipeToDismiss, forKey: "popupSwipeToDismiss"); ReaderPreferencesStore.shared.localDidChange(self) }
    }
    
    var popupSwipeThreshold: Int {
        didSet { UserDefaults.standard.set(popupSwipeThreshold, forKey: "popupSwipeThreshold"); ReaderPreferencesStore.shared.localDidChange(self) }
    }
    
    var audioSources: [AudioSource] {
        didSet {
            if let data = try? JSONEncoder().encode(audioSources) {
                UserDefaults.standard.set(data, forKey: "audioSources")
            }
        }
    }
    
    var enableLocalAudio: Bool {
        didSet {
            UserDefaults.standard.set(enableLocalAudio, forKey: "enableLocalAudio")
            if enableLocalAudio {
                audioSources.insert(UserConfig.localAudioSource, at: 0)
            } else {
                audioSources.removeAll { $0.url == LocalFileServer.localAudioURL }
            }
        }
    }
    
    var audioEnableAutoplay: Bool {
        didSet { UserDefaults.standard.set(audioEnableAutoplay, forKey: "audioEnableAutoplay") }
    }
    
    var audioPlaybackMode: AudioPlaybackMode {
        didSet { UserDefaults.standard.set(audioPlaybackMode.rawValue, forKey: "audioPlaybackMode") }
    }
    
    var enabledAudioSources: [String] {
        audioSources.filter { $0.isEnabled }.map { $0.url }
    }
    
    static let localAudioSource = AudioSource(
        name: "Local",
        url: LocalFileServer.localAudioURL,
        isEnabled: true
    )
    
    static let defaultAudioSource = AudioSource(
        name: "Default",
        url: "https://hoshi-reader.manhhaoo-do.workers.dev/?term={term}&reading={reading}",
        isEnabled: true,
        isDefault: true
    )
    
    var customCSS: String {
        didSet { UserDefaults.standard.set(customCSS, forKey: "customCSS") }
    }
    
    var enableStatistics: Bool {
        didSet { UserDefaults.standard.set(enableStatistics, forKey: "enableStatistics") }
    }
    
    var statisticsEnableSync: Bool {
        didSet { UserDefaults.standard.set(statisticsEnableSync, forKey: "statisticsEnableSync") }
    }
    
    var statisticsSyncMode: StatisticsSyncMode {
        didSet { UserDefaults.standard.set(statisticsSyncMode.rawValue, forKey: "statisticsSyncMode") }
    }
    
    var statisticsAutostartMode: StatisticsAutostartMode {
        didSet { UserDefaults.standard.set(statisticsAutostartMode.rawValue, forKey: "statisticsAutostartMode") }
    }
    
    var enableSasayaki: Bool {
        didSet { UserDefaults.standard.set(enableSasayaki, forKey: "enableSasayaki"); ReaderPreferencesStore.shared.localDidChange(self) }
    }
    
    var sasayakiAutoScroll: Bool {
        didSet { UserDefaults.standard.set(sasayakiAutoScroll, forKey: "sasayakiAutoScroll"); ReaderPreferencesStore.shared.localDidChange(self) }
    }
    
    var sasayakiAutoPause: Bool {
        didSet { UserDefaults.standard.set(sasayakiAutoPause, forKey: "sasayakiAutoPause"); ReaderPreferencesStore.shared.localDidChange(self) }
    }
    
    var sasayakiEnableSync: Bool {
        didSet { UserDefaults.standard.set(sasayakiEnableSync, forKey: "sasayakiEnableSync") }
    }
    
    var sasayakiTextColor: Color {
        didSet { Self.saveColor(sasayakiTextColor, key: "sasayakiTextColor"); ReaderPreferencesStore.shared.localDidChange(self) }
    }
    
    var sasayakiBackgroundColor: Color {
        didSet { Self.saveColor(sasayakiBackgroundColor, key: "sasayakiBackgroundColor"); ReaderPreferencesStore.shared.localDidChange(self) }
    }
    
    var sasayakiDarkTextColor: Color {
        didSet { Self.saveColor(sasayakiDarkTextColor, key: "sasayakiDarkTextColor"); ReaderPreferencesStore.shared.localDidChange(self) }
    }
    
    var sasayakiDarkBackgroundColor: Color {
        didSet { Self.saveColor(sasayakiDarkBackgroundColor, key: "sasayakiDarkBackgroundColor"); ReaderPreferencesStore.shared.localDidChange(self) }
    }
    
    init() {
        let defaults = UserDefaults.standard
        
        self.bookshelfSortOption = defaults.string(forKey: "bookshelfSortOption")
            .flatMap(SortOption.init) ?? .recent
        self.bookshelfShowReading = defaults.object(forKey: "bookshelfShowReading") as? Bool ?? false
        
        self.dictionaryTabDefault = defaults.object(forKey: "dictionaryTabDefault") as? Bool ?? false
        self.maxResults = defaults.object(forKey: "maxResults") as? Int ?? 16
        self.scanLength = defaults.object(forKey: "scanLength") as? Int ?? 16
        self.collapseDictionaries = defaults.object(forKey: "collapseDictionaries") as? Bool ?? false
        self.compactGlossaries = defaults.object(forKey: "compactGlossaries") as? Bool ?? true
        self.showExpressionTags = defaults.object(forKey: "showExpressionTags") as? Bool ?? false
        self.harmonicFrequency = defaults.object(forKey: "harmonicFrequency") as? Bool ?? false
        self.deduplicatePitchAccents = defaults.object(forKey: "deduplicatePitchAccents") as? Bool ?? false
        
        self.enableSync = defaults.object(forKey: "enableSync") as? Bool ?? false
        self.syncMode = defaults.string(forKey: "syncMode")
            .flatMap(SyncMode.init) ?? .auto
        self.enableAutoSync = defaults.object(forKey: "enableAutoSync") as? Bool ?? false
        self.googleClientId = defaults.object(forKey: "googleClientId") as? String ?? ""
        
        self.theme = defaults.string(forKey: "theme")
            .flatMap(Themes.init) ?? .system
        self.uiTheme = defaults.string(forKey: "uiTheme")
            .flatMap(Themes.init) ?? .system
        self.systemLightSepia = defaults.object(forKey: "systemLightSepia") as? Bool ?? false
        self.sepiaInvertInDark = defaults.object(forKey: "sepiaInvertInDark") as? Bool ?? false
        self.customBackgroundColor = UserConfig.loadColor(key: "customBackgroundColor") ?? Color(.sRGB, red: 1, green: 1, blue: 1)
        self.customTextColor = UserConfig.loadColor(key: "customTextColor") ?? Color(.sRGB, red: 0, green: 0, blue: 0)
        self.customInfoColor = UserConfig.loadColor(key: "customInfoColor") ?? Color(.sRGB, red: 0.6, green: 0.6, blue: 0.6)
        
        self.verticalWriting = defaults.object(forKey: "verticalWriting") as? Bool ?? true
        self.selectedFont = defaults.string(forKey: "selectedFont") ?? "Hiragino Mincho ProN"
        self.fontSize = defaults.object(forKey: "fontSize") as? Int ?? 22
        self.readerHideFurigana = defaults.object(forKey: "readerHideFurigana") as? Bool ?? false
        self.readerShowSentenceTranslations = defaults.object(forKey: "readerShowSentenceTranslations") as? Bool ?? true
        
        self.continuousMode = defaults.object(forKey: "continuousMode") as? Bool ?? false
        self.chapterSwipeDistance = defaults.object(forKey: "chapterSwipeDistance") as? Int ?? 20
        self.horizontalPadding = defaults.object(forKey: "layoutHorizontalPadding") as? Int ?? 5
        self.verticalPadding = defaults.object(forKey: "layoutVerticalPadding") as? Int ?? 0
        self.avoidPageBreak = defaults.object(forKey: "avoidPageBreak") as? Bool ?? false
        self.justifyText = defaults.object(forKey: "justifyText") as? Bool ?? false
        self.blurImages = defaults.object(forKey: "blurImages") as? Bool ?? false
        self.layoutAdvanced = defaults.object(forKey: "layoutAdvanced") as? Bool ?? false
        self.lineHeight = defaults.object(forKey: "lineHeight") as? Double ?? 1.65
        self.characterSpacing = defaults.object(forKey: "characterSpacing") as? Double ?? 0
        
        self.readerShowTitle = defaults.object(forKey: "readerShowTitle") as? Bool ?? true
        self.readerShowCharacters = defaults.object(forKey: "readerShowCharacters") as? Bool ?? true
        self.readerShowPercentage = defaults.object(forKey: "readerShowPercentage") as? Bool ?? true
        self.readerShowProgressTop = defaults.object(forKey: "readerShowProgressTop") as? Bool ?? true
        self.readerShowStatisticsToggle = defaults.object(forKey: "readerShowStatisticsToggle") as? Bool ?? false
        self.readerShowReadingSpeed = defaults.object(forKey: "readerShowReadingSpeed") as? Bool ?? false
        self.readerShowReadingTime = defaults.object(forKey: "readerShowReadingTime") as? Bool ?? false
        self.readerShowSasayakiToggle = defaults.object(forKey: "readerShowSasayakiToggle") as? Bool ?? false
        
        self.disablePageTurnAnimation = defaults.object(forKey: "disablePageTurnAnimation") as? Bool ?? false
        self.keepScreenOnWhileReading = defaults.object(forKey: ScreenAwake.settingKey) as? Bool ?? false
        self.mangaShowFurigana = defaults.object(forKey: "mangaShowFurigana") as? Bool ?? true
        self.mangaSingleTapLookup = defaults.object(forKey: "mangaSingleTapLookup") as? Bool ?? false
        self.mangaUseNotoSansJpFont = defaults.object(forKey: "mangaUseNotoSansJpFont") as? Bool ?? false
        self.mangaScanNonJapaneseText = defaults.object(forKey: "mangaScanNonJapaneseText") as? Bool ?? false
        self.mangaEnlargeSmallText = defaults.object(forKey: "mangaEnlargeSmallText") as? Bool ?? true
        self.mangaShowCopyButton = defaults.bool(forKey: "mangaShowCopyButton")
        self.mangaShowActionButtons = defaults.object(forKey: "mangaShowActionButtons") as? Bool ?? true

        self.dictionaryCard = defaults.data(forKey: "dictionaryCardStyle").flatMap { try? JSONDecoder().decode(PopupCardStyle.self, from: $0) }?.normalized ?? .init()
        self.translationCard = defaults.data(forKey: "translationCardStyle").flatMap { try? JSONDecoder().decode(PopupCardStyle.self, from: $0) }?.normalized ?? .init()
        self.popupWidth = defaults.object(forKey: "popupWidth") as? Int ?? 240
        self.popupHeight = defaults.object(forKey: "popupHeight") as? Int ?? 170
        self.popupFullWidth = defaults.object(forKey: "popupFullWidth") as? Bool ?? false
        self.popupSwipeToDismiss = defaults.object(forKey: "popupSwipeToDismiss") as? Bool ?? false
        self.popupSwipeThreshold = min(60, max(20, defaults.object(forKey: "popupSwipeThreshold") as? Int ?? 40))
        
        if let data = defaults.data(forKey: "audioSources"),
           let sources = try? JSONDecoder().decode([AudioSource].self, from: data) {
            self.audioSources = sources
        } else {
            self.audioSources = [UserConfig.defaultAudioSource]
        }
        self.enableLocalAudio = defaults.object(forKey: "enableLocalAudio") as? Bool ?? false
        self.audioEnableAutoplay = defaults.object(forKey: "audioEnableAutoplay") as? Bool ?? false
        self.audioPlaybackMode = defaults.string(forKey: "audioPlaybackMode")
            .flatMap(AudioPlaybackMode.init) ?? .interrupt
        self.customCSS = defaults.string(forKey: "customCSS") ?? ""
        
        self.enableStatistics = true
        self.statisticsEnableSync = defaults.object(forKey: "statisticsEnableSync") as? Bool ?? false
        self.statisticsSyncMode = defaults.string(forKey: "statisticsSyncMode")
            .flatMap(StatisticsSyncMode.init) ?? .merge
        self.statisticsAutostartMode = .on
        
        self.enableSasayaki = defaults.object(forKey: "enableSasayaki") as? Bool ?? false
        self.sasayakiAutoScroll = defaults.object(forKey: "sasayakiAutoScroll") as? Bool ?? true
        self.sasayakiAutoPause = defaults.object(forKey: "sasayakiAutoPause") as? Bool ?? true
        self.sasayakiEnableSync = defaults.object(forKey: "sasayakiEnableSync") as? Bool ?? false
        self.sasayakiTextColor = UserConfig.loadColor(key: "sasayakiTextColor") ?? Color(.sRGB, red: 0, green: 0, blue: 0)
        self.sasayakiBackgroundColor = UserConfig.loadColor(key: "sasayakiBackgroundColor") ?? Color(.sRGB, red: 0.53, green: 0.81, blue: 0.98, opacity: 0.4)
        self.sasayakiDarkTextColor = UserConfig.loadColor(key: "sasayakiDarkTextColor") ?? Color(.sRGB, red: 1, green: 1, blue: 1)
        self.sasayakiDarkBackgroundColor = UserConfig.loadColor(key: "sasayakiDarkBackgroundColor") ?? Color(.sRGB, red: 0.53, green: 0.81, blue: 0.98, opacity: 0.4)
        ReaderPreferencesStore.shared.attach(self)
    }
    
    private static func saveColor(_ color: Color, key: String) {
        let uiColor = UIColor(color)
        let colorData = try? NSKeyedArchiver.archivedData(withRootObject: uiColor, requiringSecureCoding: false)
        UserDefaults.standard.set(colorData, forKey: key)
    }
    
    private static func loadColor(key: String) -> Color? {
        guard let colorData = UserDefaults.standard.data(forKey: key) else {
            return nil
        }
        if let uiColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: UIColor.self, from: colorData) {
            return Color(uiColor)
        }
        return nil
    }
}
