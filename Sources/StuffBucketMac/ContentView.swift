import CoreData
import SwiftUI
import StuffBucketCore

struct ContentView: View {
    @State private var searchText = ""
    @State private var results: [SearchResult] = []
    @State private var searchTask: Task<Void, Never>?
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
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(result.title)
                                        .font(.headline)
                                    if let snippet = result.snippet, !snippet.isEmpty {
                                        Text(snippet)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .listStyle(.inset)
                    }
                }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
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
}

#Preview {
    ContentView()
}
