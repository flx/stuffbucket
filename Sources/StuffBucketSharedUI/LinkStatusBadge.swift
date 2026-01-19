import SwiftUI
import StuffBucketCore

struct LinkStatusBadge: View {
    let status: ArchiveStatus?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: statusSymbol)
            Text(statusLabel)
        }
        .font(.caption)
        .foregroundStyle(statusColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(statusColor.opacity(0.12))
        )
        .accessibilityLabel(statusLabel)
    }

    private var statusLabel: String {
        switch status {
        case .some(.full):
            return "Archived"
        case .some(.partial):
            return "Partial"
        case .some(.failed):
            return "Failed"
        case .none:
            return "Pending"
        }
    }

    private var statusSymbol: String {
        switch status {
        case .some(.full):
            return "checkmark.seal"
        case .some(.partial):
            return "circle.lefthalf.filled"
        case .some(.failed):
            return "exclamationmark.triangle"
        case .none:
            return "clock"
        }
    }

    private var statusColor: Color {
        switch status {
        case .some(.full):
            return .green
        case .some(.partial):
            return .orange
        case .some(.failed):
            return .red
        case .none:
            return .secondary
        }
    }
}

struct ItemArchiveStatusBadge: View {
    @ObservedObject var item: Item

    var body: some View {
        if item.isLinkItem {
            LinkStatusBadge(status: item.archiveStatusValue)
        }
    }
}

struct TagLineView: View {
    private struct TagToken: Identifiable {
        enum Kind {
            case tag
            case collection
        }

        let kind: Kind
        let display: String
        let id = UUID()
    }

    private let tokens: [TagToken]
    private let selectedTags: Set<String>
    private let selectedCollections: Set<String>

    init(item: Item, selectedTags: Set<String>, selectedCollections: Set<String>) {
        self.tokens = TagLineView.buildTokens(from: item)
        self.selectedTags = selectedTags
        self.selectedCollections = selectedCollections
    }

    var body: some View {
        if !tokens.isEmpty {
            Text(renderedLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var renderedLine: String {
        tokens
            .map { token in
                if isSelected(token) {
                    return "[\(token.display)]"
                }
                return token.display
            }
            .joined(separator: " ")
    }

    private func isSelected(_ token: TagToken) -> Bool {
        switch token.kind {
        case .tag:
            return selectedTags.contains(token.display.lowercased())
        case .collection:
            let collectionName = CollectionTagParser.collectionName(from: token.display) ?? token.display
            return selectedCollections.contains(collectionName.lowercased())
                || selectedTags.contains(token.display.lowercased())
        }
    }

    private static func buildTokens(from item: Item) -> [TagToken] {
        var results: [TagToken] = []
        for rawTag in item.tagList {
            let trimmed = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != Item.trashTag else { continue }
            if CollectionTagParser.isCollectionTag(trimmed) {
                results.append(TagToken(kind: .collection, display: trimmed))
            } else {
                results.append(TagToken(kind: .tag, display: trimmed))
            }
        }
        return results
    }
}

#Preview {
    VStack(spacing: 12) {
        LinkStatusBadge(status: .full)
        LinkStatusBadge(status: .partial)
        LinkStatusBadge(status: .failed)
        LinkStatusBadge(status: nil)
    }
    .padding()
}

#Preview {
    let context = PersistenceController(inMemory: true).container.viewContext
    let item = Item.create(in: context)
    item.setTagList(["customer-service", "collection:VIP", "support"])
    return TagLineView(item: item, selectedTags: ["customer-service"], selectedCollections: ["vip"])
        .padding()
}
