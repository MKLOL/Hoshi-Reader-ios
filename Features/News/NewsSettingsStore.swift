//
//  NewsSettingsStore.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Which sources are on and the user's own RSS feeds. UserDefaults-backed like `UserConfig`.
@Observable
@MainActor
final class NewsSettingsStore {
    static let shared = NewsSettingsStore()

    /// Source ids the user switched off explicitly.
    private(set) var disabledSourceIds: Set<String>
    /// Source ids the user switched on explicitly (needed for built-ins that start disabled).
    private(set) var enabledSourceIds: Set<String>
    private(set) var customSources: [NewsSource]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        disabledSourceIds = Set(defaults.stringArray(forKey: Keys.disabled) ?? [])
        enabledSourceIds = Set(defaults.stringArray(forKey: Keys.enabled) ?? [])
        customSources = defaults.data(forKey: Keys.custom)
            .flatMap { try? JSONDecoder().decode([NewsSource].self, from: $0) } ?? []
    }

    /// Every listable source; the shared-link pseudo-source is not part of this.
    var sources: [NewsSource] { NewsSourceCatalog.builtIn + customSources }

    var enabledSources: [NewsSource] { sources.filter(isEnabled) }

    func isEnabled(_ source: NewsSource) -> Bool {
        if disabledSourceIds.contains(source.id) { return false }
        if enabledSourceIds.contains(source.id) { return true }
        return source.enabledByDefault
    }

    func setEnabled(_ enabled: Bool, source: NewsSource) {
        if enabled {
            disabledSourceIds.remove(source.id)
            enabledSourceIds.insert(source.id)
        } else {
            disabledSourceIds.insert(source.id)
            enabledSourceIds.remove(source.id)
        }
        persist()
    }

    @discardableResult
    func addCustomRss(name: String, url: String) -> NewsSource {
        let source = NewsSourceCatalog.customRss(name: name, url: url)
        customSources.removeAll { $0.id == source.id }
        customSources.append(source)
        persist()
        return source
    }

    func removeCustomSource(_ source: NewsSource) {
        customSources.removeAll { $0.id == source.id }
        disabledSourceIds.remove(source.id)
        enabledSourceIds.remove(source.id)
        persist()
    }

    private func persist() {
        defaults.set(disabledSourceIds.sorted(), forKey: Keys.disabled)
        defaults.set(enabledSourceIds.sorted(), forKey: Keys.enabled)
        defaults.set(try? JSONEncoder().encode(customSources), forKey: Keys.custom)
    }

    private enum Keys {
        static let disabled = "news.disabledSourceIds"
        static let enabled = "news.enabledSourceIds"
        static let custom = "news.customSources"
    }
}
