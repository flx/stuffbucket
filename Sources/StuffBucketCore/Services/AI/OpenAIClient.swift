import Foundation

public enum OpenAIClientError: Error, LocalizedError {
    case invalidResponse
    case httpStatus(Int, String?)
    case decodingFailed
    case emptyResponse

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
        case .emptyResponse:
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

        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content,
              !content.isEmpty else {
            throw OpenAIClientError.emptyResponse
        }

        return content
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

        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content,
              !content.isEmpty else {
            throw OpenAIClientError.emptyResponse
        }

        return content
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

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": messages
        ]

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

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": messages
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
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

private struct ChatCompletionResponse: Decodable {
    let choices: [Choice]
}

private struct Choice: Decodable {
    let message: Message
}

private struct Message: Decodable {
    let content: String
}
