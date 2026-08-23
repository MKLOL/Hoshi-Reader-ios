//
//  GeminiChatClient.swift
//  Hoshi Reader
//
//  Native Google Gemini generateContent client.
//

import Foundation

struct GeminiError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

nonisolated struct GeminiChatClient {
    func complete(apiKey: String, model: String, prompt: String, bubbleText: String) async throws -> String {
        let instruction = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = instruction.isEmpty ? bubbleText : "\(instruction)\n\n\(bubbleText)"
        return try await perform(apiKey: apiKey, model: model, parts: [.text(text)])
    }

    func completeImage(apiKey: String, model: String, prompt: String, image: AiChatImage) async throws -> String {
        let instruction = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = instruction.isEmpty
            ? "Transcribe and translate the Japanese text in this image into natural English."
            : instruction
        let mime = image.mimeType.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await perform(
            apiKey: apiKey,
            model: model,
            parts: [
                .text(text),
                .inlineData(mimeType: mime.isEmpty ? "image/png" : mime, data: image.base64Data),
            ]
        )
    }

    private func perform(apiKey: String, model: String, parts: [RequestPart]) async throws -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw GeminiError(message: "Set your Google (Gemini) API key in Settings → Translation model.")
        }
        let selectedModel = ChatModelCatalog.replacementModelId(for: model)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedModel.isEmpty,
              let encodedModel = selectedModel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let endpoint = URL(string:
                "https://generativelanguage.googleapis.com/v1beta/models/\(encodedModel):generateContent"
              ) else {
            throw GeminiError(message: "The selected Gemini model id is invalid.")
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(
            GenerateRequest(contents: [.init(role: "user", parts: parts)])
        )
        request.timeoutInterval = 90
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 90
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession(configuration: config).data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GeminiError(message: error.localizedDescription)
        }

        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else {
            if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
               let message = envelope.error?.message,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw GeminiError(message: "Google (Gemini): \(message)")
            }
            throw GeminiError(message: "Google (Gemini) request failed (HTTP \(code)).")
        }
        guard let decoded = try? JSONDecoder().decode(GenerateResponse.self, from: data) else {
            throw GeminiError(message: "Could not read the Google (Gemini) response.")
        }
        var reply = ""
        for candidate in decoded.candidates {
            for part in candidate.content?.parts ?? [] {
                if let text = part.text { reply += text }
            }
        }
        reply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else {
            throw GeminiError(message: "Google (Gemini) returned an empty response.")
        }
        return reply
    }

    private struct GenerateRequest: Encodable { let contents: [RequestContent] }
    private struct RequestContent: Encodable {
        let role: String
        let parts: [RequestPart]
    }
    private enum RequestPart: Encodable {
        case text(String)
        case inlineData(mimeType: String, data: String)

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let text):
                try container.encode(text, forKey: .text)
            case .inlineData(let mimeType, let data):
                try container.encode(
                    InlineData(mimeType: mimeType, data: data),
                    forKey: .inlineData
                )
            }
        }

        private enum CodingKeys: String, CodingKey {
            case text
            case inlineData = "inline_data"
        }
        private struct InlineData: Encodable {
            let mimeType: String
            let data: String
            enum CodingKeys: String, CodingKey {
                case mimeType = "mime_type"
                case data
            }
        }
    }

    private struct GenerateResponse: Decodable {
        let candidates: [Candidate]
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            candidates = try container.decodeIfPresent([Candidate].self, forKey: .candidates) ?? []
        }
        private enum CodingKeys: String, CodingKey { case candidates }
    }
    private struct Candidate: Decodable { let content: ResponseContent? }
    private struct ResponseContent: Decodable { let parts: [ResponsePart] }
    private struct ResponsePart: Decodable { let text: String? }
    private struct ErrorEnvelope: Decodable { let error: ApiError? }
    private struct ApiError: Decodable { let message: String? }
}
