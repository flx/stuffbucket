import Foundation
import CoreData
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

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
    private static let anthropicMaxImageBytes = 5 * 1_024 * 1_024

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

        let systemPrompt = buildSystemPrompt(existingTags: existingLibraryTags, maxSuggestions: maxSuggestions)
        let modelID = validModelID(for: keyStorage.selectedProvider)

        let response: String

        // Check if item has a document attachment
        if let docInfo = extractDocumentData(from: item) {
            let preparedDocInfo = try prepareDocumentForProvider(docInfo)
            switch preparedDocInfo.type {
            case .image, .pdf:
                // Send images and PDFs to vision/document API
                let userPrompt = buildDocumentUserPrompt(item: item, documentType: preparedDocInfo.type)
                response = try await suggestTagsWithDocument(
                    apiKey: apiKey,
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    documentData: preparedDocInfo.data,
                    mediaType: preparedDocInfo.mediaType,
                    model: modelID
                )
            case .text:
                // Extract text from text documents and include in content
                var content = extractContent(from: item)
                if let docText = extractTextFromDocument(docInfo.data) {
                    let truncated = String(docText.prefix(4000))
                    content += "\n\nDocument content:\n\(truncated)"
                }
                guard !content.isEmpty else {
                    throw TagSuggestionError.noContent
                }
                let userPrompt = buildUserPrompt(content: content)
                response = try await suggestTagsWithText(
                    apiKey: apiKey,
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    model: modelID
                )
            }
        } else {
            let content = extractContent(from: item)
            guard !content.isEmpty else {
                throw TagSuggestionError.noContent
            }

            let userPrompt = buildUserPrompt(content: content)
            response = try await suggestTagsWithText(
                apiKey: apiKey,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                model: modelID
            )
        }

        let tags = Array(parseTagResponse(response).prefix(maxSuggestions))
        let existingTagsLower = Set(existingLibraryTags.map { $0.lowercased() })

        return tags.map { tag in
            TagSuggestion(
                tag: tag,
                isExisting: existingTagsLower.contains(tag.lowercased())
            )
        }
    }

    private func suggestTagsWithDocument(
        apiKey: String,
        systemPrompt: String,
        userPrompt: String,
        documentData: Data,
        mediaType: String,
        model: String
    ) async throws -> String {
        switch keyStorage.selectedProvider {
        case .anthropic:
            let client = AnthropicClient(apiKey: apiKey)
            return try await client.suggestTagsWithDocument(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                documentData: documentData,
                mediaType: mediaType,
                model: model
            )
        case .openAI:
            let client = OpenAIClient(apiKey: apiKey)
            return try await client.suggestTagsWithDocument(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                documentData: documentData,
                mediaType: mediaType,
                model: model
            )
        }
    }

    private func suggestTagsWithText(
        apiKey: String,
        systemPrompt: String,
        userPrompt: String,
        model: String
    ) async throws -> String {
        switch keyStorage.selectedProvider {
        case .anthropic:
            let client = AnthropicClient(apiKey: apiKey)
            return try await client.suggestTags(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                model: model
            )
        case .openAI:
            let client = OpenAIClient(apiKey: apiKey)
            return try await client.suggestTags(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                model: model
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

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "heic", "heif"
    ]

    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "rtf", "json", "xml", "csv", "log",
        "swift", "js", "ts", "py", "rb", "java", "c", "cpp", "h", "m",
        "html", "css", "sh", "yaml", "yml"
    ]

    private enum DocumentType {
        case image
        case pdf
        case text
    }

    private struct DocumentInfo {
        let data: Data
        let mediaType: String
        let type: DocumentType
    }

    private func extractDocumentData(from item: Item) -> DocumentInfo? {
        guard let documentURL = item.documentURL else { return nil }
        let ext = documentURL.pathExtension.lowercased()

        // Check for images
        if Self.imageExtensions.contains(ext) {
            guard let data = try? Data(contentsOf: documentURL) else { return nil }
            let mediaType: String
            switch ext {
            case "jpg", "jpeg":
                mediaType = "image/jpeg"
            case "png":
                mediaType = "image/png"
            case "gif":
                mediaType = "image/gif"
            case "webp":
                mediaType = "image/webp"
            case "heic", "heif":
                if let converted = convertImageDataToJPEG(data) {
                    return DocumentInfo(data: converted, mediaType: "image/jpeg", type: .image)
                }
                mediaType = "image/heic"
            default:
                mediaType = "image/jpeg"
            }
            return DocumentInfo(data: data, mediaType: mediaType, type: .image)
        }

        // Check for PDFs
        if ext == "pdf" {
            guard let data = try? Data(contentsOf: documentURL) else { return nil }
            return DocumentInfo(data: data, mediaType: "application/pdf", type: .pdf)
        }

        // Check for text files
        if Self.textExtensions.contains(ext) {
            guard let text = try? String(contentsOf: documentURL, encoding: .utf8),
                  let data = text.data(using: .utf8) else { return nil }
            return DocumentInfo(data: data, mediaType: "text/plain", type: .text)
        }

        return nil
    }

    private func extractTextFromDocument(_ data: Data) -> String? {
        return String(data: data, encoding: .utf8)
    }

    private func prepareDocumentForProvider(_ docInfo: DocumentInfo) throws -> DocumentInfo {
        guard keyStorage.selectedProvider == .anthropic, docInfo.type == .image else {
            return docInfo
        }

        if docInfo.data.count <= Self.anthropicMaxImageBytes {
            return docInfo
        }

        guard let compressed = compressImageForAnthropic(docInfo.data),
              compressed.count <= Self.anthropicMaxImageBytes else {
            throw TagSuggestionError.apiError(
                "Image is too large for Claude. Please use a smaller image (max 5 MB)."
            )
        }

        return DocumentInfo(data: compressed, mediaType: "image/jpeg", type: .image)
    }

    private func compressImageForAnthropic(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        var bestCandidate: Data?
        let maxPixelSteps: [Int] = [3072, 2560, 2048, 1600, 1280, 1024, 768]
        let qualitySteps: [CGFloat] = [0.88, 0.78, 0.68, 0.58, 0.48, 0.38, 0.30]

        for maxPixel in maxPixelSteps {
            guard let image = makeThumbnail(from: source, maxPixelSize: maxPixel) else { continue }
            for quality in qualitySteps {
                guard let encoded = encodeJPEG(image: image, quality: quality) else { continue }
                if bestCandidate == nil || encoded.count < bestCandidate!.count {
                    bestCandidate = encoded
                }
                if encoded.count <= Self.anthropicMaxImageBytes {
                    return encoded
                }
            }
        }

        return bestCandidate
    }

    private func makeThumbnail(from source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private func encodeJPEG(image: CGImage, quality: CGFloat) -> Data? {
        let destinationData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            destinationData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return destinationData as Data
    }

    private func convertImageDataToJPEG(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        return encodeJPEG(image: image, quality: 0.9)
    }

    private func buildDocumentUserPrompt(item: Item, documentType: DocumentType) -> String {
        let typeDescription: String
        switch documentType {
        case .image:
            typeDescription = "image"
        case .pdf:
            typeDescription = "PDF document"
        case .text:
            typeDescription = "text document"
        }

        var parts: [String] = ["Suggest tags for this \(typeDescription)."]

        if let title = item.title, !title.isEmpty {
            parts.append("Title: \(title)")
        }

        if let textContent = item.textContent, !textContent.isEmpty {
            let truncated = String(textContent.prefix(500))
            parts.append("Notes: \(truncated)")
        }

        return parts.joined(separator: "\n\n")
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
