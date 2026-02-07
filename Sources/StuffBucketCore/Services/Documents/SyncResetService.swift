import CoreData
import Foundation
import CloudKit

public enum SyncResetService {
    public static func resetLocalData(persistence: PersistenceController = .shared) async throws {
        try await resetData(persistence: persistence, includeCloudKit: false)
    }

    public static func resetLocalAndCloudKitData(persistence: PersistenceController = .shared) async throws {
        try await resetData(persistence: persistence, includeCloudKit: true)
    }

    private static func resetData(persistence: PersistenceController, includeCloudKit: Bool) async throws {
        try await deleteAllManagedObjects(persistence: persistence)
        if includeCloudKit {
            try await purgeCloudKitPrivateZones()
        }
        deleteLocalStorageFiles()
        MaterializedDocumentStore.resetMaterializedCopies()
        SearchIndexer.shared.resetIndex()
    }

    private static func deleteAllManagedObjects(persistence: PersistenceController) async throws {
        let context = persistence.container.newBackgroundContext()
        try await perform(on: context) {
            let entityNames = ["Item", "SearchIndexMetadata"]
            for entityName in entityNames {
                let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
                request.includesPropertyValues = false
                let objects = try context.fetch(request)
                for object in objects {
                    context.delete(object)
                }
            }
            if context.hasChanges {
                try context.save()
            }
        }
    }

    private static func deleteLocalStorageFiles() {
        let fm = FileManager.default
        let root = StoragePaths.localRootURL(fileManager: fm)
        try? fm.removeItem(at: root)

        if let cacheRoot = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            for folder in ["ExtractedArchives", "ExtractedDocuments"] {
                let directory = cacheRoot.appendingPathComponent(folder, isDirectory: true)
                try? fm.removeItem(at: directory)
            }
        }
    }

    private static func purgeCloudKitPrivateZones() async throws {
        let container = CKContainer(identifier: ICloudConfig.containerIdentifier)
        let database = container.privateCloudDatabase
        let zones = try await fetchAllZones(database: database)
        let defaultZoneID = CKRecordZone.default().zoneID
        let zonesToDelete = zones
            .map(\.zoneID)
            .filter { $0 != defaultZoneID }
        guard !zonesToDelete.isEmpty else { return }
        try await deleteZones(zonesToDelete, database: database)
    }

    private static func fetchAllZones(database: CKDatabase) async throws -> [CKRecordZone] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[CKRecordZone], Error>) in
            database.fetchAllRecordZones { zones, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: zones ?? [])
                }
            }
        }
    }

    private static func deleteZones(_ zoneIDs: [CKRecordZone.ID], database: CKDatabase) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let operation = CKModifyRecordZonesOperation(recordZonesToSave: nil, recordZoneIDsToDelete: zoneIDs)
            operation.modifyRecordZonesResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: ())
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }

    private static func perform(on context: NSManagedObjectContext, _ block: @escaping () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            context.perform {
                do {
                    try block()
                    continuation.resume(returning: ())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
