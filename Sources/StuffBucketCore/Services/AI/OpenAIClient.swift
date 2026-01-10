import Foundation

public enum OpenAIClientError: Error {
    case invalidResponse
    case httpStatus(Int)
    case decodingFailed
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
        try validate(response: response)

        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return decoded.data.map { $0.id }.sorted()
    }

    private func makeRequest(path: String, method: String) -> URLRequest {
        let url = URL(string: "https://api.openai.com\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func validate(response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIClientError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw OpenAIClientError.httpStatus(httpResponse.statusCode)
        }
    }
}

private struct ModelsResponse: Decodable {
    let data: [ModelInfo]
}

private struct ModelInfo: Decodable {
    let id: String
}
