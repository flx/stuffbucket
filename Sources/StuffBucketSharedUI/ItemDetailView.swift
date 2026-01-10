import CoreData
import SwiftUI
import StuffBucketCore
#if os(macOS)
import AppKit
#endif

struct ItemDetailView: View {
    let itemID: UUID

    @Environment(\.managedObjectContext) private var context
    @FetchRequest private var items: FetchedResults<Item>
    @State private var tagsText = ""
    @State private var contentText = ""

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
                if item.isLinkItem, let linkURL = item.linkURL {
                    Text(linkURL)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if showsContentEditor(for: item) {
                Section("Content") {
                    contentEditor
                }
            }

            if item.itemType == .document {
                Section("Document") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.documentFileName ?? "Document")
                            .foregroundStyle(.secondary)
#if os(macOS)
                        if let documentURL = item.documentURL {
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([documentURL])
                            }
                        }
#endif
                    }
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
        .onChange(of: item.textContent ?? "") { _, _ in
            syncFromItem(item)
        }
        .onChange(of: tagsText) { _, newValue in
            applyTags(newValue, to: item)
        }
        .onChange(of: contentText) { _, newValue in
            applyContent(newValue, to: item)
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
        item.displayTitle
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

    @ViewBuilder
    private var contentEditor: some View {
#if os(iOS)
        TextEditor(text: $contentText)
            .frame(minHeight: 140)
#else
        TextEditor(text: $contentText)
            .frame(minHeight: 180)
#endif
    }

    private func syncFromItem(_ item: Item) {
        let current = item.tagList.joined(separator: ", ")
        if current != tagsText {
            tagsText = current
        }
        let currentContent = item.textContent ?? ""
        if currentContent != contentText {
            contentText = currentContent
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

    private func applyContent(_ text: String, to item: Item) {
        guard showsContentEditor(for: item) else { return }
        let current = item.textContent ?? ""
        guard text != current else { return }
        item.textContent = text
        item.updatedAt = Date()
        do {
            try context.save()
        } catch {
            context.rollback()
        }
    }

    private func showsContentEditor(for item: Item) -> Bool {
        item.itemType == .note || item.itemType == .snippet
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

struct QuickAddSnippetView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    let onSave: ((UUID) -> Void)?

    var body: some View {
        NavigationStack {
            VStack {
                TextEditor(text: $text)
                    .frame(minHeight: 200)
            }
            .padding()
            .navigationTitle("New Snippet")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveSnippet()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func saveSnippet() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let itemID = ItemImportService.createSnippetItem(text: trimmed, in: context) else { return }
        do {
            try context.save()
        } catch {
            context.rollback()
            return
        }
        onSave?(itemID)
        dismiss()
    }
}
