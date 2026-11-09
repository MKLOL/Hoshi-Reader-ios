import Foundation

/// Opt-in, bounded startup evidence for simulator and optimized device builds. Callers must use
/// constant stage names; this trace deliberately has no book, path, text or credential fields.
/// `first_visible` must be finished by the current document after image decode and two animation
/// frames, rather than by WKNavigationDelegate.didFinish.
@MainActor
final class MangaStartupTrace {
    static let environmentKey = "HOSHI_MANGA_STARTUP_TRACE"
    static let isEnabled = ProcessInfo.processInfo.environment[environmentKey] == "1"
    static let maximumStages = 48

    private struct PendingSelection {
        let bookID: UUID
        let trace: MangaStartupTrace
        let selectedAt: TimeInterval
    }
    private static var pendingSelection: PendingSelection?

    /// Start at the actual bookshelf action, before SwiftUI presents or constructs the reader.
    /// Keep only the newest selection in memory; its book identity never enters the output.
    static func bookSelected(_ bookID: UUID) {
        guard isEnabled else { return }
        let trace = MangaStartupTrace()
        trace.mark("book_selected")
        pendingSelection = PendingSelection(bookID: bookID, trace: trace, selectedAt: trace.startedAt)
    }

    static func forOpeningBook(_ bookID: UUID) -> MangaStartupTrace {
        guard isEnabled, let pending = pendingSelection else { return MangaStartupTrace() }
        let age = ProcessInfo.processInfo.systemUptime - pending.selectedAt
        guard age.isFinite, age >= 0, age <= 10 else {
            pendingSelection = nil
            return MangaStartupTrace()
        }
        guard pending.bookID == bookID else { return MangaStartupTrace() }
        pendingSelection = nil
        return pending.trace
    }

    let id: String
    let enabled: Bool
    private(set) var firstVisibleMilliseconds: Double?
    private(set) var isFinished = false
    private let clock: () -> TimeInterval
    private let output: (String) -> Void
    private let startedAt: TimeInterval
    private let persistOnFinish: Bool
    private var previousElapsed: Double = 0
    private var recordedStages: Set<String> = []
    private var recordedLines: [String] = []

    init(enabled: Bool = MangaStartupTrace.isEnabled,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         output: @escaping (String) -> Void = {
             FileHandle.standardError.write(Data(($0 + "\n").utf8))
         }) {
        self.enabled = enabled
        self.clock = clock
        self.output = output
        // Injected clocks/sinks can test enabled traces without writing application state.
        // Only the actual opt-in launch environment permits retaining diagnostic files.
        persistOnFinish = enabled && MangaStartupTrace.isEnabled
        id = enabled ? String(UUID().uuidString.prefix(8)).lowercased() : "disabled"
        startedAt = enabled ? clock() : 0
    }

    var elapsedMilliseconds: Double {
        guard enabled else { return 0 }
        return firstVisibleMilliseconds ?? max(previousElapsed, (clock() - startedAt) * 1000)
    }

    /// Repeated SwiftUI layout/render callbacks cannot flood stderr. At most one event per
    /// constant stage is emitted, with one reserved slot for the first-visible completion.
    func mark(_ stage: String) {
        guard enabled, !isFinished, stage != "first_visible", valid(stage),
              recordedStages.count < Self.maximumStages - 1, recordedStages.insert(stage).inserted else { return }
        emit(stage)
    }

    /// The owning controller validates the WebView load token before calling this method.
    /// Finish once, so later page turns and late/stale document events cannot change startup.
    func finish() {
        guard enabled, !isFinished else { return }
        emit("first_visible")
        firstVisibleMilliseconds = previousElapsed
        isFinished = true
        if persistOnFinish {
            let lines = recordedLines, identifier = id
            Task.detached(priority: .utility) {
                Self.persist(lines: lines, identifier: identifier)
            }
        }
    }

    private func emit(_ stage: String) {
        let elapsed = max(previousElapsed, (clock() - startedAt) * 1000)
        let delta = elapsed - previousElapsed
        previousElapsed = elapsed
        let line = String(format: "HOSHI_MANGA_STARTUP id=%@ stage=%@ elapsed_ms=%.3f delta_ms=%.3f", id, stage, elapsed, delta)
        if persistOnFinish { recordedLines.append(line) }
        output(line)
    }

    private func valid(_ stage: String) -> Bool {
        !stage.isEmpty && stage.utf8.count <= 48 && stage.utf8.allSatisfy {
            (97...122).contains($0) || (48...57).contains($0) || $0 == 95
        }
    }

    /// One background write after first image visibility; no reader-time polling or file I/O.
    /// Keep only the newest eight small traces so leaving diagnostics enabled stays bounded.
    nonisolated private static func persist(lines: [String], identifier: String) {
        let manager = FileManager.default
        guard let caches = manager.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let directory = caches.appendingPathComponent("MangaStartupTrace", isDirectory: true)
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data((lines.joined(separator: "\n") + "\n").utf8)
                .write(to: directory.appendingPathComponent(identifier + ".log"), options: .atomic)
            let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
            let files = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles)
                .filter { $0.pathExtension == "log" }
                .compactMap { file -> (URL, Date)? in
                    guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
                    return (file, values.contentModificationDate ?? .distantPast)
                }
                .sorted { left, right in
                    left.1 == right.1 ? left.0.lastPathComponent > right.0.lastPathComponent : left.1 > right.1
                }
            for (file, _) in files.dropFirst(8) { try? manager.removeItem(at: file) }
        } catch {
            // Diagnostics cannot fail or delay reading when the cache is unavailable/full.
        }
    }
}
