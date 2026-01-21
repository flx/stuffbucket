import AppKit
import SwiftUI
import StuffBucketCore

@main
struct StuffBucketMacApp: App {
    @StateObject private var persistenceController = PersistenceController.shared
    @Environment(\.scenePhase) private var scenePhase
    private let captureObserver = SharedCaptureObserver {
        NSApp.activate(ignoringOtherApps: true)
        refreshPendingData(using: PersistenceController.shared)
    }
    
    init() {
        SearchIndexer.shared.startObserving(context: PersistenceController.shared.viewContext)
        // Set up platform-specific actions for shared UI
        PlatformActions.shared.showInFinder = DocumentActions.showInFinder
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.viewContext)
                .onAppear {
                    refreshPendingData(using: persistenceController)
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        refreshPendingData(using: persistenceController)
                    }
                }
                .onOpenURL { _ in
                    NSApp.activate(ignoringOtherApps: true)
                    refreshPendingData(using: persistenceController)
                }
        }
    }
}

private func refreshPendingData(using persistenceController: PersistenceController) {
    StorageMigration.migrateLocalStorageIfNeeded()
    SearchIndexer.shared.seedIndexIfNeeded(context: persistenceController.viewContext)
    importPendingSharedItems(using: persistenceController)
    archivePendingLinks(using: persistenceController)
    let backgroundContext = persistenceController.container.newBackgroundContext()
    TrashCleanupService.cleanupExpiredTrashItems(context: backgroundContext)
}

private func importPendingSharedItems(using persistenceController: PersistenceController) {
    let items = SharedCaptureStore.dequeueAll()
    guard !items.isEmpty else { return }
    let context = persistenceController.viewContext
    let backgroundContext = persistenceController.container.newBackgroundContext()
    var newItemIDs: [UUID] = []
    var importedSharedPaths: [String] = []
    context.performAndWait {
        for item in items {
            let parsed = ShareCommentParser.parse(item.tagsText)
            switch item.kind {
            case .link:
                guard let url = item.url else { continue }
                if let id = ItemImportService.createLinkItem(
                    url: url,
                    source: .shareSheet,
                    tags: parsed.tags,
                    textContent: parsed.snippet,
                    in: context
                ) {
                    newItemIDs.append(id)
                }
            case .document:
                guard let fileURL = SharedCaptureStore.resolveSharedFileURL(for: item) else { continue }
                do {
                    _ = try ItemImportService.importDocument(
                        fileURL: fileURL,
                        source: .shareSheet,
                        tags: parsed.tags,
                        textContent: parsed.snippet,
                        in: context
                    )
                    if let relativePath = item.sharedRelativePath {
                        importedSharedPaths.append(relativePath)
                    }
                } catch {
                    continue
                }
            }
        }
        if context.hasChanges {
            do {
                try context.save()
                for relativePath in importedSharedPaths {
                    SharedCaptureStore.removeSharedFile(relativePath: relativePath)
                }
            } catch {
                NSLog("Failed to import shared items: \(error)")
            }
        }
    }
    for itemID in newItemIDs {
        LinkArchiver.shared.archive(itemID: itemID, context: backgroundContext)
    }
}

private func archivePendingLinks(using persistenceController: PersistenceController) {
    let backgroundContext = persistenceController.container.newBackgroundContext()
    LinkArchiver.shared.archivePendingLinks(context: backgroundContext)
}
