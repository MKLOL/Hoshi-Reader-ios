import Foundation

nonisolated final class HttpSyncUploadProgressDelegate: NSObject, URLSessionTaskDelegate {
    private let progress: @Sendable (Int64) -> Void
    init(_ progress: @escaping @Sendable (Int64) -> Void) { self.progress = progress }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        progress(totalBytesSent)
    }
}
