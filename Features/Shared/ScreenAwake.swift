//
//  ScreenAwake.swift
//  Hoshi Reader
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit

/// The one owner of the idle timer. The screen stays on while any reason holds it, so one
/// feature letting go cannot dim the screen under another.
@MainActor enum ScreenAwake {
    enum Reason: Hashable { case reading, audiobook, diagnostics }
    static let settingKey = "keepScreenOnWhileReading"
    private static var reasons: Set<Reason> = []
    private static var openReaders = 0

    static func set(_ reason: Reason, _ held: Bool) {
        if held { reasons.insert(reason) } else { reasons.remove(reason) }
        UIApplication.shared.isIdleTimerDisabled = !reasons.isEmpty
    }

    static func readerOpened() { openReaders += 1; settingChanged() }
    static func readerClosed() { openReaders = max(0, openReaders - 1); settingChanged() }

    #if DEBUG
    /// Tests start from a closed reader with nothing holding the screen.
    static func reset() { reasons = []; openReaders = 0; set(.reading, false) }
    #endif

    /// "Keep Screen On" applies while a book or manga is open, not on the shelf or in settings.
    static func settingChanged() {
        set(.reading, openReaders > 0 && UserDefaults.standard.bool(forKey: settingKey))
    }
}
