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
    @State private var showAllItems = false
    @State private var isSelectMode = false
    @State private var selectedItems: Set<UUID> = []
    @State private var selectedTags: Set<String> = []
    @State private var selectedCollections: Set<String> = []
    @State private var isShowingAISettings = false
    private let searchService = SearchService()
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Item.updatedAt, ascending: false)]
    )
    private var items: FetchedResults<Item>

    private var activeItems: [Item] {
        items.filter { !$0.isTrashed }
    }

    private var tagSummaries: [TagSummary] {
        LibrarySummaryBuilder.tags(from: activeItems)
    }

    private var collectionSummaries: [CollectionSummary] {
        LibrarySummaryBuilder.collections(from: activeItems)
    }

    private var recentItems: [Item] {
        showAllItems ? Array(activeItems) : Array(activeItems.prefix(10))
    }

    private var hasMoreItems: Bool {
        activeItems.count > 10
    }

    private var untaggedItemCount: Int {
        activeItems.filter { $0.displayTagList.isEmpty }.count
    }

    private func extractDateFilter(from searchText: String) -> DateFilter? {
        // Simple extraction of date: filter from search text
        let pattern = #"date:("[^"]+"|[^\s]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: searchText, range: NSRange(searchText.startIndex..., in: searchText)),
              let range = Range(match.range, in: searchText) else {
            return nil
        }
        let token = String(searchText[range])
        guard let colonIndex = token.firstIndex(of: ":") else { return nil }
        var value = String(token[token.index(after: colonIndex)...])
        // Remove quotes if present
        if value.hasPrefix("\"") && value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        return DateFilter(from: value)
    }

    private func isDateOnlySearch(_ searchText: String) -> Bool {
        // Check if search contains only date: filter(s) and no other text
        let pattern = #"date:("[^"]+"|[^\s]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return false
        }
        let withoutDate = regex.stringByReplacingMatches(
            in: searchText,
            range: NSRange(searchText.startIndex..., in: searchText),
            withTemplate: ""
        )
        return withoutDate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                        Section("Stuff") {
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
                                        if isSelectMode {
                                            Button {
                                                toggleSelection(itemID)
                                            } label: {
                                                HStack {
                                                    Image(systemName: selectedItems.contains(itemID) ? "checkmark.circle.fill" : "circle")
                                                        .foregroundStyle(selectedItems.contains(itemID) ? .blue : .secondary)
                                                    itemRowContent(item: item)
                                                }
                                            }
                                            .buttonStyle(.plain)
                                        } else {
                                            NavigationLink {
                                                ItemDetailView(itemID: itemID)
                                            } label: {
                                                itemRowContent(item: item)
                                            }
                                        }
                                    }
                                }
                                if hasMoreItems {
                                    Button {
                                        withAnimation {
                                            showAllItems.toggle()
                                        }
                                    } label: {
                                        HStack {
                                            Text(showAllItems ? "Show Less" : "Show All")
                                            Spacer()
                                            Image(systemName: showAllItems ? "chevron.up" : "chevron.down")
                                        }
                                        .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        Section("Tags") {
                            if tagSummaries.isEmpty {
                                Text("No tags yet")
                                    .foregroundStyle(.secondary)
                            } else {
                                Button {
                                    searchText = "tag:none"
                                } label: {
                                    HStack {
                                        Label("Untagged", systemImage: "tag.slash")
                                        Spacer()
                                        Text("\(untaggedItemCount)")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                                ForEach(tagSummaries) { summary in
                                    if isSelectMode {
                                        Button {
                                            toggleTagSelection(summary.name)
                                        } label: {
                                            HStack {
                                                Image(systemName: selectedTags.contains(summary.name) ? "checkmark.circle.fill" : "circle")
                                                    .foregroundStyle(selectedTags.contains(summary.name) ? .blue : .secondary)
                                                Label(summary.name, systemImage: "tag")
                                                Spacer()
                                                Text("\(summary.count)")
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        .buttonStyle(.plain)
                                    } else {
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
                        }
                        Section("Collections") {
                            if collectionSummaries.isEmpty {
                                Text("No collections yet")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(collectionSummaries) { summary in
                                    if isSelectMode {
                                        Button {
                                            toggleCollectionSelection(summary.name)
                                        } label: {
                                            HStack {
                                                Image(systemName: selectedCollections.contains(summary.name) ? "checkmark.circle.fill" : "circle")
                                                    .foregroundStyle(selectedCollections.contains(summary.name) ? .blue : .secondary)
                                                Label(summary.name, systemImage: "folder")
                                                Spacer()
                                                Text("\(summary.count)")
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        .buttonStyle(.plain)
                                    } else {
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
                        }
                    } else if let dateFilter = extractDateFilter(from: searchText), isDateOnlySearch(searchText) {
                        // Date-only search: show all items matching the date filter
                        let matchingItems = activeItems.filter { dateFilter.matches(date: $0.createdAt) }
                        if matchingItems.isEmpty {
                            Text("No items match this date filter")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(matchingItems, id: \.objectID) { item in
                                if let itemID = item.id {
                                    if isSelectMode {
                                        Button {
                                            toggleSelection(itemID)
                                        } label: {
                                            HStack {
                                                Image(systemName: selectedItems.contains(itemID) ? "checkmark.circle.fill" : "circle")
                                                    .foregroundStyle(selectedItems.contains(itemID) ? .blue : .secondary)
                                                itemRowContent(item: item)
                                            }
                                        }
                                        .buttonStyle(.plain)
                                    } else {
                                        NavigationLink {
                                            ItemDetailView(itemID: itemID)
                                        } label: {
                                            itemRowContent(item: item)
                                        }
                                    }
                                }
                            }
                        }
                    } else if searchText.lowercased() == "tag:none" {
                        // Special case: show untagged items
                        let untaggedItems = activeItems.filter { $0.displayTagList.isEmpty }
                        if untaggedItems.isEmpty {
                            Text("No untagged items")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(untaggedItems, id: \.objectID) { item in
                                if let itemID = item.id {
                                    if isSelectMode {
                                        Button {
                                            toggleSelection(itemID)
                                        } label: {
                                            HStack {
                                                Image(systemName: selectedItems.contains(itemID) ? "checkmark.circle.fill" : "circle")
                                                    .foregroundStyle(selectedItems.contains(itemID) ? .blue : .secondary)
                                                itemRowContent(item: item)
                                            }
                                        }
                                        .buttonStyle(.plain)
                                    } else {
                                        NavigationLink {
                                            ItemDetailView(itemID: itemID)
                                        } label: {
                                            itemRowContent(item: item)
                                        }
                                    }
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
                ToolbarItem(placement: .navigationBarLeading) {
                    if isSelectMode && (!selectedItems.isEmpty || !selectedTags.isEmpty || !selectedCollections.isEmpty) {
                        Button(role: .destructive) {
                            deleteSelected()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel("Delete Selected")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(isSelectMode ? "Done" : "Select") {
                        withAnimation {
                            isSelectMode.toggle()
                            if !isSelectMode {
                                selectedItems.removeAll()
                                selectedTags.removeAll()
                                selectedCollections.removeAll()
                            }
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !isSelectMode {
                        Button {
                            isShowingAISettings = true
                        } label: {
                            Image(systemName: "sparkles")
                        }
                        .accessibilityLabel("AI Settings")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !isSelectMode {
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
                            Divider()
                            Button(role: .destructive) {
                                isShowingDeleteAllAlert = true
                            } label: {
                                Label("Delete All Data", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
            .sheet(isPresented: $isShowingSnippetSheet) {
                QuickAddSnippetView(onSave: nil)
                    .environment(\.managedObjectContext, context)
            }
            .sheet(isPresented: $isShowingAISettings) {
                AISettingsView()
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
            // Skip search service for special filters handled locally
            if newValue.lowercased() == "tag:none" {
                results = []
                return
            }
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                let results = await searchService.search(text: newValue)
                await MainActor.run {
                    let lookup = self.itemLookup
                    let showTrashed = newValue.localizedCaseInsensitiveContains(Item.trashTag)
                    let dateFilter = extractDateFilter(from: newValue)
                    self.results = results.filter { result in
                        guard let item = lookup[result.itemID] else { return false }
                        // Filter by trash status
                        if !showTrashed && item.isTrashed { return false }
                        // Filter by date if specified
                        if let dateFilter, !dateFilter.matches(date: item.createdAt) { return false }
                        return true
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func itemRowContent(item: Item) -> some View {
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
                Spacer()
                if let date = item.createdAt {
                    Text(dateFormatter.string(from: date))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func toggleSelection(_ itemID: UUID) {
        if selectedItems.contains(itemID) {
            selectedItems.remove(itemID)
        } else {
            selectedItems.insert(itemID)
        }
    }

    private func deleteSelected() {
        // Trash selected items
        for itemID in selectedItems {
            if let item = itemLookup[itemID] {
                item.moveToTrash()
            }
        }
        // Remove selected tags from all items
        if !selectedTags.isEmpty {
            for item in activeItems {
                var tags = item.displayTagList
                let originalCount = tags.count
                tags.removeAll { selectedTags.contains($0) }
                if tags.count != originalCount {
                    item.setDisplayTagList(tags)
                    item.updatedAt = Date()
                }
            }
        }
        // Remove selected collections from all items
        if !selectedCollections.isEmpty {
            let lowercasedSelected = Set(selectedCollections.map { $0.lowercased() })
            for item in activeItems {
                var collections = item.collectionList
                let originalCount = collections.count
                collections.removeAll { lowercasedSelected.contains($0.lowercased()) }
                if collections.count != originalCount {
                    item.setCollectionList(collections)
                    item.updatedAt = Date()
                }
            }
        }
        if context.hasChanges {
            try? context.save()
        }
        selectedItems.removeAll()
        selectedTags.removeAll()
        selectedCollections.removeAll()
    }

    private func toggleTagSelection(_ tag: String) {
        if selectedTags.contains(tag) {
            selectedTags.remove(tag)
        } else {
            selectedTags.insert(tag)
        }
    }

    private func toggleCollectionSelection(_ collection: String) {
        if selectedCollections.contains(collection) {
            selectedCollections.remove(collection)
        } else {
            selectedCollections.insert(collection)
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
