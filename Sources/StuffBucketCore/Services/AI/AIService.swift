import Foundation

public enum AIServiceError: Error {
    case missingAPIKey
    case notImplemented
}

public final class AIService: ObservableObject {
    public static let shared = AIService()

    @MainActor @Published public private(set) var availableModels: [String] = []

    private init() {}

    public func validateAPIKey(_ apiKey: String) async throws -> [String] {
        let client = OpenAIClient(apiKey: apiKey)
        let models = try await client.validateAPIKey()
        await MainActor.run {
            availableModels = models
        }
        return models
    }

    public func summarize(text: String, title: String?, apiKey: String, model: String) async throws -> String {
        guard !apiKey.isEmpty else {
            throw AIServiceError.missingAPIKey
        }
        // TODO: Implement Responses API call for summarization.
        throw AIServiceError.notImplemented
    }
}
