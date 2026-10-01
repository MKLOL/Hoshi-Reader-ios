import Foundation

nonisolated struct HttpSyncTransferSample: Sendable, Equatable {
    let key: String
    let uploading: Bool
    let completed: Int64
    let total: Int64
}

nonisolated struct HttpSyncTransferProgress: Sendable, Equatable {
    let sample: HttpSyncTransferSample
    let bytesPerSecond: Double?
    var fraction: Double? { sample.total > 0 ? min(1, max(0, Double(sample.completed) / Double(sample.total))) : nil }
    var remainingSeconds: Int? {
        guard let bytesPerSecond, bytesPerSecond > 0, sample.total > sample.completed else { return nil }
        let seconds = ceil(Double(sample.total - sample.completed) / bytesPerSecond)
        return seconds.isFinite && seconds < Double(Int.max) ? Int(seconds) : nil
    }
    var label: String {
        let amount = String(format: "%.1f", Double(sample.completed) / 1_000_000)
        let total = sample.total > 0 ? " / \(String(format: "%.1f", Double(sample.total) / 1_000_000)) MB" : " MB"
        let speed = bytesPerSecond.map { String(format: " · %.2f MB/s", $0 / 1_000_000) } ?? ""
        let eta = remainingSeconds.map { " · \($0 / 60)m \($0 % 60)s remaining" } ?? ""
        return amount + total + speed + eta
    }
}

/// Per-file monotonic sampling: reconnect/retry offsets never turn a cached prefix into speed.
nonisolated struct HttpSyncTransferMeter {
    private var previous: HttpSyncTransferSample?
    private var startedAt: TimeInterval = 0
    private var initialBytes: Int64 = 0
    mutating func update(_ sample: HttpSyncTransferSample, now: TimeInterval) -> HttpSyncTransferProgress {
        if previous?.key != sample.key || previous?.uploading != sample.uploading ||
            sample.completed < (previous?.completed ?? 0) || now < startedAt {
            startedAt = now; initialBytes = sample.completed
        }
        previous = sample
        let elapsed = now - startedAt
        let bytes = max(0, sample.completed - initialBytes)
        let speed = elapsed >= 0.5 && bytes > 0 ? Double(bytes) / elapsed : nil
        return .init(sample: sample, bytesPerSecond: speed)
    }
}
