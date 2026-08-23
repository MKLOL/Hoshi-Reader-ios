//
//  MangaWheelDebouncer.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Collapses a stream of trackpad horizontal scroll deltas into at most one page turn per physical
//  scroll gesture. It lives NATIVELY (held by the reader's Coordinator) precisely so its state
//  survives the per-page WebView reload that a turn triggers: a debounce kept in the page JS gets
//  wiped by `loadHTMLString`, which let one scroll's inertial momentum land on the freshly reloaded
//  next page and turn it again — the multi-page-jump bug.
//
//  Re-arm is decided by the TIME GAP since the previous event, re-evaluated on every event — never a
//  self-rescheduling timer. A timer that's pushed out on every event can be starved by bursty
//  trackpad input and never fire, leaving the trackpad stuck "disarmed / unresponsive"; the gap
//  check can't be starved (any real pause re-arms the very next event).
//

import CoreGraphics
import Foundation

struct MangaWheelDebouncer {
    /// Horizontal travel (CSS px) that commits a page turn. ~60px = a deliberate two-finger nudge.
    var threshold: CGFloat = 60
    /// Silence (seconds) that ends a gesture + its momentum tail and re-arms the next one. Trackpad
    /// active/momentum events arrive ~8–33ms apart, so 0.2s never trips mid-gesture, yet it's below
    /// human re-flick latency so a deliberate second scroll re-arms in time.
    var idleGap: TimeInterval = 0.20

    private var accumX: CGFloat = 0
    private var armed = true
    private var lastEventTime: TimeInterval = -.infinity

    /// Marks the current indirect gesture as viewport-only. Continued scroll/momentum stays
    /// suppressed until a real idle gap begins a new gesture.
    mutating func suppressCurrentGesture(now: TimeInterval) {
        accumX = 0
        armed = false
        lastEventTime = now
    }

    /// Feed one horizontal wheel delta observed at monotonic time `now`. Returns the page-turn
    /// direction to perform, or nil if this event doesn't (yet) commit a turn.
    mutating func feed(deltaX: CGFloat, now: TimeInterval) -> NavigationDirection? {
        let gap = now - lastEventTime
        lastEventTime = now
        if gap > idleGap {          // first event of a new gesture segment → fresh + armed
            accumX = 0
            armed = true
        }
        guard armed else { return nil }   // mid-gesture, or momentum after a fired turn → swallow
        accumX += deltaX
        guard abs(accumX) >= threshold else { return nil }
        // Direction copied verbatim from the working JS: drag fingers right (deltaX < 0) → forward.
        let direction: NavigationDirection = accumX < 0 ? .forward : .backward
        accumX = 0
        armed = false
        return direction
    }
}
