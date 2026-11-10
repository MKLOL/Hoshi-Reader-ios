//
//  DiagnosticsReport.swift
//  Hoshi Reader
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// The text shown in Settings → Diagnostics and shared from there.
nonisolated struct DiagnosticsReport: Sendable {
    struct App: Equatable, Sendable {
        var bundle: String
        var version: String
        var system: String
        var device: String

        static var current: App {
            var system = utsname()
            let device = uname(&system) == 0 ? withUnsafePointer(to: &system.machine) {
                $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
            } : "unknown"
            let os = ProcessInfo.processInfo.operatingSystemVersion
            return App(bundle: Bundle.main.bundleIdentifier ?? "unknown", version: installedVersion,
                       system: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", device: device)
        }

        var header: [String] { ["Bundle: \(bundle)", "Version: \(version)", "iOS: \(system)", "Device: \(device)"] }
    }

    static let maxTraceCharacters = 12_000

    static var installedVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return "\(version) (\(build))"
    }

    var app: App
    var capturedCrashes: [CapturedCrash] = []
    var events: [DiagnosticEvent] = []

    static func current(log: DiagnosticsLog = .shared) async -> DiagnosticsReport {
        DiagnosticsReport(app: .current, capturedCrashes: await log.capturedCrashes(), events: await log.events())
    }

    var text: String { sections.joined(separator: "\n\n") + "\n" }

    /// The header, then one block per record, newest first within each group.
    var sections: [String] {
        var sections = [(["Hoshi Reader Diagnostics"] + app.header).joined(separator: "\n")]
        for (index, crash) in capturedCrashes.enumerated() {
            sections.append(["Captured Crash \(index + 1)", "Time: \(Self.stamp(crash.time))", "Trace:", Self.bounded(crash.text)].joined(separator: "\n"))
        }
        let groups: [(DiagnosticEvent.Kind, String)] = [
            (.crash, "Crash"), (.unexpectedExit, "Unexpected Exit"), (.hang, "Hang"), (.cpu, "CPU Limit"),
            (.disk, "Disk Writes"), (.pageProcess, "Page Restart"), (.exits, "Exit Counts")
        ]
        for (kind, name) in groups {
            for (index, event) in events.filter({ $0.kind == kind }).enumerated() {
                var lines = ["\(name) \(index + 1)", "Time: \(Self.stamp(event.time))", "Version: \(event.version)", event.title] + event.details
                if let trace = event.trace, !trace.isEmpty { lines += ["Trace:", Self.bounded(trace)] }
                sections.append(lines.joined(separator: "\n"))
            }
        }
        if sections.count == 1 {
            sections.append("Nothing has been recorded. iOS hands over crash and hang reports the next time the app is opened, and exit counts about once a day.")
        }
        return sections
    }

    static func fileName(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "hoshi-diagnostics-\(formatter.string(from: now)).txt"
    }

    static func stamp(_ date: Date) -> String { date.formatted(.iso8601) }

    /// A long trace keeps its beginning and its end, which name the failure and where it started.
    static func bounded(_ trace: String) -> String {
        guard trace.count > maxTraceCharacters else { return trace }
        let head = maxTraceCharacters / 2
        return trace.prefix(head) + "\n[trace truncated to first and last \(maxTraceCharacters) characters]\n" + trace.suffix(maxTraceCharacters - head)
    }

    // MARK: - What iOS reports

    /// The frames of the thread iOS blames, one per line, from a MetricKit call stack tree. Each
    /// line carries what symbolication needs: the binary, its UUID and the offset into it.
    static func trace(fromCallStackTree json: Data, frameLimit: Int = 64) -> String? {
        struct Tree: Decodable {
            struct Stack: Decodable {
                var threadAttributed: Bool?
                var callStackRootFrames: [Frame]?
            }
            struct Frame: Decodable {
                var binaryName: String?
                var binaryUUID: String?
                var offsetIntoBinaryTextSegment: UInt64?
                var address: UInt64?
                var subFrames: [Frame]?
            }
            var callStacks: [Stack]?
        }
        guard let stacks = (try? JSONDecoder().decode(Tree.self, from: json))?.callStacks, !stacks.isEmpty else { return nil }
        let stack = stacks.first { $0.threadAttributed == true } ?? stacks[0]
        var lines: [String] = []
        var pending = Array((stack.callStackRootFrames ?? []).reversed())
        while let frame = pending.popLast(), lines.count < frameLimit {
            let address = frame.address.map { "0x" + String($0, radix: 16) } ?? "?"
            lines.append("\(lines.count)  \(frame.binaryName ?? "?")  \(address)  +\(frame.offsetIntoBinaryTextSegment ?? 0)  \(frame.binaryUUID ?? "")")
            pending.append(contentsOf: (frame.subFrames ?? []).reversed())
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// "EXC_BAD_ACCESS (SIGSEGV)" from the numbers iOS reports.
    static func crashTitle(exceptionType: Int?, signal: Int?) -> String {
        let exceptions = [1: "EXC_BAD_ACCESS", 2: "EXC_BAD_INSTRUCTION", 3: "EXC_ARITHMETIC", 4: "EXC_EMULATION",
                          5: "EXC_SOFTWARE", 6: "EXC_BREAKPOINT", 10: "EXC_CRASH", 11: "EXC_RESOURCE", 12: "EXC_GUARD"]
        let signals = [4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT", 8: "SIGFPE", 9: "SIGKILL", 10: "SIGBUS", 11: "SIGSEGV", 13: "SIGPIPE", 15: "SIGTERM"]
        let exception = exceptionType.map { exceptions[$0] ?? "Exception \($0)" }
        let signalName = signal.map { signals[$0] ?? "signal \($0)" }
        switch (exception, signalName) {
        case let (exception?, signalName?): return "\(exception) (\(signalName))"
        case let (exception?, nil): return exception
        case let (nil, signalName?): return signalName
        default: return "Crash"
        }
    }

    /// The exits iOS counted over a period, as "Where, why: count" lines without the zeroes.
    static func exitLines(foreground: [(String, Int)], background: [(String, Int)]) -> [String] {
        foreground.filter { $0.1 > 0 }.map { "Open, \($0.0): \($0.1)" } + background.filter { $0.1 > 0 }.map { "In the background, \($0.0): \($0.1)" }
    }
}
