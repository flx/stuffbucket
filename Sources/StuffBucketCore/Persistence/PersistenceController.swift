import CoreData
import Foundation

enum ICloudConfig {
    static let containerIdentifier = "iCloud.com.digitalhandstand.stuffbucketapp"
}

public final class PersistenceController: ObservableObject {
    public static let shared = PersistenceController()

    public let container: NSPersistentCloudKitContainer

    public var viewContext: NSManagedObjectContext {
        container.viewContext
    }

    public init(inMemory: Bool = false) {
        Self.disableVerboseCoreDataLogging()
        let model = Self.loadModel()
        container = NSPersistentCloudKitContainer(name: "StuffBucketModel", managedObjectModel: model)

        if inMemory {
            let description = NSPersistentStoreDescription()
            description.url = URL(fileURLWithPath: "/dev/null")
            description.shouldMigrateStoreAutomatically = true
            description.shouldInferMappingModelAutomatically = true
            container.persistentStoreDescriptions = [description]
        } else {
            for description in container.persistentStoreDescriptions {
                description.shouldMigrateStoreAutomatically = true
                description.shouldInferMappingModelAutomatically = true
                description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
                    containerIdentifier: ICloudConfig.containerIdentifier
                )
            }
        }

        container.loadPersistentStores { _, error in
            if let error {
                NSLog("Failed to load persistent stores: \(error)")
            }
        }

        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        container.viewContext.automaticallyMergesChangesFromParent = true
    }

    private static func loadModel() -> NSManagedObjectModel {
        let bundle = Bundle(for: PersistenceController.self)
        guard let modelURL = bundle.url(forResource: "StuffBucketModel", withExtension: "momd") else {
            fatalError("Missing StuffBucketModel.momd in bundle: \(bundle.bundleURL.path)")
        }
        guard let model = NSManagedObjectModel(contentsOf: modelURL) else {
            fatalError("Failed to load StuffBucketModel from: \(modelURL.path)")
        }
        return model
    }

    private static func disableVerboseCoreDataLogging() {
        let keys = [
            "com.apple.CoreData.CloudKitDebug",
            "com.apple.CoreData.MigrationDebug",
            "com.apple.CoreData.SQLDebug",
            "com.apple.CoreData.Debug",
            "com.apple.CoreData.Logging.stderr",
            "com.apple.CoreData.Logging.stdout",
            "com.apple.CoreData.Logging.syslog"
        ]
        let defaults = UserDefaults.standard
        for key in keys {
            _ = key.withCString { setenv($0, "0", 1) }
            defaults.removeObject(forKey: key)
            defaults.set(0, forKey: key)
        }
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
