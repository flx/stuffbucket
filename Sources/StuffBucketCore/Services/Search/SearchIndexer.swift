import Foundation

public struct SearchDocument: Hashable, Codable {
    public let id: UUID
    public let title: String
    public let content: String
    public let tags: [String]
    public let collection: String?
    public let aiSummary: String?
    public let isProtected: Bool

    public init(
        id: UUID,
        title: String,
        content: String,
        tags: [String] = [],
        collection: String? = nil,
        aiSummary: String? = nil,
        isProtected: Bool = false
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.tags = tags
        self.collection = collection
        self.aiSummary = aiSummary
        self.isProtected = isProtected
    }
}

public final class SearchIndexer {
    public static let shared = SearchIndexer()

    private init() {}

    public func index(_ document: SearchDocument) {
        // TODO: Replace with SQLite FTS5 indexing implementation.
    }

    public func remove(itemID: UUID) {
        // TODO: Remove from the search index.
    }

    public func search(_ query: SearchQuery) async -> [SearchResult] {
        // TODO: Execute ranked search with filters and snippets.
        return []
    }
}
