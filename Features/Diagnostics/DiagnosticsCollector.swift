//
//  DiagnosticsCollector.swift
//  Hoshi Reader
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import MetricKit
import UIKit

/// Gathers what Settings → Diagnostics shows: the crash, hang and exit reports iOS collects for
/// the app (MetricKit), uncaught Objective-C exceptions, and sessions that ended while in front.
nonisolated final class DiagnosticsCollector: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = DiagnosticsCollector()
    private let log: DiagnosticsLog
    private nonisolated(unsafe) static var previousHandler: (@convention(c) (NSException) -> Void)?
    private nonisolated(unsafe) static var crashHeader: [String] = []
    private nonisolated(unsafe) static var crashDirectory: URL?

    init(log: DiagnosticsLog = .shared) { self.log = log }

    /// Call once at launch.
    @MainActor func start() {
        let app = DiagnosticsReport.App.current
        Self.crashHeader = app.header
        Self.crashDirectory = log.crashDirectory
        Self.previousHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            if let directory = DiagnosticsCollector.crashDirectory {
                DiagnosticsLog.saveCapturedCrash(name: exception.name.rawValue, reason: exception.reason,
                                                 symbols: exception.callStackSymbols,
                                                 header: DiagnosticsCollector.crashHeader, in: directory)
            }
            DiagnosticsCollector.previousHandler?(exception)
        }
        MXMetricManager.shared.add(self)
        log.beginSession(version: app.version)
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(cameForward), name: UIApplication.didBecomeActiveNotification, object: nil)
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification, UIApplication.willTerminateNotification] {
            center.addObserver(self, selector: #selector(leftFront), name: name, object: nil)
        }
    }

    @objc private func cameForward() { log.sessionMoved(foreground: true) }
    @objc private func leftFront() { log.sessionMoved(foreground: false) }

    /// A reader page's WebKit process ended, which iOS does to pages it needs the memory of.
    func pageProcessEnded(_ reader: String, visible: Bool, reloaded: Bool) {
        log.record(DiagnosticEvent(kind: .pageProcess, time: Date(), version: DiagnosticsReport.installedVersion,
                                   title: "\(reader) page process ended",
                                   details: ["On screen: \(visible ? "yes" : "no")",
                                             "Loaded again: \(reloaded ? "at once" : "when next shown")"]))
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        log.record(payloads.flatMap(Self.events))
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        log.record(payloads.compactMap(Self.exits))
    }

    private static func version(_ diagnostic: MXDiagnostic) -> String {
        "\(diagnostic.applicationVersion) (\(diagnostic.metaData.applicationBuildVersion))"
    }

    private static func common(_ diagnostic: MXDiagnostic, _ payload: MXDiagnosticPayload) -> [String] {
        ["Reported for: \(DiagnosticsReport.stamp(payload.timeStampBegin)) to \(DiagnosticsReport.stamp(payload.timeStampEnd))",
         "iOS: \(diagnostic.metaData.osVersion)", "Device: \(diagnostic.metaData.deviceType)"]
    }

    private static func events(_ payload: MXDiagnosticPayload) -> [DiagnosticEvent] {
        var events: [DiagnosticEvent] = []
        for crash in payload.crashDiagnostics ?? [] {
            var details = common(crash, payload)
            if let code = crash.exceptionCode { details.append("Exception code: \(code)") }
            if let reason = crash.terminationReason { details.append("Termination reason: \(reason)") }
            if let region = crash.virtualMemoryRegionInfo { details.append("Memory region: \(region)") }
            if let reason = crash.exceptionReason { details.append("Exception: \(reason.exceptionName): \(reason.composedMessage)") }
            events.append(DiagnosticEvent(
                kind: .crash, time: payload.timeStampEnd, version: version(crash),
                title: DiagnosticsReport.crashTitle(exceptionType: crash.exceptionType?.intValue, signal: crash.signal?.intValue),
                details: details, trace: DiagnosticsReport.trace(fromCallStackTree: crash.callStackTree.jsonRepresentation())))
        }
        for hang in payload.hangDiagnostics ?? [] {
            events.append(DiagnosticEvent(
                kind: .hang, time: payload.timeStampEnd, version: version(hang),
                title: "Unresponsive for \(duration(hang.hangDuration))", details: common(hang, payload),
                trace: DiagnosticsReport.trace(fromCallStackTree: hang.callStackTree.jsonRepresentation())))
        }
        for cpu in payload.cpuExceptionDiagnostics ?? [] {
            events.append(DiagnosticEvent(
                kind: .cpu, time: payload.timeStampEnd, version: version(cpu),
                title: "Used the processor for \(duration(cpu.totalCPUTime)) of \(duration(cpu.totalSampledTime))",
                details: common(cpu, payload), trace: DiagnosticsReport.trace(fromCallStackTree: cpu.callStackTree.jsonRepresentation())))
        }
        for disk in payload.diskWriteExceptionDiagnostics ?? [] {
            let megabytes = disk.totalWritesCaused.converted(to: .megabytes).value
            events.append(DiagnosticEvent(
                kind: .disk, time: payload.timeStampEnd, version: version(disk),
                title: "Wrote \(megabytes.formatted(.number.precision(.fractionLength(0)))) MB to storage",
                details: common(disk, payload), trace: DiagnosticsReport.trace(fromCallStackTree: disk.callStackTree.jsonRepresentation())))
        }
        return events
    }

    private static func exits(_ payload: MXMetricPayload) -> DiagnosticEvent? {
        guard let exits = payload.applicationExitMetrics else { return nil }
        let open = exits.foregroundExitData, hidden = exits.backgroundExitData
        let lines = DiagnosticsReport.exitLines(
            foreground: [("closed normally", open.cumulativeNormalAppExitCount),
                         ("memory limit", open.cumulativeMemoryResourceLimitExitCount),
                         ("bad memory access", open.cumulativeBadAccessExitCount),
                         ("abnormal exit", open.cumulativeAbnormalExitCount),
                         ("illegal instruction", open.cumulativeIllegalInstructionExitCount),
                         ("unresponsive", open.cumulativeAppWatchdogExitCount)],
            background: [("closed normally", hidden.cumulativeNormalAppExitCount),
                         ("memory limit", hidden.cumulativeMemoryResourceLimitExitCount),
                         ("memory needed by other apps", hidden.cumulativeMemoryPressureExitCount),
                         ("bad memory access", hidden.cumulativeBadAccessExitCount),
                         ("abnormal exit", hidden.cumulativeAbnormalExitCount),
                         ("illegal instruction", hidden.cumulativeIllegalInstructionExitCount),
                         ("unresponsive", hidden.cumulativeAppWatchdogExitCount),
                         ("processor limit", hidden.cumulativeCPUResourceLimitExitCount),
                         ("held a locked file", hidden.cumulativeSuspendedWithLockedFileExitCount),
                         ("background task ran too long", hidden.cumulativeBackgroundTaskAssertionTimeoutExitCount)])
        guard !lines.isEmpty else { return nil }
        return DiagnosticEvent(kind: .exits, time: payload.timeStampEnd, version: payload.latestApplicationVersion,
                               title: "Exits iOS counted from \(DiagnosticsReport.stamp(payload.timeStampBegin))", details: lines)
    }

    private static func duration(_ measurement: Measurement<UnitDuration>) -> String {
        measurement.converted(to: .seconds).value.formatted(.number.precision(.fractionLength(1))) + " s"
    }
}
