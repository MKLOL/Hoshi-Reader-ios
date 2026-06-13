//
//  AnthropicChatClient.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Minimal Anthropic Messages API client for the manga translation feature, mirroring the surface
//  of `OpenAiChatClient` (`complete` for text, `completeImage` for a vision crop). Claude has no
//  official Swift SDK, so this calls the Messages API over raw HTTPS:
//    POST https://api.anthropic.com/v1/messages
//    headers: x-api-key, anthropic-version: 2023-06-01
//    body:    { model, max_tokens (required), messages:[{role:"user", content: ...}] }
//    reply:   { content:[{type:"text", text:"…"}], stop_reason, … }
//  The whole type is `nonisolated` so its networking never hops the main actor.
//

import Foundation

/// Thrown when an Anthropic request fails; `message` is safe to show the user.
struct AnthropicError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

nonisolated struct AnthropicChatClient {
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let apiVersion = "2023-06-01"
    /// Anthropic requires `max_tokens`; a translation + short note fits comfortably here.
    private let maxTokens = 2048
    private let connectTimeout: TimeInterval = 30
    private let readTimeout: TimeInterval = 90

    init() {}

    nonisolated func complete(apiKey: String, model: String, prompt: String, bubbleText: String) async throws -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            throw AnthropicError(message: "Set your Anthropic API key in Settings → Translation model.")
        }
        let body = Self.buildRequestBody(model: model, maxTokens: maxTokens, prompt: prompt, bubbleText: bubbleText)
        return try await perform(apiKey: key, body: body)
    }

    nonisolated func completeImage(apiKey: String, model: String, prompt: String, image: AiChatImage) async throws -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            throw AnthropicError(message: "Set your Anthropic API key in Settings → Translation model.")
        }
        let body = Self.buildImageRequestBody(model: model, maxTokens: maxTokens, prompt: prompt, image: image)
        return try await perform(apiKey: key, body: body)
    }

    // MARK: - HTTP

    private nonisolated func perform(apiKey: String, body: Data) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = readTimeout
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = connectTimeout
        config.timeoutIntervalForResource = readTimeout
        let session = URLSession(configuration: config)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as AnthropicError {
            throw error
        } catch {
            throw AnthropicError(message: error.localizedDescription)
        }

        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200...299).contains(code) {
            throw AnthropicError(message: Self.parseErrorMessage(code: code, data: data))
        }
        return try Self.parseResponse(data)
    }

    // MARK: - Body builders (pure, testable)

    static func buildRequestBody(model: String, maxTokens: Int, prompt: String, bubbleText: String) -> Data {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = trimmedPrompt.isEmpty ? bubbleText : "\(trimmedPrompt)\n\n\(bubbleText)"
        let request = MessagesRequest(
            model: resolvedModel(model),
            maxTokens: maxTokens,
            messages: [Message(role: "user", content: .text(content))]
        )
        return encode(request)
    }

    static func buildImageRequestBody(model: String, maxTokens: Int, prompt: String, image: AiChatImage) -> Data {
        let mimeType = image.mimeType.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedMime = mimeType.isEmpty ? "image/png" : mimeType
        let base64 = image.base64Data.trimmingCharacters(in: .whitespacesAndNewlines)
        let promptText = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPrompt = promptText.isEmpty ? Self.fallbackImagePrompt : promptText
        // Anthropic vision: image block first, then the instruction text.
        let parts: [ContentPart] = [
            .image(mediaType: resolvedMime, data: base64),
            .text(resolvedPrompt),
        ]
        let request = MessagesRequest(
            model: resolvedModel(model),
            maxTokens: maxTokens,
            messages: [Message(role: "user", content: .parts(parts))]
        )
        return encode(request)
    }

    private static func resolvedModel(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallbackModel : trimmed
    }

    private static let fallbackModel = "claude-haiku-4-5"
    private static let fallbackImagePrompt =
        "Transcribe any Japanese text visible in this image crop and translate it into " +
        "natural English. If useful, include a short vocabulary or grammar note. If no " +
        "readable Japanese text is visible, say so."

    private static func encode(_ request: MessagesRequest) -> Data {
        (try? JSONEncoder().encode(request)) ?? Data("{}".utf8)
    }

    // MARK: - Response parsing (pure, testable)

    /// Extracts the assistant reply by concatenating the `text` blocks of a successful response.
    static func parseResponse(_ data: Data) throws -> String {
        guard let response = try? JSONDecoder().decode(MessagesResponse.self, from: data) else {
            throw AnthropicError(message: "Could not read the Anthropic response.")
        }
        let text = response.content
            .filter { $0.type == "text" }
            .compactMap { $0.text }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            // A safety refusal returns 200 with stop_reason "refusal" and no text.
            if response.stopReason == "refusal" {
                throw AnthropicError(message: "Claude declined to answer this request.")
            }
            throw AnthropicError(message: "Anthropic returned an empty response.")
        }
        return text
    }

    static func parseErrorMessage(code: Int, data: Data) -> String {
        if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
           let message = envelope.error?.message,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return message
        }
        return "Anthropic request failed (HTTP \(code))."
    }

    // MARK: - Codable wire types

    private struct MessagesRequest: Encodable {
        let model: String
        let maxTokens: Int
        let messages: [Message]
        enum CodingKeys: String, CodingKey {
            case model
            case maxTokens = "max_tokens"
            case messages
        }
    }

    private struct Message: Encodable {
        let role: String
        let content: MessageContent

        enum CodingKeys: String, CodingKey { case role, content }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(role, forKey: .role)
            switch content {
            case .text(let text): try c.encode(text, forKey: .content)
            case .parts(let parts): try c.encode(parts, forKey: .content)
            }
        }
    }

    private enum MessageContent {
        case text(String)
        case parts([ContentPart])
    }

    /// One content block — either text or a base64 image source, encoded in Anthropic's shape.
    private enum ContentPart: Encodable {
        case text(String)
        case image(mediaType: String, data: String)

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let text):
                try c.encode("text", forKey: .type)
                try c.encode(text, forKey: .text)
            case .image(let mediaType, let data):
                try c.encode("image", forKey: .type)
                var source = c.nestedContainer(keyedBy: SourceKeys.self, forKey: .source)
                try source.encode("base64", forKey: .type)
                try source.encode(mediaType, forKey: .mediaType)
                try source.encode(data, forKey: .data)
            }
        }

        enum CodingKeys: String, CodingKey { case type, text, source }
        enum SourceKeys: String, CodingKey {
            case type, data
            case mediaType = "media_type"
        }
    }

    private struct MessagesResponse: Decodable {
        let content: [ContentBlock]
        let stopReason: String?
        enum CodingKeys: String, CodingKey {
            case content
            case stopReason = "stop_reason"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            content = try c.decodeIfPresent([ContentBlock].self, forKey: .content) ?? []
            stopReason = try c.decodeIfPresent(String.self, forKey: .stopReason)
        }
    }

    private struct ContentBlock: Decodable {
        let type: String
        let text: String?
    }

    private struct ErrorEnvelope: Decodable {
        let error: ApiError?
    }

    private struct ApiError: Decodable {
        let type: String?
        let message: String?
    }
}
