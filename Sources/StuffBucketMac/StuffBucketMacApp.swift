import SwiftUI
import StuffBucketCore

@main
struct StuffBucketMacApp: App {
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
        }
    }

    private func importPendingSharedLinks() {
        let urls = SharedCaptureStore.dequeueAll()
        guard !urls.isEmpty else { return }
        let context = persistenceController.viewContext
        let backgroundContext = persistenceController.container.newBackgroundContext()
        var newItemIDs: [UUID] = []
        context.performAndWait {
            for url in urls {
                if let id = ItemImportService.createLinkItem(url: url, source: .shareSheet, in: context) {
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
