import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("StuffBucket")
                    .font(.largeTitle.bold())
                Text("Capture, organize, and search your items.")
                    .foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle("Inbox")
        }
    }
}

#Preview {
    ContentView()
}
