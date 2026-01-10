import SwiftUI
import StuffBucketCore

@main
struct StuffBucketMacApp: App {
    @StateObject private var persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.viewContext)
        }
    }
}
