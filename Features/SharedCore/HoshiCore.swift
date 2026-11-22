import Foundation

enum HoshiCore {
    struct Failure: LocalizedError {
        let reason: String

        nonisolated var errorDescription: String? { reason }
    }

    nonisolated static func call(_ operation: String, payload: [String: Any]) throws -> Any {
        let request = try JSONSerialization.data(withJSONObject: ["operation": operation, "payload": payload])
        return try String(decoding: request, as: UTF8.self).withCString { request in
            guard let result = hoshi_core_call(request) else {
                throw Failure(reason: "Shared core returned no response")
            }
            defer { hoshi_core_free(result) }
            let data = Data(String(cString: result).utf8)
            let response = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let value = response?["value"] else {
                throw Failure(reason: response?["error"] as? String ?? "Invalid shared core response")
            }
            return value
        }
    }
}
