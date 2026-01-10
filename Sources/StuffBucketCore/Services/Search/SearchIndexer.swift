import Foundation
import CoreData

public struct SearchDocument: Hashable, Codable {
    public let id: UUID
    public let title: String
    public let content: String
    public let tags: [String]
    public let collection: String?
    public let aiSummary: String?
    public let isProtected: Bool
    public let type: ItemType?
    public let source: ItemSource?

    public init(
        id: UUID,
        title: String,
        content: String,
        tags: [String] = [],
        collection: String? = nil,
        aiSummary: String? = nil,
        isProtected: Bool = false,
        type: ItemType? = nil,
        source: ItemSource? = nil
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.tags = tags
        self.collection = collection
        self.aiSummary = aiSummary
        self.isProtected = isProtected
        self.type = type
        self.source = source
    }
}

public final class SearchIndexer {
    public static let shared = SearchIndexer()

    private var observer: NSObjectProtocol?

    private init() {}

    public func startObserving(context: NSManagedObjectContext) {
        observer = NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextObjectsDidChange,
            object: context,
            queue: nil
        ) { [weak self] notification in
            self?.handleChange(notification)
        }
    }

    public func stopObserving() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
    }

    public func index(_ document: SearchDocument) {
        SearchDatabase.shared.upsert(document: document)
    }

    public func remove(itemID: UUID) {
        SearchDatabase.shared.delete(itemID: itemID)
    }

    public func index(items: [Item]) {
        for item in items {
            index(item: item)
        }
    }

    public func index(item: Item) {
        guard let id = item.id else { return }
        let title = item.displayTitle
        var contentParts: [String] = []
        if let textContent = item.textContent, !textContent.isEmpty {
            contentParts.append(textContent)
        }
        if let linkTitle = item.linkTitle, !linkTitle.isEmpty, linkTitle != title {
            contentParts.append(linkTitle)
        }
        if let linkURL = item.linkURL, !linkURL.isEmpty {
            contentParts.append(linkURL)
        }
        if let documentName = item.documentFileName, !documentName.isEmpty {
            contentParts.append(documentName)
        }
        let content = contentParts.joined(separator: "\n")
        let document = SearchDocument(
            id: id,
            title: title,
            content: content,
            tags: item.tagList,
            collection: item.collectionDisplayName,
            aiSummary: item.aiSummary,
            isProtected: item.isProtected,
            type: item.itemType,
            source: item.sourceType
        )
        index(document)
    }

    public func search(_ query: SearchQuery) async -> [SearchResult] {
        return SearchDatabase.shared.search(query: query)
    }

    private func handleChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo else { return }

        if let inserted = userInfo[NSInsertedObjectsKey] as? Set<NSManagedObject> {
            for object in inserted {
                guard let item = object as? Item else { continue }
                index(item: item)
            }
        }

        if let updated = userInfo[NSUpdatedObjectsKey] as? Set<NSManagedObject> {
            for object in updated {
                guard let item = object as? Item else { continue }
                index(item: item)
            }
        }

        if let deleted = userInfo[NSDeletedObjectsKey] as? Set<NSManagedObject> {
            for object in deleted {
                guard let item = object as? Item else { continue }
                guard let id = item.id else { continue }
                remove(itemID: id)
            }
        }
    }
}
