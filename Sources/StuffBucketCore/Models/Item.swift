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

    /// Resolves the document URL using fallback logic (iCloud Drive -> CloudKit bundle -> cache)
    var resolvedDocumentURL: DocumentResolver.ResolvedDocument? {
        DocumentResolver.resolve(item: self)
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
        // Prioritize text content (snippets) over link title
        if let textContent, !textContent.isEmpty {
            return TitleBuilder.title(from: textContent)
        }
        if let linkTitle, !linkTitle.isEmpty {
            return linkTitle
        }
        if let fileName = documentFileName, !fileName.isEmpty {
            return fileName
        }
        return "Untitled"
    }

    var isLinkItem: Bool {
        hasLink
    }

    var hasLink: Bool {
        guard let linkURL, !linkURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return true
    }

    var hasDocument: Bool {
        guard let documentRelativePath, !documentRelativePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return true
    }

    var hasText: Bool {
        guard let textContent, !textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return true
    }

    var tagList: [String] {
        TagCodec.decode(tags)
    }

    func setTagList(_ tags: [String]) {
        self.tags = TagCodec.encode(tags)
    }

    /// Returns tags excluding collection: prefixed tags and the trashcan tag
    var displayTagList: [String] {
        tagList.filter { !CollectionTagParser.isCollectionTag($0) && $0 != Self.trashTag }
    }

    /// Sets the display tags (non-collection tags), preserving existing collection tags
    func setDisplayTagList(_ displayTags: [String]) {
        let collectionTags = tagList.filter { CollectionTagParser.isCollectionTag($0) }
        let trashTags = tagList.filter { $0 == Self.trashTag }
        setTagList(displayTags + collectionTags + trashTags)
    }

    /// Returns collection names extracted from collection: prefixed tags
    var collectionList: [String] {
        tagList.compactMap { CollectionTagParser.collectionName(from: $0) }
    }

    /// Sets the collections, preserving existing non-collection tags
    func setCollectionList(_ collections: [String]) {
        let nonCollectionTags = tagList.filter { !CollectionTagParser.isCollectionTag($0) }
        let collectionTags = collections.map { CollectionTagParser.tag(forCollection: $0) }
        setTagList(nonCollectionTags + collectionTags)
    }

    /// Adds item to a collection
    func addToCollection(_ name: String) {
        var collections = collectionList
        let normalizedName = name.trimmingCharacters(in: .whitespaces)
        if !collections.contains(where: { $0.lowercased() == normalizedName.lowercased() }) {
            collections.append(normalizedName)
            setCollectionList(collections)
        }
    }

    /// Removes item from a collection
    func removeFromCollection(_ name: String) {
        let normalizedName = name.lowercased()
        let collections = collectionList.filter { $0.lowercased() != normalizedName }
        setCollectionList(collections)
    }

    var collectionDisplayName: String? {
        // First check tag-based collections
        if let firstCollection = collectionList.first {
            return firstCollection
        }
        // Legacy: check sourceFolderPath (for Safari imports)
        if let sourceFolderPath, !sourceFolderPath.isEmpty {
            return sourceFolderPath
        }
        return nil
    }

    // MARK: - Trash

    static let trashTag = "trashcan"

    var isTrashed: Bool {
        trashedAt != nil
    }

    /// Moves the item to trash by adding the trashcan tag and setting trashedAt
    func moveToTrash() {
        var currentTags = tagList
        if !currentTags.contains(Self.trashTag) {
            currentTags.append(Self.trashTag)
            setTagList(currentTags)
        }
        trashedAt = Date()
        updatedAt = Date()
    }

    /// Restores the item from trash by removing the trashcan tag and clearing trashedAt
    func restoreFromTrash() {
        var currentTags = tagList
        currentTags.removeAll { $0 == Self.trashTag }
        setTagList(currentTags)
        trashedAt = nil
        updatedAt = Date()
    }

    /// Returns true if the item has been in trash for more than the specified number of days
    func isExpiredInTrash(days: Int = 10) -> Bool {
        guard let trashedAt else { return false }
        let expirationDate = Calendar.current.date(byAdding: .day, value: days, to: trashedAt) ?? trashedAt
        return Date() > expirationDate
    }
}

private enum TagCodec {
    static func decode(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var parsed: [String] = []
        if trimmed.first == "[" {
            if let data = trimmed.data(using: .utf8),
               let tags = try? JSONDecoder().decode([String].self, from: data) {
                parsed = tags
            }
        }
        if parsed.isEmpty {
            let parts = trimmed.split(whereSeparator: { $0 == "," || $0 == "\n" })
            parsed = parts.map(String.init)
        }
        return normalize(parsed)
    }

    static func encode(_ tags: [String]) -> String? {
        let cleaned = normalize(tags)
        guard !cleaned.isEmpty else { return nil }
        if let data = try? JSONEncoder().encode(cleaned),
           let encoded = String(data: data, encoding: .utf8) {
            return encoded
        }
        return cleaned.joined(separator: ",")
    }

    private static func normalize(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var results: [String] = []

        for raw in tags {
            guard let canonical = canonicalTag(raw) else { continue }
            let key = dedupeKey(for: canonical)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            results.append(canonical)
        }

        return results
    }

    private static func canonicalTag(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowercased = trimmed.lowercased()
        if lowercased == Item.trashTag {
            return Item.trashTag
        }
        if CollectionTagParser.isCollectionTag(trimmed) {
            guard let name = CollectionTagParser.collectionName(from: trimmed), !name.isEmpty else { return nil }
            return CollectionTagParser.tag(forCollection: name)
        }
        return trimmed
    }

    private static func dedupeKey(for tag: String) -> String {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        if lowercased == Item.trashTag {
            return Item.trashTag
        }
        if lowercased.hasPrefix(CollectionTagParser.prefix) {
            let name = String(lowercased.dropFirst(CollectionTagParser.prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(CollectionTagParser.prefix)\(name)"
        }
        return lowercased
    }
}

private enum TitleBuilder {
    static func title(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Untitled" }

        // Get first line
        let firstLine = trimmed.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).first ?? Substring(trimmed)

        // Take first ~6 words
        let words = firstLine.split(separator: " ", omittingEmptySubsequences: true)
        let maxWords = 6
        if words.count <= maxWords {
            let result = String(firstLine)
            // Still truncate if very long single "word" (like a URL)
            if result.count > 50 {
                return String(result.prefix(47)) + "..."
            }
            return result
        }

        let preview = words.prefix(maxWords).joined(separator: " ")
        return preview + "..."
    }
}
