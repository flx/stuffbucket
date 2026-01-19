import Foundation
import CoreData

public enum TagSuggestionError: Error {
    case noAPIKey
    case noContent
    case invalidResponse
    case apiError(String)
}

public struct TagSuggestion: Identifiable, Hashable {
    public let tag: String
    public let isExisting: Bool

    public var id: String { tag }

    public init(tag: String, isExisting: Bool) {
        self.tag = tag
        self.isExisting = isExisting
    }
}

public final class TagSuggestionService {
    private let keyStorage: AIKeyStorage

    public init(keyStorage: AIKeyStorage = .shared) {
        self.keyStorage = keyStorage
    }

    public func suggestTags(
        for item: Item,
        existingLibraryTags: [String],
        maxSuggestions: Int = 5
    ) async throws -> [TagSuggestion] {
        guard let apiKey = keyStorage.currentAPIKey, !apiKey.isEmpty else {
            throw TagSuggestionError.noAPIKey
        }

        let content = extractContent(from: item)
        guard !content.isEmpty else {
            throw TagSuggestionError.noContent
        }

        let systemPrompt = buildSystemPrompt(existingTags: existingLibraryTags, maxSuggestions: maxSuggestions)
        let userPrompt = buildUserPrompt(content: content)

        let response: String
        let modelID = validModelID(for: keyStorage.selectedProvider)

        switch keyStorage.selectedProvider {
        case .anthropic:
            let client = AnthropicClient(apiKey: apiKey)
            response = try await client.suggestTags(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                model: modelID
            )
        case .openAI:
            let client = OpenAIClient(apiKey: apiKey)
            response = try await client.suggestTags(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                model: modelID
            )
        }

        let tags = parseTagResponse(response)
        let existingTagsLower = Set(existingLibraryTags.map { $0.lowercased() })

        return tags.map { tag in
            TagSuggestion(
                tag: tag,
                isExisting: existingTagsLower.contains(tag.lowercased())
            )
        }
    }

    private var defaultModelID: String {
        switch keyStorage.selectedProvider {
        case .anthropic:
            return AnthropicModelDefaults.defaultModelID
        case .openAI:
            return OpenAIModelDefaults.defaultModelID
        }
    }

    private func validModelID(for provider: AIProvider) -> String {
        guard let selectedModel = keyStorage.selectedModelID else {
            return defaultModelID
        }

        // Check if selected model is valid for the current provider
        switch provider {
        case .anthropic:
            if selectedModel.hasPrefix("claude") {
                return selectedModel
            }
            return AnthropicModelDefaults.defaultModelID
        case .openAI:
            if selectedModel.hasPrefix("gpt") {
                return selectedModel
            }
            return OpenAIModelDefaults.defaultModelID
        }
    }

    private func extractContent(from item: Item) -> String {
        var parts: [String] = []

        if let title = item.title, !title.isEmpty {
            parts.append("Title: \(title)")
        } else if let linkTitle = item.linkTitle, !linkTitle.isEmpty {
            parts.append("Title: \(linkTitle)")
        }

        if let textContent = item.textContent, !textContent.isEmpty {
            let truncated = String(textContent.prefix(2000))
            parts.append("Content: \(truncated)")
        }

        if let linkURL = item.linkURL, !linkURL.isEmpty {
            parts.append("URL: \(linkURL)")
        }

        // Try to read reader archive content
        if let readerURL = item.archivedReaderURL,
           let readerContent = extractTextFromHTML(at: readerURL) {
            let truncated = String(readerContent.prefix(3000))
            parts.append("Article: \(truncated)")
        }

        return parts.joined(separator: "\n\n")
    }

    private func extractTextFromHTML(at url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let html = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return HTMLTextExtractor.extractText(from: html)
    }

    private func buildSystemPrompt(existingTags: [String], maxSuggestions: Int) -> String {
        var prompt = """
        You are a tagging assistant for a personal knowledge base. Your job is to suggest relevant tags for saved items.

        Guidelines:
        - Suggest up to \(maxSuggestions) tags that describe the content
        - Tags should be lowercase, concise (1-3 words), and use hyphens for multi-word tags
        - STRONGLY prefer using existing tags from the library when they apply
        - Only create new tags if no existing tag fits well
        - Focus on topics, themes, and categories rather than generic terms
        - Respond with ONLY a JSON array of tag strings, nothing else

        """

        if !existingTags.isEmpty {
            let tagList = existingTags.prefix(100).joined(separator: ", ")
            prompt += "\nExisting tags in the library: \(tagList)"
        }

        prompt += "\n\nResponse format: [\"tag1\", \"tag2\", \"tag3\"]"

        return prompt
    }

    private func buildUserPrompt(content: String) -> String {
        "Suggest tags for this item:\n\n\(content)"
    }

    private func parseTagResponse(_ response: String) -> [String] {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try to extract JSON array from response
        if let startIndex = trimmed.firstIndex(of: "["),
           let endIndex = trimmed.lastIndex(of: "]") {
            let jsonString = String(trimmed[startIndex...endIndex])
            if let data = jsonString.data(using: .utf8),
               let tags = try? JSONDecoder().decode([String].self, from: data) {
                return tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        }

        // Fallback: try to parse comma-separated or newline-separated tags
        let parts = trimmed
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return parts
    }
}
