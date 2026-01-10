import CoreData
import Foundation

public final class PersistenceController: ObservableObject {
    public static let shared = PersistenceController()

    public let container: NSPersistentCloudKitContainer

    public var viewContext: NSManagedObjectContext {
        container.viewContext
    }

    public init(inMemory: Bool = false) {
        container = NSPersistentCloudKitContainer(name: "StuffBucketModel")

        if inMemory {
            let description = NSPersistentStoreDescription()
            description.url = URL(fileURLWithPath: "/dev/null")
            container.persistentStoreDescriptions = [description]
        }

        container.loadPersistentStores { _, error in
            if let error {
                NSLog("Failed to load persistent stores: \(error)")
            }
        }

        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        container.viewContext.automaticallyMergesChangesFromParent = true
    }

    public func saveIfNeeded() {
        let context = container.viewContext
        guard context.hasChanges else { return }

        do {
            try context.save()
        } catch {
            NSLog("Failed to save context: \(error)")
        }
    }
}
