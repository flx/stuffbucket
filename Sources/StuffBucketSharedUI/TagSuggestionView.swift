import SwiftUI
import StuffBucketCore

public struct TagSuggestionView: View {
    let item: Item
    let existingLibraryTags: [String]
    let onApply: ([String]) -> Void
    let onCancel: () -> Void

    @State private var suggestions: [TagSuggestion] = []
    @State private var selectedTags: Set<String> = []
    @State private var isLoading = true
    @State private var error: String?

    public init(
        item: Item,
        existingLibraryTags: [String],
        onApply: @escaping ([String]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.item = item
        self.existingLibraryTags = existingLibraryTags
        self.onApply = onApply
        self.onCancel = onCancel
    }

    public var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    loadingView
                } else if let error {
                    errorView(error)
                } else if suggestions.isEmpty {
                    emptyView
                } else {
                    suggestionsList
                }
            }
            .navigationTitle("Suggested Tags")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onApply(Array(selectedTags))
                    }
                    .disabled(selectedTags.isEmpty)
                }
            }
            #else
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onApply(Array(selectedTags))
                    }
                    .disabled(selectedTags.isEmpty)
                }
            }
            .frame(minWidth: 350, minHeight: 300)
            #endif
        }
        .task {
            await loadSuggestions()
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Analyzing content...")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again") {
                Task {
                    await loadSuggestions()
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "tag.slash")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No tag suggestions available")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var suggestionsList: some View {
        List {
            Section {
                ForEach(suggestions) { suggestion in
                    Button {
                        toggleTag(suggestion.tag)
                    } label: {
                        HStack {
                            Image(systemName: selectedTags.contains(suggestion.tag) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedTags.contains(suggestion.tag) ? .blue : .secondary)

                            Text(suggestion.tag)

                            Spacer()

                            if suggestion.isExisting {
                                Text("existing")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Select tags to add")
            } footer: {
                if suggestions.contains(where: { $0.isExisting }) {
                    Text("Tags marked 'existing' are already used in your library")
                }
            }
        }
    }

    private func toggleTag(_ tag: String) {
        if selectedTags.contains(tag) {
            selectedTags.remove(tag)
        } else {
            selectedTags.insert(tag)
        }
    }

    private func loadSuggestions() async {
        isLoading = true
        error = nil

        let service = TagSuggestionService()

        do {
            let results = try await service.suggestTags(
                for: item,
                existingLibraryTags: existingLibraryTags
            )
            await MainActor.run {
                suggestions = results
                // Pre-select all suggestions
                selectedTags = Set(results.map { $0.tag })
                isLoading = false
            }
        } catch TagSuggestionError.noAPIKey {
            await MainActor.run {
                error = "Please configure an AI API key in settings"
                isLoading = false
            }
        } catch TagSuggestionError.noContent {
            await MainActor.run {
                error = "Not enough content to suggest tags"
                isLoading = false
            }
        } catch {
            await MainActor.run {
                self.error = "Failed to get suggestions: \(error.localizedDescription)"
                isLoading = false
            }
        }
    }
}
