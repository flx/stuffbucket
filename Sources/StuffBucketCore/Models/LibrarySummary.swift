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

public enum LibrarySummaryBuilder {
    public static func tags(from items: [Item]) -> [TagSummary] {
        var counts: [String: Int] = [:]
        for item in items {
            for tag in item.tagList {
                counts[tag, default: 0] += 1
            }
        }
        return counts
            .map { TagSummary(name: $0.key, count: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func collections(from items: [Item]) -> [CollectionSummary] {
        var counts: [String: Int] = [:]
        for item in items {
            guard let name = item.collectionDisplayName else { continue }
            counts[name, default: 0] += 1
        }
        return counts
            .map { CollectionSummary(name: $0.key, count: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
