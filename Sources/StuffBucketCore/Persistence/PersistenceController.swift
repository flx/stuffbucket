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

public enum DebugDataResetService {
    public static func resetAllData(context: NSManagedObjectContext) {
        context.perform {
            let request = NSFetchRequest<Item>(entityName: "Item")
            let items = (try? context.fetch(request)) ?? []
            let linkIDs = items.compactMap { $0.id }
            let documentPaths = items.compactMap { $0.documentRelativePath }

            for item in items {
                context.delete(item)
            }

            if context.hasChanges {
                try? context.save()
            }

            purgeStoredFiles(linkIDs: linkIDs, documentRelativePaths: documentPaths)
            SearchDatabase.shared.reset()
        }
    }

    private static func purgeStoredFiles(linkIDs: [UUID], documentRelativePaths: [String]) {
        let fileManager = FileManager.default

        for id in linkIDs {
            let linkFolder = LinkStorage.url(forRelativePath: "Links/\(id.uuidString)")
            removeItemIfExists(at: linkFolder, fileManager: fileManager)
        }

        for relativePath in documentRelativePaths {
            let documentURL = DocumentStorage.url(forRelativePath: relativePath)
            removeItemIfExists(at: documentURL, fileManager: fileManager)
            removeItemIfExists(at: documentURL.deletingLastPathComponent(), fileManager: fileManager)
        }

        let rootURL = storageRootURL(fileManager: fileManager)
        removeIfEmpty(url: rootURL.appendingPathComponent("Links", isDirectory: true), fileManager: fileManager)
        removeIfEmpty(url: rootURL.appendingPathComponent("Documents", isDirectory: true), fileManager: fileManager)
        removeIfEmpty(url: rootURL, fileManager: fileManager)
    }

    private static func storageRootURL(fileManager: FileManager) -> URL {
        if let iCloudRoot = fileManager.url(forUbiquityContainerIdentifier: ICloudConfig.containerIdentifier)?
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("StuffBucket", isDirectory: true) {
            return iCloudRoot
        }
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("StuffBucket", isDirectory: true)
    }

    private static func removeItemIfExists(at url: URL, fileManager: FileManager) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try? fileManager.removeItem(at: url)
    }

    private static func removeIfEmpty(url: URL, fileManager: FileManager) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        guard let contents = try? fileManager.contentsOfDirectory(atPath: url.path), contents.isEmpty else {
            return
        }
        try? fileManager.removeItem(at: url)
    }
}
