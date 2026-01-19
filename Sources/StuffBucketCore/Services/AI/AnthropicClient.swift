import Foundation

public enum AnthropicClientError: Error, LocalizedError {
    case invalidResponse
    case httpStatus(Int, String?)
    case decodingFailed
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from Claude"
        case .httpStatus(let code, let message):
            if let message {
                return "Claude error (\(code)): \(message)"
            }
            return "Claude error: HTTP \(code)"
        case .decodingFailed:
            return "Failed to decode Claude response"
        case .emptyResponse:
            return "Claude returned an empty response"
        }
    }
}

public struct AnthropicClient {
    private let apiKey: String
    private let session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    public func validateAPIKey() async throws -> [String] {
        // Anthropic doesn't have a models list endpoint like OpenAI
        // We'll return the known models and validate by making a minimal request
        let models = AnthropicModelDefaults.availableModels

        // Validate by checking if the key works with a minimal message
        let request = makeMessagesRequest(
            model: AnthropicModelDefaults.defaultModelID,
            messages: [["role": "user", "content": "Hi"]],
            maxTokens: 1
        )

        let (_, response) = try await session.data(for: request)
        try validate(response: response)

        return models
    }

    public func suggestTags(
        systemPrompt: String,
        userPrompt: String,
        model: String,
        maxTokens: Int = 500
    ) async throws -> String {
        let request = makeMessagesRequest(
            model: model,
            messages: [["role": "user", "content": userPrompt]],
            maxTokens: maxTokens,
            system: systemPrompt
        )

        let (data, response) = try await session.data(for: request)
        try validate(response: response)

        let decoded = try JSONDecoder().decode(MessagesResponse.self, from: data)
        guard let textContent = decoded.content.first(where: { $0.type == "text" }),
              !textContent.text.isEmpty else {
            throw AnthropicClientError.emptyResponse
        }

        return textContent.text
    }

    private func makeMessagesRequest(
        model: String,
        messages: [[String: String]],
        maxTokens: Int,
        system: String? = nil
    ) -> URLRequest {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": messages
        ]

        if let system {
            body["system"] = system
        }

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func validate(response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AnthropicClientError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw AnthropicClientError.httpStatus(httpResponse.statusCode, nil)
        }
    }
}

private struct MessagesResponse: Decodable {
    let content: [ContentBlock]
}

private struct ContentBlock: Decodable {
    let type: String
    let text: String
}

public enum AnthropicModelDefaults {
    public static let defaultModelID = "claude-sonnet-4-20250514"
    public static let availableModels = [
        "claude-sonnet-4-20250514",
        "claude-opus-4-20250514",
        "claude-3-5-sonnet-20241022",
        "claude-3-5-haiku-20241022"
    ]
    public static let recommendedModels = [
        "claude-sonnet-4-20250514",
        "claude-3-5-haiku-20241022"
    ]
}
