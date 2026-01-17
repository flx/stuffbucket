import CoreData
import SwiftUI
import StuffBucketCore
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.managedObjectContext) private var context
    @State private var searchText = ""
    @State private var results: [SearchResult] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var isShowingSnippetSheet = false
    @State private var isImportingDocument = false
    @State private var isShowingAddLinkAlert = false
    @State private var addLinkText = ""
    @State private var isShowingDeleteAllAlert = false
    private let searchService = SearchService()
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Item.updatedAt, ascending: false)]
    )
    private var items: FetchedResults<Item>

    private var tagSummaries: [TagSummary] {
        LibrarySummaryBuilder.tags(from: Array(items))
    }

    private var collectionSummaries: [CollectionSummary] {
        LibrarySummaryBuilder.collections(from: Array(items))
    }

    private var recentItems: [Item] {
        Array(items.prefix(10))
    }

    private var itemLookup: [UUID: Item] {
        var lookup: [UUID: Item] = [:]
        for item in items {
            if let id = item.id {
                lookup[id] = item
            }
        }
        return lookup
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                SearchBarView(text: $searchText)
                    .padding(.horizontal)
                    .padding(.top, 8)
                List {
                    if searchText.isEmpty {
                        Section("Recent") {
                            if recentItems.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("No items yet")
                                        .foregroundStyle(.secondary)
                                    Button("Add Link...") {
                                        addLinkText = ""
                                        isShowingAddLinkAlert = true
                                    }
                                    Button("Import Document...") {
                                        isImportingDocument = true
                                    }
                                }
                            } else {
                                ForEach(recentItems, id: \.objectID) { item in
                                    if let itemID = item.id {
                                        NavigationLink {
                                            ItemDetailView(itemID: itemID)
                                        } label: {
                                            VStack(alignment: .leading, spacing: 6) {
                                                Text(item.displayTitle)
                                                    .font(.headline)
                                                HStack(spacing: 8) {
                                                    Text(item.itemType?.rawValue.capitalized ?? "Item")
                                                        .font(.subheadline)
                                                        .foregroundStyle(.secondary)
                                                    if item.isLinkItem {
                                                        ItemArchiveStatusBadge(item: item)
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        Section("Tags") {
                            if tagSummaries.isEmpty {
                                Text("No tags yet")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(tagSummaries) { summary in
                                    Button {
                                        searchText = filterToken(prefix: "tag", value: summary.name)
                                    } label: {
                                        HStack {
                                            Label(summary.name, systemImage: "tag")
                                            Spacer()
                                            Text("\(summary.count)")
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        Section("Collections") {
                            if collectionSummaries.isEmpty {
                                Text("No collections yet")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(collectionSummaries) { summary in
                                    Button {
                                        searchText = filterToken(prefix: "collection", value: summary.name)
                                    } label: {
                                        HStack {
                                            Label(summary.name, systemImage: "folder")
                                            Spacer()
                                            Text("\(summary.count)")
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    } else if results.isEmpty {
                        Text("No results")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(results) { result in
                            NavigationLink {
                                ItemDetailView(itemID: result.itemID)
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(result.title)
                                        .font(.headline)
                                    if let snippet = result.snippet, !snippet.isEmpty {
                                        Text(snippet)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                    if let item = itemLookup[result.itemID], item.isLinkItem {
                                        ItemArchiveStatusBadge(item: item)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(role: .destructive) {
                        isShowingDeleteAllAlert = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Delete All Data")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("New Snippet") {
                            isShowingSnippetSheet = true
                        }
#if os(iOS)
                        Button("Add Link...") {
                            addLinkText = ""
                            isShowingAddLinkAlert = true
                        }
#endif
                        Button("Import Document...") {
                            isImportingDocument = true
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $isShowingSnippetSheet) {
                QuickAddSnippetView(onSave: nil)
                    .environment(\.managedObjectContext, context)
            }
            .fileImporter(
                isPresented: $isImportingDocument,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    importDocuments(urls)
                case .failure:
                    break
                }
            }
#if os(iOS)
            .alert("Add Link", isPresented: $isShowingAddLinkAlert) {
                TextField("https://example.com", text: $addLinkText)
                Button("Cancel", role: .cancel) {}
                Button("Add") {
                    addLink()
                }
                .disabled(addLinkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: {
                Text("Paste a URL to save it in StuffBucket.")
            }
#endif
            .alert("Delete All Data?", isPresented: $isShowingDeleteAllAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Delete All", role: .destructive) {
                    deleteAllData()
                }
            } message: {
                Text("This removes all StuffBucket items and stored files. This is temporary debug tooling.")
            }
        }
        .onChange(of: searchText) { _, newValue in
            searchTask?.cancel()
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                results = []
                return
            }
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                let results = await searchService.search(text: newValue)
                await MainActor.run {
                    let lookup = self.itemLookup
                    self.results = results.filter { lookup[$0.itemID] != nil }
                }
            }
        }
    }

    private func filterToken(prefix: String, value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(" ") {
            return "\(prefix):\"\(trimmed)\""
        }
        return "\(prefix):\(trimmed)"
    }

#if os(iOS)
    private func addLink() {
        guard let url = normalizedURL(from: addLinkText) else { return }
        guard let itemID = ItemImportService.createLinkItem(url: url, source: .manual, in: context) else { return }
        do {
            try context.save()
        } catch {
            context.rollback()
            return
        }
        let backgroundContext = PersistenceController.shared.container.newBackgroundContext()
        LinkArchiver.shared.archive(itemID: itemID, context: backgroundContext)
    }

    private func normalizedURL(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        return URL(string: "https://\(trimmed)")
    }
#endif

    private func deleteAllData() {
        searchText = ""
        results = []
        DebugDataResetService.resetAllData(context: context)
    }

    private func importDocuments(_ urls: [URL]) {
        for url in urls {
            let accessGranted = url.startAccessingSecurityScopedResource()
            defer {
                if accessGranted {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                _ = try ItemImportService.importDocument(fileURL: url, in: context)
            } catch {
                continue
            }
        }
        if context.hasChanges {
            do {
                try context.save()
            } catch {
                context.rollback()
            }
        }
    }
}

#Preview {
    ContentView()
}
