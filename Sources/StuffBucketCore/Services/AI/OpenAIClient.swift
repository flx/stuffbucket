import Foundation

public enum OpenAIClientError: Error, LocalizedError {
    case invalidResponse
    case httpStatus(Int, String?)
    case decodingFailed
    case emptyResponse(String?)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from OpenAI"
        case .httpStatus(let code, let message):
            if let message {
                return "OpenAI error (\(code)): \(message)"
            }
            return "OpenAI error: HTTP \(code)"
        case .decodingFailed:
            return "Failed to decode OpenAI response"
        case .emptyResponse(let details):
            if let details, !details.isEmpty {
                return "OpenAI returned no text: \(details)"
            }
            return "OpenAI returned an empty response"
        }
    }
}

public struct OpenAIClient {
    private let apiKey: String
    private let session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    public func validateAPIKey() async throws -> [String] {
        let request = makeRequest(path: "/v1/models", method: "GET")
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)

        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return decoded.data.map { $0.id }.sorted()
    }

    public static func chatModelIDs(from modelIDs: [String]) -> [String] {
        modelIDs.filter(isLikelyChatModel).sorted()
    }

    private static func isLikelyChatModel(_ modelID: String) -> Bool {
        let normalized = modelID.lowercased()

        if normalized.hasPrefix("ft:") { return false }
        if normalized.contains("embedding") { return false }
        if normalized.contains("moderation") { return false }
        if normalized.contains("image") { return false }
        if normalized.contains("audio") { return false }
        if normalized.contains("realtime") { return false }
        if normalized.contains("transcribe") { return false }
        if normalized.contains("tts") { return false }
        if normalized.hasPrefix("whisper") { return false }

        return normalized.hasPrefix("gpt-")
            || normalized.hasPrefix("chatgpt-")
            || normalized.hasPrefix("o1")
            || normalized.hasPrefix("o3")
            || normalized.hasPrefix("o4")
            || normalized.hasPrefix("o5")
    }

    public func suggestTags(
        systemPrompt: String,
        userPrompt: String,
        model: String,
        maxTokens: Int = 500
    ) async throws -> String {
        let request = makeChatRequest(
            model: model,
            messages: [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            maxTokens: maxTokens
        )

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try extractAssistantText(from: data)
    }

    public func suggestTagsWithDocument(
        systemPrompt: String,
        userPrompt: String,
        documentData: Data,
        mediaType: String,
        model: String,
        maxTokens: Int = 500
    ) async throws -> String {
        let base64Data = documentData.base64EncodedString()
        let dataURL = "data:\(mediaType);base64,\(base64Data)"

        // OpenAI uses different content types for images vs files (PDFs)
        let contentBlock: [String: Any]
        if mediaType == "application/pdf" {
            contentBlock = [
                "type": "file",
                "file": [
                    "filename": "document.pdf",
                    "file_data": dataURL
                ]
            ]
        } else {
            contentBlock = [
                "type": "image_url",
                "image_url": ["url": dataURL]
            ]
        }

        let userContent: [[String: Any]] = [
            contentBlock,
            [
                "type": "text",
                "text": userPrompt
            ]
        ]

        let request = makeChatRequestWithContent(
            model: model,
            systemPrompt: systemPrompt,
            userContent: userContent,
            maxTokens: maxTokens
        )

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try extractAssistantText(from: data)
    }

    private func makeRequest(path: String, method: String) -> URLRequest {
        let url = URL(string: "https://api.openai.com\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func makeChatRequest(
        model: String,
        messages: [[String: String]],
        maxTokens: Int
    ) -> URLRequest {
        var request = makeRequest(path: "/v1/chat/completions", method: "POST")

        var body: [String: Any] = [
            "model": model,
            "messages": messages
        ]
        body[tokenLimitParameterName(for: model)] = tokenLimitValue(for: model, maxTokens: maxTokens)
        if let reasoningEffort = reasoningEffort(for: model) {
            body["reasoning_effort"] = reasoningEffort
        }

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func makeChatRequestWithContent(
        model: String,
        systemPrompt: String,
        userContent: [[String: Any]],
        maxTokens: Int
    ) -> URLRequest {
        var request = makeRequest(path: "/v1/chat/completions", method: "POST")

        let messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": userContent]
        ]

        var body: [String: Any] = [
            "model": model,
            "messages": messages
        ]
        body[tokenLimitParameterName(for: model)] = tokenLimitValue(for: model, maxTokens: maxTokens)
        if let reasoningEffort = reasoningEffort(for: model) {
            body["reasoning_effort"] = reasoningEffort
        }

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func tokenLimitParameterName(for model: String) -> String {
        let normalized = model.lowercased()
        if normalized.hasPrefix("gpt-5")
            || normalized.hasPrefix("o1")
            || normalized.hasPrefix("o3")
            || normalized.hasPrefix("o4")
            || normalized.hasPrefix("o5") {
            return "max_completion_tokens"
        }
        return "max_tokens"
    }

    private func tokenLimitValue(for model: String, maxTokens: Int) -> Int {
        guard tokenLimitParameterName(for: model) == "max_completion_tokens" else {
            return maxTokens
        }
        // Reasoning models can consume completion budget on internal reasoning.
        // Keep a higher floor so we still get visible tag output.
        return max(maxTokens, 1200)
    }

    private func reasoningEffort(for model: String) -> String? {
        let normalized = model.lowercased()
        guard tokenLimitParameterName(for: model) == "max_completion_tokens" else {
            return nil
        }
        if normalized.hasPrefix("gpt-5-pro") {
            return "high"
        }
        return "low"
    }

    private func extractAssistantText(from data: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let firstChoice = choices.first else {
            throw OpenAIClientError.decodingFailed
        }

        let finishReason = firstChoice["finish_reason"] as? String
        let message = firstChoice["message"] as? [String: Any]

        if let content = message?["content"] as? String {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        if let parts = message?["content"] as? [[String: Any]] {
            let text = parts.compactMap { part -> String? in
                guard let type = part["type"] as? String, type == "text" else { return nil }
                return part["text"] as? String
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

            if !text.isEmpty {
                return text
            }

            if let refusal = parts.compactMap({ part -> String? in
                guard let type = part["type"] as? String, type == "refusal" else { return nil }
                return part["refusal"] as? String
            }).first,
               !refusal.isEmpty {
                throw OpenAIClientError.emptyResponse(refusal)
            }
        }

        if let refusal = message?["refusal"] as? String, !refusal.isEmpty {
            throw OpenAIClientError.emptyResponse(refusal)
        }

        if finishReason == "length" {
            throw OpenAIClientError.emptyResponse(
                "Token limit reached before a visible answer was produced."
            )
        }
        if finishReason == "content_filter" {
            throw OpenAIClientError.emptyResponse(
                "Content was filtered by the model safety system."
            )
        }
        if finishReason == "tool_calls" {
            throw OpenAIClientError.emptyResponse(
                "Model returned tool calls instead of text."
            )
        }

        throw OpenAIClientError.emptyResponse(nil)
    }

    private func validate(response: URLResponse, data: Data? = nil) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIClientError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            var errorMessage: String?
            if let data {
                errorMessage = String(data: data, encoding: .utf8)
            }
            throw OpenAIClientError.httpStatus(httpResponse.statusCode, errorMessage)
        }
    }
}

public enum OpenAIModelDefaults {
    public static let defaultModelID = "gpt-4o"
    public static let availableModels = [
        "gpt-4o",
        "gpt-4o-mini",
        "gpt-4-turbo",
        "gpt-3.5-turbo"
    ]
    public static let recommendedModels = [
        "gpt-4o",
        "gpt-4o-mini"
    ]
}

private struct ModelsResponse: Decodable {
    let data: [ModelInfo]
}

private struct ModelInfo: Decodable {
    let id: String
}
