import CoreData
import Foundation

public extension Item {
    static func create(in context: NSManagedObjectContext, type: ItemType = .note) -> Item {
        let item = Item(context: context)
        item.id = UUID()
        let now = Date()
        item.createdAt = now
        item.updatedAt = now
        item.type = type.rawValue
        return item
    }

    var itemType: ItemType? {
        ItemType(rawValue: type ?? "")
    }

    var sourceType: ItemSource? {
        guard let source else { return nil }
        return ItemSource(rawValue: source)
    }

    var tagList: [String] {
        TagCodec.decode(tags)
    }

    func setTagList(_ tags: [String]) {
        self.tags = TagCodec.encode(tags)
    }

    var collectionDisplayName: String? {
        if let sourceFolderPath, !sourceFolderPath.isEmpty {
            return sourceFolderPath
        }
        return collectionID?.uuidString
    }
}

private enum TagCodec {
    static func decode(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.first == "[" {
            if let data = trimmed.data(using: .utf8),
               let tags = try? JSONDecoder().decode([String].self, from: data) {
                return tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            }
        }
        let parts = trimmed.split(whereSeparator: { $0 == "," || $0 == "\n" })
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static func encode(_ tags: [String]) -> String? {
        let cleaned = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }
        if let data = try? JSONEncoder().encode(cleaned),
           let encoded = String(data: data, encoding: .utf8) {
            return encoded
        }
        return cleaned.joined(separator: ",")
    }
}
