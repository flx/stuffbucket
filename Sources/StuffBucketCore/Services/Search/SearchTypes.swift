import Foundation

public enum SearchSort: String, CaseIterable, Codable {
    case relevance
    case recency
}

public enum SearchFilterKey: String, CaseIterable, Codable {
    case type
    case tag
    case collection
    case source
}

public struct SearchFilter: Hashable, Codable {
    public let key: SearchFilterKey
    public let value: String

    public init(key: SearchFilterKey, value: String) {
        self.key = key
        self.value = value
    }
}

public struct SearchQuery: Hashable, Codable {
    public let text: String
    public let filters: [SearchFilter]
    public let sort: SearchSort

    public init(text: String, filters: [SearchFilter] = [], sort: SearchSort = .relevance) {
        self.text = text
        self.filters = filters
        self.sort = sort
    }
}

public struct SearchResult: Hashable, Codable {
    public let itemID: UUID
    public let title: String
    public let snippet: String?

    public init(itemID: UUID, title: String, snippet: String? = nil) {
        self.itemID = itemID
        self.title = title
        self.snippet = snippet
    }
}

extension SearchResult: Identifiable {
    public var id: UUID { itemID }
}
