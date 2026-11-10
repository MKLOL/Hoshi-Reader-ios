//
//  DiagnosticsLog.swift
//  Hoshi Reader
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Something that went wrong, or that iOS reported about the app, kept for Settings → Diagnostics.
nonisolated struct DiagnosticEvent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case crash, hang, cpu, disk, exits
        case unexpectedExit = "unexpected-exit", pageProcess = "page-process"
    }
    var kind: Kind
    /// When it happened, or the end of the period iOS reported on.
    var time: Date
    /// The app version and build it happened in.
    var version: String
    var title: String
    /// "Name: value" lines.
    var details: [String] = []
    var trace: String?
}

/// An uncaught Objective-C exception, written by the app as it went down.
nonisolated struct CapturedCrash: Equatable, Sendable {
    var time: Date
    var text: String
}

/// The device's own record of crashes, hangs and unexpected exits. Nothing in it leaves the device
/// unless the reader shares the report from Settings → Diagnostics.
nonisolated final class DiagnosticsLog: @unchecked Sendable {
    static let shared = DiagnosticsLog()
    static let limits: [DiagnosticEvent.Kind: Int] = [
        .crash: 10, .hang: 5, .cpu: 5, .disk: 5, .exits: 7, .unexpectedExit: 10, .pageProcess: 20
    ]
    static let capturedCrashLimit = 5

    /// One run of the app, from launch to the last time it was known to be in front.
    struct Session: Codable, Equatable, Sendable {
        var version: String
        var launched: Date
        var active: Date?
        var foreground = false
    }

    let directory: URL
    private let queue = DispatchQueue(label: "hoshi.diagnostics", qos: .utility)
    private var session: Session?

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Diagnostics", isDirectory: true)
    }

    var crashDirectory: URL { directory.appendingPathComponent("crashes", isDirectory: true) }
    private var eventsFile: URL { directory.appendingPathComponent("events.json") }
    private var sessionFile: URL { directory.appendingPathComponent("session.json") }

    func record(_ event: DiagnosticEvent) { record([event]) }

    func record(_ events: [DiagnosticEvent]) {
        guard !events.isEmpty else { return }
        queue.async { [self] in store(readEvents() + events) }
    }

    /// Newest first.
    func events() async -> [DiagnosticEvent] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: readEvents()) }
        }
    }

    /// Starts this launch's session. A previous session that was still in front when it ended did
    /// not close normally: iOS moves an app to the background before it suspends or quits it.
    func beginSession(version: String, now: Date = Date()) {
        queue.async { [self] in
            if let data = try? Data(contentsOf: sessionFile),
               let previous = try? JSONDecoder().decode(Session.self, from: data), previous.foreground {
                let seen = previous.active ?? previous.launched
                store(readEvents() + [DiagnosticEvent(
                    kind: .unexpectedExit, time: seen, version: previous.version,
                    title: "The app stopped while it was open",
                    details: ["Opened: \(DiagnosticsReport.stamp(previous.launched))",
                              "Last came to the front: \(DiagnosticsReport.stamp(seen))",
                              "Next opened: \(DiagnosticsReport.stamp(now))",
                              "Possible causes: a crash, the memory limit, an unresponsive app, a device restart or an update installed over it."])])
            }
            session = Session(version: version, launched: now)
            writeSession()
        }
    }

    func sessionMoved(foreground: Bool, now: Date = Date()) {
        queue.async { [self] in
            guard var current = session, current.foreground != foreground else { return }
            current.foreground = foreground
            if foreground { current.active = now }
            session = current
            writeSession()
        }
    }

    /// Newest first, at most `capturedCrashLimit`.
    func capturedCrashes() async -> [CapturedCrash] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: Self.capturedCrashes(in: crashDirectory)) }
        }
    }

    static func capturedCrashes(in directory: URL) -> [CapturedCrash] {
        crashFiles(in: directory).prefix(capturedCrashLimit).compactMap { file in
            guard let text = try? String(contentsOf: file, encoding: .utf8), !text.isEmpty else { return nil }
            let millis = Double(file.deletingPathExtension().lastPathComponent.dropFirst("crash-".count))
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return CapturedCrash(time: millis.map { Date(timeIntervalSince1970: $0 / 1000) } ?? modified ?? .distantPast, text: text)
        }
    }

    /// Writes an uncaught exception where the next launch can read it. Runs while the app is going
    /// down, so it formats text, writes one file and touches nothing else.
    @discardableResult
    static func saveCapturedCrash(name: String, reason: String?, symbols: [String], header: [String],
                                  time: Date = Date(), in directory: URL) -> URL? {
        let millis = Int64(time.timeIntervalSince1970 * 1000)
        let file = directory.appendingPathComponent("crash-\(millis).txt")
        var lines = ["Captured Hoshi Reader crash", "Time: \(DiagnosticsReport.stamp(time))"] + header
        lines += ["Exception: \(name)", "Reason: \(reason ?? "none given")", ""] + symbols
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(lines.joined(separator: "\n").utf8).write(to: file, options: .atomic)
        } catch { return nil }
        for old in crashFiles(in: directory).dropFirst(capturedCrashLimit) { try? FileManager.default.removeItem(at: old) }
        return file
    }

    private static func crashFiles(in directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("crash-") && $0.pathExtension == "txt" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
    }

    private func readEvents() -> [DiagnosticEvent] {
        guard let data = try? Data(contentsOf: eventsFile) else { return [] }
        return (try? JSONDecoder().decode([DiagnosticEvent].self, from: data)) ?? []
    }

    private func store(_ events: [DiagnosticEvent]) {
        var kept: [DiagnosticEvent.Kind: Int] = [:]
        let newest = events.enumerated().sorted { $0.element.time == $1.element.time ? $0.offset > $1.offset : $0.element.time > $1.element.time }
        let bounded = newest.map(\.element).filter { event in
            kept[event.kind, default: 0] += 1
            return kept[event.kind, default: 0] <= Self.limits[event.kind, default: 5]
        }
        guard let data = try? JSONEncoder().encode(bounded) else { return }
        write(data, to: eventsFile)
    }

    private func writeSession() {
        guard let session, let data = try? JSONEncoder().encode(session) else { return }
        write(data, to: sessionFile)
    }

    /// Diagnostics cannot interrupt reading, so a full or unavailable disk only loses the record.
    private func write(_ data: Data, to file: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var root = directory, values = URLResourceValues(); values.isExcludedFromBackup = true
            try root.setResourceValues(values)
            try data.write(to: file, options: .atomic)
        } catch { }
    }
}
