import CoreData
import Foundation

public enum TrashCleanupService {
    private static let cleanupQueue = DispatchQueue(label: "com.digitalhandstand.stuffbucket.trash.cleanup", qos: .utility)
    private static var lastCleanupDate: Date?

    /// Deletes items that have been in trash for more than the specified number of days.
    /// This method is rate-limited to run at most once per hour to avoid excessive work.
    public static func cleanupExpiredTrashItems(context: NSManagedObjectContext, expirationDays: Int = 10) {
        // Rate limit: only run once per hour
        if let lastCleanup = lastCleanupDate, Date().timeIntervalSince(lastCleanup) < 3600 {
            return
        }
        lastCleanupDate = Date()

        cleanupQueue.async {
            context.perform {
                let fetchRequest: NSFetchRequest<Item> = Item.fetchRequest()
                fetchRequest.predicate = NSPredicate(format: "trashedAt != nil")

                do {
                    let trashedItems = try context.fetch(fetchRequest)
                    var deletedCount = 0

                    for item in trashedItems {
                        if item.isExpiredInTrash(days: expirationDays) {
                            deleteItemCompletely(item, context: context)
                            deletedCount += 1
                        }
                    }

                    if context.hasChanges {
                        try context.save()
                        NSLog("TrashCleanupService: Permanently deleted \(deletedCount) expired items")
                    }
                } catch {
                    NSLog("TrashCleanupService: Failed to cleanup expired trash items: \(error)")
                }
            }
        }
    }

    private static func deleteItemCompletely(_ item: Item, context: NSManagedObjectContext) {
        // Delete associated files
        if let itemID = item.id {
            deleteArchiveFiles(for: itemID)
            deleteDocumentFiles(for: item)
        }

        // Remove from search index
        if let itemID = item.id {
            SearchIndexer.shared.remove(itemID: itemID)
        }

        // Delete the Core Data object
        context.delete(item)
    }

    private static func deleteArchiveFiles(for itemID: UUID) {
        let archiveDirectory = LinkStorage.archiveDirectoryURL(for: itemID)
        try? FileManager.default.removeItem(at: archiveDirectory)

        let cacheDirectory = LinkStorage.localCacheDirectoryURL(for: itemID)
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    private static func deleteDocumentFiles(for item: Item) {
        guard let documentURL = item.documentURL else { return }
        let documentDirectory = documentURL.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: documentDirectory)
    }
}
