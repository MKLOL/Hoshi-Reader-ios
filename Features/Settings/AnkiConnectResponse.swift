import Foundation
import CoreFoundation

nonisolated enum AnkiConnectResponse {
    enum Failure: LocalizedError {
        case invalidResponse, rejected(String)
        var errorDescription: String? {
            switch self {
            case .invalidResponse: "AnkiConnect returned an invalid response."
            case .rejected(let reason): reason
            }
        }
    }
    static func result(data: Data, response: URLResponse) throws -> Any {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = envelope["error"], let result = envelope["result"] else { throw Failure.invalidResponse }
        if let reason = error as? String { throw Failure.rejected(reason) }
        guard error is NSNull else { throw Failure.invalidResponse }
        return result
    }
    static func noteID(_ result: Any?) throws -> Int64 {
        guard let number = result as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.int64Value > 0, number.decimalValue == Decimal(number.int64Value) else { throw Failure.invalidResponse }
        return number.int64Value
    }
    static func storedFilename(_ result: Any?, expected: String) throws {
        guard !expected.isEmpty, let filename = result as? String, filename == expected else { throw Failure.invalidResponse }
    }
}
