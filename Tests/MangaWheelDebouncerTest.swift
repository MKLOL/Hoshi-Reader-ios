// Standalone unit test for `MangaWheelDebouncer` — the native trackpad page-turn debounce that
// collapses one physical two-finger scroll (and its inertial momentum) into exactly one page turn.
//
// This project has no Swift unit-test target, and a real trackpad/indirect scroll cannot be
// injected into the iOS Simulator (idb is touch-only; synthetic macOS CGEvents don't reach the sim).
// So the debounce was designed as a pure, clock-injectable value type and is tested directly:
//
//   swiftc "Features/MangaReader/MangaWheelDebouncer.swift" "Tests/MangaWheelDebouncerTest.swift" -o /tmp/mwd && /tmp/mwd
//
// It compiles the REAL debouncer source (plus a NavigationDirection stub) and asserts the
// one-scroll-one-turn / momentum-swallowing / never-stuck-re-arm behaviour deterministically.

import Foundation

enum NavigationDirection: Equatable { case forward, backward }

@main
struct MangaWheelDebouncerTest {
    static var failures = 0

    static func check(_ name: String, _ cond: Bool, _ extra: String = "") {
        print("\(cond ? "PASS" : "FAIL")  \(name)\(extra.isEmpty ? "" : "  (\(extra))")")
        if !cond { failures += 1 }
    }

    /// Feed a sequence of (deltaX, time) into a fresh debouncer; return the directions it committed.
    static func run(_ events: [(CGFloat, TimeInterval)]) -> [NavigationDirection] {
        var d = MangaWheelDebouncer()
        var out: [NavigationDirection] = []
        for (dx, t) in events { if let dir = d.feed(deltaX: dx, now: t) { out.append(dir) } }
        return out
    }

    static func main() {
        // 1. One clean gesture (−20px ×4 at 16ms) → exactly one forward (commits at −60).
        check("single gesture → one forward",
              run([(-20, 0.0), (-20, 0.016), (-20, 0.032), (-20, 0.048)]) == [.forward])

        // 2. Gesture + long inertial momentum tail (24 more events at 16ms) → still one turn.
        do {
            var ev: [(CGFloat, TimeInterval)] = [(-20, 0), (-20, 0.016), (-20, 0.032)]
            for i in 0..<24 { ev.append((-12, 0.048 + Double(i) * 0.016)) }
            check("gesture + momentum tail → one forward", run(ev) == [.forward])
        }

        // 3. Long continuous edge-to-edge scroll (60 events) → one turn, not one per 60px.
        check("long continuous scroll → one forward",
              run((0..<60).map { (CGFloat(-20), Double($0) * 0.016) }) == [.forward])

        // 4. Two DISTINCT flicks separated by a real pause (>idleGap) → two turns.
        check("two distinct flicks → two turns",
              run([(-20, 0), (-20, 0.016), (-20, 0.032),
                   (-20, 0.40), (-20, 0.416), (-20, 0.432)]) == [.forward, .forward])

        // 5. The "stuck" trap: bursts every 0.10s (< idleGap) after a fire must NOT re-arm (one
        //    continuous gesture); then after a true >idleGap pause it MUST re-arm and fire again.
        do {
            var d = MangaWheelDebouncer()
            var mid: [NavigationDirection] = []
            var ev: [(CGFloat, TimeInterval)] = [(-20, 0), (-20, 0.016), (-20, 0.032)]
            for i in 0..<10 { ev.append((-20, 0.10 + Double(i) * 0.10)) }
            for (dx, t) in ev { if let x = d.feed(deltaX: dx, now: t) { mid.append(x) } }
            check("bursty < idleGap → no extra turn (one continuous gesture)", mid == [.forward], "\(mid)")
            let last = ev.last!.1
            var after: [NavigationDirection] = []
            for (dx, t) in [(CGFloat(-20), last + 0.40), (-20, last + 0.416), (-20, last + 0.432)] {
                if let x = d.feed(deltaX: dx, now: t) { after.append(x) }
            }
            check("re-arms after a real pause (never permanently stuck)", after == [.forward], "\(after)")
        }

        // 6. Direction reversal: −30,+30,+40,+40 nets to +80 → one backward (deltaX>0 ⇒ backward).
        check("direction reversal nets out → one backward",
              run([(-30, 0), (30, 0.016), (40, 0.032), (40, 0.048)]) == [.backward])

        // 7. Sub-threshold nudge within one gesture → no turn.
        check("sub-threshold → no turn", run([(-20, 0), (-20, 0.016)]) == [])

        // 8. A scroll that participated in pinch/pan must swallow its remaining momentum and only
        //    allow page navigation again after a genuine idle gap.
        do {
            var d = MangaWheelDebouncer()
            d.suppressCurrentGesture(now: 0)
            let momentum = d.feed(deltaX: -100, now: 0.05)
            let nextGesture = d.feed(deltaX: -100, now: 0.40)
            check("pinch suppression swallows momentum", momentum == nil)
            check("pinch suppression re-arms after idle", nextGesture == .forward)
        }

        print(failures == 0 ? "\nALL DEBOUNCER TESTS PASSED" : "\n\(failures) TEST(S) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
