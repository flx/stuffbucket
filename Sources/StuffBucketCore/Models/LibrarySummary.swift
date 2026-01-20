import Foundation

public struct TagSummary: Identifiable, Hashable {
    public let name: String
    public let count: Int

    public var id: String {
        name
    }
}

public struct CollectionSummary: Identifiable, Hashable {
    public let name: String
    public let count: Int

    public var id: String {
        name
    }
}

public enum CollectionTagParser {
    public static let prefix = "collection:"

    /// Extracts collection name from a tag if it has the collection: prefix
    public static func collectionName(from tag: String) -> String? {
        let trimmed = tag.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix(prefix) else { return nil }
        let name = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// Creates a collection tag from a collection name
    public static func tag(forCollection name: String) -> String {
        "\(prefix)\(name)"
    }

    /// Returns true if the tag is a collection tag
    public static func isCollectionTag(_ tag: String) -> Bool {
        tag.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix(prefix)
    }
}

public enum LibrarySummaryBuilder {
    /// Returns tag summaries excluding collection: prefixed tags
    public static func tags(from items: [Item]) -> [TagSummary] {
        var counts: [String: Int] = [:]
        var displayNames: [String: String] = [:]
        for item in items {
            for tag in item.tagList {
                // Skip collection tags and trashcan tag
                if CollectionTagParser.isCollectionTag(tag) || tag == Item.trashTag {
                    continue
                }
                let key = tag.lowercased()
                if displayNames[key] == nil {
                    displayNames[key] = tag
                }
                counts[key, default: 0] += 1
            }
        }
        return counts
            .map { TagSummary(name: displayNames[$0.key] ?? $0.key, count: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Returns collection summaries extracted from collection: prefixed tags
    public static func collections(from items: [Item]) -> [CollectionSummary] {
        var counts: [String: Int] = [:]
        var displayNames: [String: String] = [:]
        for item in items {
            for collectionName in item.collectionList {
                // Use lowercased name for case-insensitive grouping, but preserve first seen casing
                let trimmed = collectionName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let key = trimmed.lowercased()
                if displayNames[key] == nil {
                    displayNames[key] = trimmed
                }
                counts[key, default: 0] += 1
            }
        }
        return counts
            .map { CollectionSummary(name: displayNames[$0.key] ?? $0.key, count: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
