import AppKit
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
    @State private var isDropTargeted = false
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
        showAllItems ? Array(activeItems) : Array(activeItems.prefix(12))
    }

    private var hasMoreItems: Bool {
        activeItems.count > 12
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

    private var selectedTagFilters: Set<String> {
        let filters = SearchQueryParser().parse(searchText).filters
        let tags = filters
            .filter { $0.key == .tag }
            .map { $0.value.lowercased() }
            .filter { $0 != "none" }
        return Set(tags)
    }

    private var selectedCollectionFilters: Set<String> {
        let filters = SearchQueryParser().parse(searchText).filters
        let collections = filters
            .filter { $0.key == .collection }
            .map { $0.value.lowercased() }
        return Set(collections)
    }

    var body: some View {
        NavigationSplitView {
            List {
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
                                    let isAdditive = NSApp.currentEvent?.modifierFlags.contains(.command)
                                        ?? NSEvent.modifierFlags.contains(.command)
                                    applyCollectionFilter(summary.name, additive: isAdditive)
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
                                    let isAdditive = NSApp.currentEvent?.modifierFlags.contains(.command)
                                        ?? NSEvent.modifierFlags.contains(.command)
                                    applyTagFilter(summary.name, additive: isAdditive)
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
            }
        } detail: {
            NavigationStack {
                    if searchText.isEmpty {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 24) {
                                VStack(alignment: .leading, spacing: 12) {
                                    Label("Stuff", systemImage: "tray.full")
                                        .font(.title3.bold())
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
                                                    .buttonStyle(.plain)
                                                    .contextMenu {
                                                        documentRevealMenu(for: item)
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
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                            }
                            .padding(24)
                        }
                    } else if let dateFilter = extractDateFilter(from: searchText), isDateOnlySearch(searchText) {
                        // Date-only search: show all items matching the date filter
                        let matchingItems = activeItems.filter { dateFilter.matches(date: $0.createdAt) }
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                Label("Date Filter Results", systemImage: "calendar")
                                    .font(.title3.bold())
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
                                                .buttonStyle(.plain)
                                                .contextMenu {
                                                    documentRevealMenu(for: item)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(24)
                        }
                    } else if searchText.lowercased() == "tag:none" {
                        // Special case: show untagged items
                        let untaggedItems = activeItems.filter { $0.displayTagList.isEmpty }
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                Label("Untagged Items", systemImage: "tag.slash")
                                    .font(.title3.bold())
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
                                                .buttonStyle(.plain)
                                                .contextMenu {
                                                    documentRevealMenu(for: item)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(24)
                        }
                    } else if results.isEmpty {
                        Text("No results")
                            .foregroundStyle(.secondary)
                            .padding()
                    } else {
                        List(results) { result in
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
                                    if let item = itemLookup[result.itemID] {
                                        TagLineView(
                                            item: item,
                                            selectedTags: selectedTagFilters,
                                            selectedCollections: selectedCollectionFilters
                                        )
                                    }
                                    if let item = itemLookup[result.itemID], item.isLinkItem {
                                        ItemArchiveStatusBadge(item: item)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .contextMenu {
                                if let item = itemLookup[result.itemID] {
                                    documentRevealMenu(for: item)
                                }
                            }
                        }
                        .listStyle(.inset)
                    }
                }
        }
                .frame(minWidth: 900, minHeight: 600)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                if isSelectMode && (!selectedItems.isEmpty || !selectedTags.isEmpty || !selectedCollections.isEmpty) {
                    Button(role: .destructive) {
                        deleteSelected()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Delete Selected")
                }
            }
            ToolbarItem(placement: .automatic) {
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
            ToolbarItem(placement: .automatic) {
                if !isSelectMode {
                    Button {
                        isShowingAISettings = true
                    } label: {
                        Image(systemName: "sparkles")
                    }
                    .accessibilityLabel("AI Settings")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if !isSelectMode {
                    Menu {
                        Button("New Snippet") {
                            isShowingSnippetSheet = true
                        }
                        Button("Add Link...") {
                            addLinkText = ""
                            isShowingAddLinkAlert = true
                        }
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
                        Label("Add", systemImage: "plus")
                    }
                }
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search")
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
        .alert("Delete All Data?", isPresented: $isShowingDeleteAllAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete All", role: .destructive) {
                deleteAllData()
            }
        } message: {
            Text("This removes all StuffBucket items and stored files. This is temporary debug tooling.")
        }
        .onDrop(of: [UTType.fileURL.identifier, UTType.url.identifier, UTType.plainText.identifier], isTargeted: $isDropTargeted) { providers in
            guard canHandleProviders(providers) else { return false }
            handleItemProviders(providers)
            return true
        }
        .onPasteCommand(of: [UTType.fileURL, UTType.url, UTType.plainText]) { providers in
            handleItemProviders(providers)
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

    private func filterToken(prefix: String, value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(" ") {
            return "\(prefix):\"\(trimmed)\""
        }
        return "\(prefix):\(trimmed)"
    }

    private func applyTagFilter(_ tag: String, additive: Bool) {
        applyFilter(prefix: "tag", value: tag, key: .tag, additive: additive, resetOn: ["tag:none"])
    }

    private func applyCollectionFilter(_ collection: String, additive: Bool) {
        applyFilter(prefix: "collection", value: collection, key: .collection, additive: additive)
    }

    private func applyFilter(
        prefix: String,
        value: String,
        key: SearchFilterKey,
        additive: Bool,
        resetOn: Set<String> = []
    ) {
        let token = filterToken(prefix: prefix, value: value)
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !additive || trimmedSearch.isEmpty || resetOn.contains(trimmedSearch.lowercased()) {
            searchText = token
            return
        }

        let query = SearchQueryParser().parse(trimmedSearch)
        if query.filters.contains(where: { $0.key == key && $0.value.caseInsensitiveCompare(value) == .orderedSame }) {
            return
        }

        let separator = trimmedSearch.hasSuffix(" ") ? "" : " "
        searchText = trimmedSearch + separator + token
    }

    @ViewBuilder
    private func itemRowContent(item: Item) -> some View {
        HStack {
            Text(item.displayTitle)
            Spacer()
            Text(item.itemType?.rawValue.capitalized ?? "Item")
                .foregroundStyle(.secondary)
            if item.isLinkItem {
                ItemArchiveStatusBadge(item: item)
            }
            if let date = item.createdAt {
                Text(dateFormatter.string(from: date))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
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

    @ViewBuilder
    private func documentRevealMenu(for item: Item) -> some View {
        if item.itemType == .document, let url = item.documentURL {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    private func importDocuments(_ urls: [URL]) {
        context.perform {
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

    private func canHandleProviders(_ providers: [NSItemProvider]) -> Bool {
        providers.contains { provider in
            provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                || provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
                || provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
        }
    }

    private func handleItemProviders(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                loadURL(from: provider, typeIdentifier: UTType.fileURL.identifier)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                loadURL(from: provider, typeIdentifier: UTType.url.identifier)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                loadURL(from: provider, typeIdentifier: UTType.plainText.identifier)
            }
        }
    }

    private func loadURL(from provider: NSItemProvider, typeIdentifier: String) {
        provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
            guard let url = Self.coerceURL(from: item) else { return }
            if url.isFileURL {
                importDocuments([url])
            } else {
                storeLink(url)
            }
        }
    }

    private static func coerceURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
        }
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if let string = item as? String {
            return normalizedURL(from: string)
        }
        return nil
    }

    private static func normalizedURL(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        return URL(string: "https://\(trimmed)")
    }

    private func addLink() {
        guard let url = Self.normalizedURL(from: addLinkText) else { return }
        storeLink(url)
    }

    private func deleteAllData() {
        searchText = ""
        results = []
        DebugDataResetService.resetAllData(context: context)
    }

    private func storeLink(_ url: URL) {
        context.perform {
            guard let itemID = ItemImportService.createLinkItem(url: url, source: .manual, in: context) else {
                return
            }
            do {
                try context.save()
            } catch {
                context.rollback()
                return
            }
            let backgroundContext = PersistenceController.shared.container.newBackgroundContext()
            LinkArchiver.shared.archive(itemID: itemID, context: backgroundContext)
        }
    }
}

#Preview {
    ContentView()
}
