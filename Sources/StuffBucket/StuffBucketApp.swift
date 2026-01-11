import SwiftUI
import StuffBucketCore

@main
struct StuffBucketApp: App {
    @StateObject private var persistenceController = PersistenceController.shared
    @Environment(\.scenePhase) private var scenePhase
    
    init() {
        SearchIndexer.shared.startObserving(context: PersistenceController.shared.viewContext)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.viewContext)
                .onAppear {
                    importPendingSharedLinks()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        importPendingSharedLinks()
                    }
                }
                .onOpenURL { _ in
                    importPendingSharedLinks()
                }
        }
    }

    private func importPendingSharedLinks() {
        let items = SharedCaptureStore.dequeueAll()
        guard !items.isEmpty else { return }
        let context = persistenceController.viewContext
        let backgroundContext = persistenceController.container.newBackgroundContext()
        var newItemIDs: [UUID] = []
        context.performAndWait {
            for item in items {
                if let id = ItemImportService.createLinkItem(
                    url: item.url,
                    source: .shareSheet,
                    tagsText: item.tagsText,
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
}
