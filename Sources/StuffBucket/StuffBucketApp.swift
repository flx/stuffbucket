import SwiftUI
import StuffBucketCore

@main
struct StuffBucketApp: App {
    @StateObject private var persistenceController = PersistenceController.shared
    
    init() {
        SearchIndexer.shared.startObserving(context: PersistenceController.shared.viewContext)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.viewContext)
        }
    }
}
