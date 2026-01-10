import CoreData
import SwiftUI
import StuffBucketCore

struct ItemDetailView: View {
    let itemID: UUID

    @Environment(\.managedObjectContext) private var context
    @FetchRequest private var items: FetchedResults<Item>
    @State private var tagsText = ""

    init(itemID: UUID) {
        self.itemID = itemID
        _items = FetchRequest(
            sortDescriptors: [],
            predicate: NSPredicate(format: "id == %@", itemID as CVarArg),
            animation: .default
        )
    }

    var body: some View {
        Group {
            if let item = items.first {
                detailView(for: item)
            } else {
                missingView
            }
        }
    }

    private func detailView(for item: Item) -> some View {
        Form {
            Section("Details") {
                Text(displayTitle(for: item))
                    .font(.headline)
                if let type = item.itemType?.rawValue {
                    Text(type.capitalized)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Tags") {
                tagsField
            }
        }
        .navigationTitle(displayTitle(for: item))
        .onAppear {
            syncFromItem(item)
        }
        .onChange(of: item.tags ?? "") { _, _ in
            syncFromItem(item)
        }
        .onChange(of: tagsText) { _, newValue in
            applyTags(newValue, to: item)
        }
    }

    private var missingView: some View {
        VStack(spacing: 8) {
            Text("Item not found")
                .font(.title2.bold())
            Text("The item may have been deleted or is not synced yet.")
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private func displayTitle(for item: Item) -> String {
        item.title ?? item.linkTitle ?? "Untitled"
    }

    @ViewBuilder
    private var tagsField: some View {
#if os(iOS)
        TextField("tag1, tag2", text: $tagsText)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
#else
        TextField("tag1, tag2", text: $tagsText)
#endif
    }

    private func syncFromItem(_ item: Item) {
        let current = item.tagList.joined(separator: ", ")
        if current != tagsText {
            tagsText = current
        }
    }

    private func applyTags(_ text: String, to item: Item) {
        let parsed = parseTags(text)
        guard parsed != item.tagList else { return }
        item.setTagList(parsed)
        item.updatedAt = Date()
        do {
            try context.save()
        } catch {
            context.rollback()
        }
    }

    private func parseTags(_ text: String) -> [String] {
        let parts = text.split(whereSeparator: { $0 == "," || $0 == "\n" })
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

#Preview {
    ItemDetailView(itemID: UUID())
}
