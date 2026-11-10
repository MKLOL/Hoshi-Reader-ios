import Foundation
import SwiftUI
import UIKit

@MainActor
protocol ReaderPreferencesSyncing: AnyObject {
    var deviceId: String { get }
    func snapshot() throws -> [String: ReaderPreferenceRecord]
    func merge(_ records: [String: ReaderPreferenceRecord]) throws -> Bool
}

/// The journal stores values and clocks together. Replaying it before displaying settings
/// recovers a process interruption between publishing the journal and updating UserDefaults.
@MainActor
final class ReaderPreferencesStore: ReaderPreferencesSyncing {
    static let shared = ReaderPreferencesStore()
    private let defaults: UserDefaults
    private let journalKey = "readerPreferencesJournal.v1"
    private weak var config: UserConfig?
    private var applying = false
    private var records: [String: ReaderPreferenceRecord] = [:]
    private var readError: Error?
    private var lastValues: [String: ReaderPreferenceValue] = [:]
    let deviceId: String

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let id = defaults.string(forKey: "readerPreferencesDeviceId"), ReaderPreferencesProtocol.validDevice(id) {
            deviceId = id
        } else {
            deviceId = UUID().uuidString.lowercased()
            defaults.set(deviceId, forKey: "readerPreferencesDeviceId")
        }
        #if DEBUG
        // UI tests choose preferences with launch arguments; an earlier launch's journal must not
        // override them.
        if HoshiAutomation.fixtureEnvironment["HOSHI_UI_TESTING"] == "1" { defaults.removeObject(forKey: journalKey) }
        #endif
        if let data = defaults.data(forKey: journalKey) {
            do {
                records = try JSONDecoder().decode([String: ReaderPreferenceRecord].self, from: data)
                try ReaderPreferencesProtocol.validate(records)
            } catch { readError = error }
        }
    }

    #if DEBUG
    /// Forgets every recorded preference, as on a new installation, so the next attached
    /// configuration starts from its stored values. Tests use it to start from known defaults.
    func reset() {
        config = nil; records = [:]; lastValues = [:]; readError = nil
        defaults.removeObject(forKey: journalKey)
    }
    #endif

    func attach(_ config: UserConfig) {
        self.config = config
        guard readError == nil else { return }
        applying = true
        for (name, record) in records { Self.fields[name]?.write(config, record.value) }
        applying = false
        lastValues = values(config)
        // Existing choices enter below all explicit edits. Untouched platform defaults stay
        // absent, so installing iOS cannot reset preferences already chosen on Android.
        for (name, field) in Self.fields where records[name] == nil {
            let value = field.read(config)
            if value != field.defaultValue, ReaderPreferencesProtocol.validValue(value, name: name) {
                records[name] = .init(value: value, editedAt: 0, deviceId: deviceId)
            }
        }
        try? persist()
    }

    func localDidChange(_ config: UserConfig) {
        guard self.config === config, !applying, readError == nil else { return }
        let current = values(config)
        var changed = false
        let clock = max(Int64(Date().timeIntervalSince1970 * 1000), (records.values.map(\.editedAt).max() ?? 0) + 1)
        guard clock <= ReaderPreferencesProtocol.maxTimestamp else { return }
        for (name, value) in current where value != lastValues[name] {
            guard ReaderPreferencesProtocol.validValue(value, name: name) else { continue }
            records[name] = .init(value: value, editedAt: clock, deviceId: deviceId)
            changed = true
        }
        lastValues = current
        if changed {
            do { try persist(); HttpSyncManager.shared.onReaderPreferencesChanged() }
            catch { readError = error }
        }
    }

    func snapshot() throws -> [String: ReaderPreferenceRecord] {
        if let readError { throw readError }
        try ReaderPreferencesProtocol.validate(records)
        return records
    }

    func merge(_ incoming: [String: ReaderPreferenceRecord]) throws -> Bool {
        if let readError { throw readError }
        try ReaderPreferencesProtocol.validate(incoming)
        guard Set(records.keys).union(incoming.keys).count <= 256 else { throw HttpSyncError("Too many reader preferences.") }
        var merged = records
        for (name, record) in incoming where record.isNewer(than: merged[name]) { merged[name] = record }
        guard merged != records else { return false }
        let data = try JSONEncoder().encode(merged)
        defaults.set(data, forKey: journalKey)
        records = merged
        if let config {
            applying = true
            defer { applying = false }
            for (name, record) in records { Self.fields[name]?.write(config, record.value) }
            lastValues = values(config)
        }
        return true
    }

    private func persist() throws { defaults.set(try JSONEncoder().encode(records), forKey: journalKey) }
    private func values(_ config: UserConfig) -> [String: ReaderPreferenceValue] { Self.fields.mapValues { $0.read(config) } }

    private struct Field {
        let defaultValue: ReaderPreferenceValue
        let read: (UserConfig) -> ReaderPreferenceValue
        let write: (UserConfig, ReaderPreferenceValue) -> Void
    }

    private static let fields: [String: Field] = {
        var fields: [String: Field] = [:]
        @MainActor func boolean(_ name: String, _ key: ReferenceWritableKeyPath<UserConfig, Bool>, _ initial: Bool) {
            fields[name] = Field(defaultValue: .bool(initial), read: { .bool($0[keyPath: key]) },
                write: { c, v in if case .bool(let b) = v { c[keyPath: key] = b } })
        }
        @MainActor func integer(_ name: String, _ key: ReferenceWritableKeyPath<UserConfig, Int>, _ initial: Int) {
            fields[name] = Field(defaultValue: .number(Double(initial)), read: { .number(Double($0[keyPath: key])) },
                write: { c, v in if case .number(let n) = v { c[keyPath: key] = Int(n) } })
        }
        @MainActor func decimal(_ name: String, _ key: ReferenceWritableKeyPath<UserConfig, Double>, _ initial: Double) {
            fields[name] = Field(defaultValue: .number(initial), read: { .number($0[keyPath: key]) },
                write: { c, v in if case .number(let n) = v { c[keyPath: key] = n } })
        }
        boolean("disablePageTurnAnimation", \.disablePageTurnAnimation, false)
        boolean("keepScreenOnWhileReading", \.keepScreenOnWhileReading, false)
        boolean("systemLightSepia", \.systemLightSepia, false)
        boolean("sepiaInvertInDark", \.sepiaInvertInDark, false)
        boolean("verticalWriting", \.verticalWriting, true)
        boolean("hideFurigana", \.readerHideFurigana, false)
        boolean("showSentenceTranslations", \.readerShowSentenceTranslations, true)
        boolean("continuousMode", \.continuousMode, false)
        boolean("showStatisticsToggle", \.readerShowStatisticsToggle, false)
        boolean("showReadingSpeed", \.readerShowReadingSpeed, false)
        boolean("showReadingTime", \.readerShowReadingTime, false)
        boolean("avoidPageBreak", \.avoidPageBreak, false)
        boolean("justifyText", \.justifyText, false)
        boolean("layoutAdvanced", \.layoutAdvanced, false)
        boolean("showTitle", \.readerShowTitle, true)
        boolean("showCharacters", \.readerShowCharacters, true)
        boolean("showPercentage", \.readerShowPercentage, true)
        boolean("showProgressTop", \.readerShowProgressTop, true)
        boolean("popupFullWidth", \.popupFullWidth, false)
        boolean("popupSwipeToDismiss", \.popupSwipeToDismiss, false)
        boolean("mangaSingleTapLookup", \.mangaSingleTapLookup, false)
        boolean("mangaUseNotoSansJp", \.mangaUseNotoSansJpFont, false)
        boolean("mangaShowCopyButton", \.mangaShowCopyButton, false)
        boolean("mangaEnlargeSmallText", \.mangaEnlargeSmallText, true)
        boolean("mangaShowFurigana", \.mangaShowFurigana, true)
        boolean("sasayaki.enabled", \.enableSasayaki, false)
        boolean("sasayaki.showReaderToggle", \.readerShowSasayakiToggle, false)
        boolean("sasayaki.autoScroll", \.sasayakiAutoScroll, true)
        boolean("sasayaki.autoPause", \.sasayakiAutoPause, true)
        integer("fontSize", \.fontSize, 22)
        integer("chapterSwipeDistance", \.chapterSwipeDistance, 20)
        integer("horizontalPadding", \.horizontalPadding, 5)
        integer("verticalPadding", \.verticalPadding, 0)
        integer("popupWidth", \.popupWidth, 240)
        integer("popupHeight", \.popupHeight, 170)
        integer("popupSwipeThreshold", \.popupSwipeThreshold, 40)
        decimal("lineHeight", \.lineHeight, 1.65)
        decimal("characterSpacing", \.characterSpacing, 0)
        for (name, key) in [("theme", \UserConfig.theme), ("uiTheme", \UserConfig.uiTheme)] {
            fields[name] = Field(defaultValue: .string("System"), read: { .string($0[keyPath: key].rawValue) },
                write: { c, v in if case .string(let raw) = v, let theme = Themes(rawValue: raw) { c[keyPath: key] = theme } })
        }
        fields["selectedFont"] = Field(defaultValue: .string("Hiragino Mincho ProN"), read: { .string($0.selectedFont) },
            write: { c, v in if case .string(let name) = v {
                c.selectedFont = name == "Noto Serif CJK JP" ? "Hiragino Mincho ProN" : name == "Noto Sans CJK JP" ? "Hiragino Kaku Gothic ProN" : name
            } })
        @MainActor func argb(_ color: Color) -> Double {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return 0 }
            func byte(_ value: CGFloat) -> UInt32 { value.isFinite ? UInt32((min(1, max(0, value)) * 255).rounded()) : 0 }
            return Double((byte(a) << 24) | (byte(r) << 16) | (byte(g) << 8) | byte(b))
        }
        let colors: [(String, ReferenceWritableKeyPath<UserConfig, Color>, Double)] = [
            ("customBackgroundColor", \.customBackgroundColor, 0xFFFFFFFF), ("customTextColor", \.customTextColor, 0xFF000000),
            ("customInfoColor", \.customInfoColor, 0xFF999999), ("sasayaki.lightTextColor", \.sasayakiTextColor, 0xFF000000),
            ("sasayaki.lightBackgroundColor", \.sasayakiBackgroundColor, 0x6687CFFA),
            ("sasayaki.darkTextColor", \.sasayakiDarkTextColor, 0xFFFFFFFF),
            ("sasayaki.darkBackgroundColor", \.sasayakiDarkBackgroundColor, 0x6687CFFA)]
        for (name, key, initial) in colors {
            fields[name] = Field(defaultValue: .number(initial), read: { .number(argb($0[keyPath: key])) }, write: { c, v in
                if case .number(let n) = v {
                    let x = UInt32(n)
                    c[keyPath: key] = Color(.sRGB, red: Double((x >> 16) & 255) / 255,
                        green: Double((x >> 8) & 255) / 255, blue: Double(x & 255) / 255, opacity: Double((x >> 24) & 255) / 255)
                }
            })
        }
        for (name, card) in [("dictionaryCard", \UserConfig.dictionaryCard), ("translationCard", \UserConfig.translationCard)] {
            for (part, key) in [("width", \PopupCardStyle.width), ("height", \PopupCardStyle.height), ("scale", \PopupCardStyle.scale), ("fontScale", \PopupCardStyle.fontScale)] {
                fields[name + "." + part] = Field(defaultValue: .null,
                    read: { $0[keyPath: card][keyPath: key].map(ReaderPreferenceValue.number) ?? .null },
                    write: { c, v in
                        var style = c[keyPath: card]
                        if case .number(let n) = v { style[keyPath: key] = n } else { style[keyPath: key] = nil }
                        c[keyPath: card] = style
                    })
            }
        }
        return fields
    }()
}
