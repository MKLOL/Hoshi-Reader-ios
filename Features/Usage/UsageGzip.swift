import Foundation
import zlib

/// Use the platform's zlib gzip implementation for framing, compression and CRC validation.
nonisolated enum UsageGzip {
    static let compressedLimit = 16 * 1024 * 1024
    static let expandedLimit = 64 * 1024 * 1024
    static func compress(_ data: Data) throws -> Data { try process(data, decompress: false, outputLimit: compressedLimit) }
    static func expand(_ data: Data, maxBytes: Int = expandedLimit) throws -> Data { try process(data, decompress: true, outputLimit: min(expandedLimit, max(0, maxBytes))) }
    private static func process(_ data: Data, decompress: Bool, outputLimit: Int) throws -> Data {
        guard data.count <= (decompress ? compressedLimit : expandedLimit) else { throw HttpSyncError("Usage log exceeds the size limit") }
        var stream = z_stream()
        let initialized = decompress
            ? inflateInit2_(&stream, MAX_WBITS + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            : deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, MAX_WBITS + 16, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initialized == Z_OK else { throw HttpSyncError("Could not initialize gzip") }
        defer { if decompress { inflateEnd(&stream) } else { deflateEnd(&stream) } }
        return try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            var output = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                try Task.checkCancellation()
                let status = buffer.withUnsafeMutableBytes { bytes -> Int32 in
                    stream.next_out = bytes.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(bytes.count)
                    return decompress ? inflate(&stream, Z_NO_FLUSH) : deflate(&stream, Z_FINISH)
                }
                let produced = buffer.count - Int(stream.avail_out)
                guard output.count + produced <= outputLimit else { throw HttpSyncError("Usage log expands beyond the size limit") }
                output.append(contentsOf: buffer.prefix(produced))
                if status == Z_STREAM_END {
                    guard stream.avail_in == 0 else { throw HttpSyncError("Unexpected data after gzip stream") }
                    return output
                }
                guard status == Z_OK, produced > 0 || stream.avail_in > 0 else { throw HttpSyncError("Invalid or truncated gzip usage log") }
            }
        }
    }
}
