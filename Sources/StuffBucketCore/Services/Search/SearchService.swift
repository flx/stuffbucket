import Foundation

public struct SearchService {
    public init() {}

    public func search(text: String, sort: SearchSort = .relevance) async -> [SearchResult] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let query = SearchQueryParser().parse(trimmed, sort: sort)
        return await SearchIndexer.shared.search(query)
    }
}
