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
    importPendingSharedLinks(using: persistenceController)
    archivePendingLinks(using: persistenceController)
}

private func importPendingSharedLinks(using persistenceController: PersistenceController) {
    let items = SharedCaptureStore.dequeueAll()
    guard !items.isEmpty else { return }
    let context = persistenceController.viewContext
    let backgroundContext = persistenceController.container.newBackgroundContext()
    var newItemIDs: [UUID] = []
    context.performAndWait {
        for item in items {
            let parsed = ShareCommentParser.parse(item.tagsText)
            if let id = ItemImportService.createLinkItem(
                url: item.url,
                source: .shareSheet,
                tags: parsed.tags,
                textContent: parsed.snippet,
                in: context
            ) {
                newItemIDs.append(id)
            }
        }
        if context.hasChanges {
            do {
                try context.save()
            } catch {
                NSLog("Failed to import shared links: \(error)")
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
