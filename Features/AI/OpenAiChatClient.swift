//
//  OpenAiChatClient.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Minimal OpenAI Chat Completions client for the manga speech-bubble ChatGPT feature, ported
//  from the Android features/ai/OpenAiChatClient.kt. Uses URLSession async/await. The request body
//  is deliberately just `model` + `messages` — no `temperature` / `max_tokens` / `stream` — so it
//  stays compatible across model families (standard, reasoning, and whatever the user types into
//  the model setting). Networking is `nonisolated` so it never hops the main actor.
//

import Foundation

/// Thrown when an OpenAI chat-completions request fails; `message` is safe to show the user.
struct OpenAiError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Minimal OpenAI Chat Completions client. `complete` sends a text-only message; `completeImage`
/// sends a vision message with one inline image crop. The whole type is `nonisolated` so its
/// networking and pure helpers never hop the main actor under the project's default-MainActor mode.
nonisolated struct OpenAiChatClient {
    private let endpoint: URL
    private let connectTimeout: TimeInterval = 30
    private let readTimeout: TimeInterval = 90

    /// `baseURL` lets the same Chat Completions client target any OpenAI-compatible provider
    /// (OpenAI, DeepSeek, Qwen, Moonshot, …); `/chat/completions` is appended to it.
    init(baseURL: String = "https://api.openai.com/v1") {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.endpoint = URL(string: trimmed + "/chat/completions")
            ?? URL(string: "https://api.openai.com/v1/chat/completions")!
    }

    /// Sends `prompt` followed by `bubbleText` to `model` and returns the assistant's reply.
    ///
    /// - Throws: `OpenAiError` on a missing key, an HTTP error (the OpenAI error message is
    ///   surfaced when present), or an empty/unparseable response.
    nonisolated func complete(apiKey: String, model: String, prompt: String, bubbleText: String) async throws -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            throw OpenAiError(message: "Set your API key in Settings → Translation model.")
        }
        let body = Self.buildRequestBody(model: model, prompt: prompt, bubbleText: bubbleText)
        return try await perform(apiKey: key, body: body)
    }

    /// Sends `prompt` plus an image crop to `model` and returns the assistant's reply.
    ///
    /// The image is sent as a `data:` URL content part, matching OpenAI's Chat Completions vision
    /// input shape. The caller owns cropping/compression.
    nonisolated func completeImage(apiKey: String, model: String, prompt: String, image: AiChatImage) async throws -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            throw OpenAiError(message: "Set your API key in Settings → Translation model.")
        }
        let body = Self.buildImageRequestBody(model: model, prompt: prompt, image: image)
        return try await perform(apiKey: key, body: body)
    }

    // MARK: - HTTP

    private nonisolated func perform(apiKey: String, body: Data) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = readTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
        } catch let error as OpenAiError {
            throw error
        } catch {
            throw OpenAiError(message: error.localizedDescription)
        }

        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200...299).contains(code) {
            throw OpenAiError(message: Self.parseErrorMessage(code: code, data: data))
        }
        return try Self.parseResponse(data)
    }

    // MARK: - Body builders (pure, testable)

    /// Builds the JSON request body. The bubble text is appended after the prompt.
    static func buildRequestBody(model: String, prompt: String, bubbleText: String) -> Data {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = trimmedPrompt.isEmpty ? bubbleText : "\(trimmedPrompt)\n\n\(bubbleText)"
        let request = ChatRequest(
            model: resolvedModel(model),
            messages: [ChatMessage(role: "user", content: .text(content))]
        )
        return encode(request)
    }

    /// Builds the JSON request body for a single image crop plus text prompt.
    static func buildImageRequestBody(model: String, prompt: String, image: AiChatImage) -> Data {
        let mimeType = image.mimeType.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedMime = mimeType.isEmpty ? "image/png" : mimeType
        let base64 = image.base64Data.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageUrl = "data:\(resolvedMime);base64,\(base64)"
        let promptText = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        // Fallback mirrors AiChatDefaults.imagePrompt; inlined because that enum is MainActor-
        // isolated and this builder is nonisolated. Callers normally pass a non-empty prompt.
        let resolvedPrompt = promptText.isEmpty ? Self.fallbackImagePrompt : promptText
        let parts: [ChatContentPart] = [
            .init(type: "text", text: resolvedPrompt, imageUrl: nil),
            .init(type: "image_url", text: nil, imageUrl: .init(url: imageUrl)),
        ]
        let request = ChatRequest(
            model: resolvedModel(model),
            messages: [ChatMessage(role: "user", content: .parts(parts))]
        )
        return encode(request)
    }

    private static func resolvedModel(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallbackModel : trimmed
    }

    // Fallbacks mirror AiChatDefaults; inlined because that enum is MainActor-isolated and these
    // builders are nonisolated. Callers (the settings store) normally supply non-empty values.
    private static let fallbackModel = "gpt-5.5"
    private static let fallbackImagePrompt =
        "Transcribe any Japanese text visible in this image crop and translate it into " +
        "natural English. If useful, include a short vocabulary or grammar note. If no " +
        "readable Japanese text is visible, say so."

    private static func encode(_ request: ChatRequest) -> Data {
        (try? JSONEncoder().encode(request)) ?? Data("{}".utf8)
    }

    // MARK: - Response parsing (pure, testable)

    /// Extracts the assistant reply text from a successful chat-completions response body.
    static func parseResponse(_ data: Data) throws -> String {
        guard let response = try? JSONDecoder().decode(ChatResponse.self, from: data) else {
            throw OpenAiError(message: "Could not read the OpenAI response.")
        }
        let content = response.choices.first?.message?.content?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let content, !content.isEmpty else {
            throw OpenAiError(message: "OpenAI returned an empty response.")
        }
        return content
    }

    /// Turns an error-status response body into a user-facing message.
    static func parseErrorMessage(code: Int, data: Data) -> String {
        if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
           let message = envelope.error?.message,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return message
        }
        return "OpenAI request failed (HTTP \(code))."
    }

    // MARK: - Codable wire types

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [ChatMessage]
    }

    private struct ChatMessage: Encodable {
        let role: String
        let content: ChatContent

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

    /// A user message's content is either a plain string (text) or an array of parts (vision).
    private enum ChatContent {
        case text(String)
        case parts([ChatContentPart])
    }

    private struct ChatContentPart: Encodable {
        let type: String
        let text: String?
        let imageUrl: ImageUrl?

        struct ImageUrl: Encodable { let url: String }

        enum CodingKeys: String, CodingKey {
            case type, text
            case imageUrl = "image_url"
        }
    }

    private struct ChatResponse: Decodable {
        let choices: [Choice]

        enum CodingKeys: String, CodingKey { case choices }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            choices = try c.decodeIfPresent([Choice].self, forKey: .choices) ?? []
        }
    }

    private struct Choice: Decodable {
        let message: ChoiceMessage?
    }

    private struct ChoiceMessage: Decodable {
        let content: String?
    }

    private struct ErrorEnvelope: Decodable {
        let error: ApiError?
    }

    private struct ApiError: Decodable {
        let message: String?
        let type: String?
        let code: String?
    }
}
