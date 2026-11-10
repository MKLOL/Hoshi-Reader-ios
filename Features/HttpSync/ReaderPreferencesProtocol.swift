import Foundation

/// Android's typed JSON values. Keeping booleans distinct from numbers prevents a malformed
/// shard from quietly turning a toggle into a numeric preference (or the reverse).
nonisolated indirect enum ReaderPreferenceValue: Codable, Equatable, Sendable {
    case bool(Bool), number(Double), string(String), null
    case array([ReaderPreferenceValue]), object([String: ReaderPreferenceValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Double.self), value.isFinite { self = .number(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([ReaderPreferenceValue].self) { self = .array(value) }
        else { self = .object(try c.decode([String: ReaderPreferenceValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        case .null: try c.encodeNil()
        case .array(let value): try c.encode(value)
        case .object(let value): try c.encode(value)
        }
    }
}

nonisolated struct ReaderPreferenceRecord: Codable, Equatable, Sendable {
    var value: ReaderPreferenceValue
    var editedAt: Int64
    var deviceId: String

    func isNewer(than old: Self?) -> Bool {
        guard let old else { return true }
        return editedAt > old.editedAt || (editedAt == old.editedAt && deviceId > old.deviceId)
    }
}

nonisolated struct ReaderPreferencesBlob: Codable, Equatable, Sendable {
    var version: Int = 1
    var deviceId: String
    var records: [String: ReaderPreferenceRecord]
    enum CodingKeys: String, CodingKey { case version, deviceId, records }
    init(deviceId: String, records: [String: ReaderPreferenceRecord], version: Int = 1) {
        self.version = version; self.deviceId = deviceId; self.records = records
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        deviceId = try c.decode(String.self, forKey: .deviceId)
        records = try c.decodeIfPresent([String: ReaderPreferenceRecord].self, forKey: .records) ?? [:]
    }
}

nonisolated enum ReaderPreferencesProtocol {
    static let prefix = "app/reader_settings/"
    static let maxTimestamp: Int64 = 253402300799999
    static let maxBody = 64 * 1024

    static func validDevice(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil
    }

    static func validate(_ records: [String: ReaderPreferenceRecord], now: Date = Date()) throws {
        let forbidden: Set<String> = ["statisticsSyncEnabled", "statisticsSyncMode",
            "statisticsStreakMinimumMinutes", "statisticsDayResetHour", "statisticsSettingsUpdatedAt",
            "statisticsTimeZone", "sasayaki.syncEnabled", "sasayaki.copyAudiobookToPrivateStorage"]
        guard records.count <= 256 else { throw HttpSyncError("Too many reader preferences.") }
        let latest = min(maxTimestamp, Int64(now.timeIntervalSince1970 * 1000) + 86_400_000)
        for (name, record) in records {
            guard name.range(of: "^[A-Za-z][A-Za-z0-9_.-]{0,127}$", options: .regularExpression) != nil,
                  !forbidden.contains(name), validDevice(record.deviceId), record.editedAt >= 0,
                  record.editedAt <= latest,
                  (try JSONEncoder().encode(record.value)).count <= 4096,
                  validValue(record.value, name: name) else {
                throw HttpSyncError("Invalid reader preference record.")
            }
        }
    }

    static func validValue(_ value: ReaderPreferenceValue, name: String) -> Bool {
        if name == "mangaTextEnlargement.ios" || name == "mangaTextEnlargement.android" {
            guard case .object(let object) = value,
                  case .bool = object["enabled"],
                  case .number(let amount) = object["amount"],
                  case .number(let threshold) = object["threshold"] else { return false }
            return amount.isFinite && (0...100).contains(amount) && amount.rounded() == amount
                && threshold.isFinite && (10...60).contains(threshold) && threshold.rounded() == threshold
        }
        let booleans: Set<String> = ["eInkMode", "disablePageTurnAnimation", "systemLightSepia",
            "sepiaInvertInDark", "verticalWriting", "hideFurigana", "showSentenceTranslations",
            "continuousMode", "showStatisticsToggle", "showReadingSpeed", "showReadingTime",
            "avoidPageBreak", "justifyText", "blurImages", "layoutAdvanced", "showTitle",
            "showCharacters", "showPercentage", "alwaysShowProgress", "showProgressTop",
            "showReaderBackButton", "popupActionBar", "popupFullWidth", "popupSwipeToDismiss",
            "popupReducedMotionScrolling", "volumeKeysTurnPages", "volumeKeysSeekSasayaki",
            "reverseVolumeKeyDirection", "keepScreenOnWhileReading", "mangaSingleTapLookup",
            "mangaUseNotoSansJp", "mangaShowCopyButton", "mangaEnlargeSmallText", "mangaShowFurigana",
            "sasayaki.enabled", "sasayaki.showReaderToggle", "sasayaki.showReaderBottomPlaybackControls",
            "sasayaki.reverseVerticalReaderSkipButtons", "sasayaki.autoScroll", "sasayaki.autoPause"]
        if booleans.contains(name) { if case .bool = value { return true }; return false }
        let ranges: [String: ClosedRange<Double>] = ["fontSize": 16...60, "chapterSwipeDistance": 10...60,
            "horizontalPadding": 0...50, "verticalPadding": 0...50, "popupWidth": 100...1600,
            "popupHeight": 100...2000, "popupSwipeThreshold": 20...60,
            "popupReducedMotionScrollPercent": 40...100, "popupReducedMotionSwipeThreshold": 0...100,
            "lineHeight": 1...2.5, "characterSpacing": -10...10, "paragraphSpacing": 0...3,
            "popupScale": 0.8...1.5]
        if let range = ranges[name] {
            guard case .number(let n) = value, n.isFinite, range.contains(n) else { return false }
            return ["lineHeight", "characterSpacing", "paragraphSpacing", "popupScale"].contains(name) || n.rounded() == n
        }
        if name.hasPrefix("dictionaryCard.") || name.hasPrefix("translationCard.") {
            let field = String(name.split(separator: ".").last ?? "")
            guard ["width", "height", "scale", "fontScale"].contains(field) else { return true }
            if value == .null { return true }
            guard case .number(let n) = value, n.isFinite else { return false }
            return (field == "width" ? 100...1600 : field == "height" ? 100...2000 : 0.5...3).contains(n)
        }
        if name.hasSuffix("Color") {
            let colors: Set<String> = ["customBackgroundColor", "customTextColor", "customInfoColor",
                "sasayaki.lightTextColor", "sasayaki.lightBackgroundColor", "sasayaki.darkTextColor", "sasayaki.darkBackgroundColor"]
            if colors.contains(name) {
                guard case .number(let n) = value else { return false }
                return n.isFinite && (0...4_294_967_295).contains(n) && n.rounded() == n
            }
        }
        if name == "theme" || name == "uiTheme" {
            guard case .string(let s) = value else { return false }
            return (name == "theme" ? ["System", "Light", "Dark", "Sepia", "Custom"] : ["System", "Light", "Dark"]).contains(s)
        }
        if name == "selectedFont" {
            guard case .string(let s) = value else { return false }
            return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && s.utf16.count <= 255 && !s.contains("/") && !s.contains("\0")
        }
        if name == "sasayaki.readerSkipButtonAction" {
            guard case .string(let s) = value else { return false }
            return ["Cue", "Seconds5", "Seconds10", "Seconds15", "Seconds30"].contains(s)
        }
        return true // Safe future/platform-specific fields retain their clocks when mirrored.
    }
}
