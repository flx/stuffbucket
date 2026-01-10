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
    @State private var isDropTargeted = false
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
        Array(items.prefix(12))
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
        NavigationSplitView {
            List {
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
            }
            .navigationTitle("Bucket")
        } detail: {
            VStack(spacing: 12) {
                SearchBarView(text: $searchText)
                    .padding(.horizontal)
                    .padding(.top, 8)
                Divider()
                NavigationStack {
                    if searchText.isEmpty {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 24) {
                                VStack(alignment: .leading, spacing: 12) {
                                    Label("Recent", systemImage: "clock")
                                        .font(.title3.bold())
                                    if recentItems.isEmpty {
                                        VStack(alignment: .leading, spacing: 12) {
                                            Text("No items yet")
                                                .foregroundStyle(.secondary)
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
                                                    HStack {
                                                        Text(item.displayTitle)
                                                        Spacer()
                                                        Text(item.itemType?.rawValue.capitalized ?? "Item")
                                                            .foregroundStyle(.secondary)
                                                        if item.isLinkItem {
                                                            LinkStatusBadge(status: item.archiveStatusValue)
                                                        }
                                                    }
                                                }
                                                .buttonStyle(.plain)
                                                .contextMenu {
                                                    documentRevealMenu(for: item)
                                                }
                                            }
                                        }
                                    }
                                }

                                VStack(alignment: .leading, spacing: 12) {
                                    Label("Tags", systemImage: "tag")
                                        .font(.title3.bold())
                                    if tagSummaries.isEmpty {
                                        Text("No tags yet")
                                            .foregroundStyle(.secondary)
                                    } else {
                                        ForEach(tagSummaries) { summary in
                                            Button {
                                                searchText = filterToken(prefix: "tag", value: summary.name)
                                            } label: {
                                                HStack {
                                                    Text(summary.name)
                                                    Spacer()
                                                    Text("\(summary.count)")
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }

                                VStack(alignment: .leading, spacing: 12) {
                                    Label("Collections", systemImage: "folder")
                                        .font(.title3.bold())
                                    if collectionSummaries.isEmpty {
                                        Text("No collections yet")
                                            .foregroundStyle(.secondary)
                                    } else {
                                        ForEach(collectionSummaries) { summary in
                                            Button {
                                                searchText = filterToken(prefix: "collection", value: summary.name)
                                            } label: {
                                                HStack {
                                                    Text(summary.name)
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
                                    if let item = itemLookup[result.itemID], item.isLinkItem {
                                        LinkStatusBadge(status: item.archiveStatusValue)
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
        }
        .frame(minWidth: 900, minHeight: 600)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("New Snippet") {
                        isShowingSnippetSheet = true
                    }
                    Button("Import Document...") {
                        isImportingDocument = true
                    }
                } label: {
                    Label("Add", systemImage: "plus")
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
        .onDrop(of: [UTType.url.identifier, UTType.plainText.identifier], isTargeted: $isDropTargeted) { providers in
            guard canHandleProviders(providers) else { return false }
            handleItemProviders(providers)
            return true
        }
        .onPasteCommand(of: [UTType.url, UTType.plainText]) { providers in
            handleItemProviders(providers)
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
                    self.results = results
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
            provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
                || provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
        }
    }

    private func handleItemProviders(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                loadURL(from: provider, typeIdentifier: UTType.url.identifier)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                loadURL(from: provider, typeIdentifier: UTType.plainText.identifier)
            }
        }
    }

    private func loadURL(from provider: NSItemProvider, typeIdentifier: String) {
        provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
            guard let url = Self.coerceURL(from: item) else { return }
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
}

#Preview {
    ContentView()
}
