import CoreData
import Foundation

public extension Item {
    static func create(in context: NSManagedObjectContext, type: ItemType = .note) -> Item {
        // Use the context's model to avoid Item.entity() ambiguity when multiple models are loaded.
        guard let entity = NSEntityDescription.entity(forEntityName: "Item", in: context) else {
            fatalError("Missing Item entity in managed object model.")
        }
        let item = Item(entity: entity, insertInto: context)
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

    var archiveStatusValue: ArchiveStatus? {
        guard let archiveStatus else { return nil }
        return ArchiveStatus(rawValue: archiveStatus)
    }

    var documentFileName: String? {
        guard let documentRelativePath, !documentRelativePath.isEmpty else { return nil }
        return URL(fileURLWithPath: documentRelativePath).lastPathComponent
    }

    var documentURL: URL? {
        guard let documentRelativePath, !documentRelativePath.isEmpty else { return nil }
        return DocumentStorage.url(forRelativePath: documentRelativePath)
    }

    var archivedPageURL: URL? {
        guard let htmlRelativePath, !htmlRelativePath.isEmpty else { return nil }
        return LinkStorage.url(forRelativePath: htmlRelativePath)
    }

    var archivedReaderURL: URL? {
        guard let id else { return nil }
        return LinkStorage.readerURL(for: id)
    }

    var displayTitle: String {
        if let title, !title.isEmpty {
            return title
        }
        if let linkTitle, !linkTitle.isEmpty {
            return linkTitle
        }
        if let fileName = documentFileName, !fileName.isEmpty {
            return fileName
        }
        if let textContent, !textContent.isEmpty {
            return TitleBuilder.title(from: textContent)
        }
        return "Untitled"
    }

    var isLinkItem: Bool {
        itemType == .link
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

private enum TitleBuilder {
    static func title(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Untitled" }
        let firstLine = trimmed.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).first ?? Substring(trimmed)
        let maxLength = 80
        if firstLine.count > maxLength {
            return String(firstLine.prefix(maxLength)) + "..."
        }
        return String(firstLine)
    }
}
