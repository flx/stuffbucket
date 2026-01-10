import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationSplitView {
            List {
                Label("Inbox", systemImage: "tray")
                Label("Links", systemImage: "link")
                Label("Documents", systemImage: "doc")
            }
            .navigationTitle("StuffBucket")
        } detail: {
            VStack(alignment: .leading, spacing: 12) {
                Text("StuffBucket")
                    .font(.largeTitle.bold())
                Text("Mac app shell is ready for the shared core.")
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}

#Preview {
    ContentView()
}
