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

#Preview {
    VStack(spacing: 12) {
        LinkStatusBadge(status: .full)
        LinkStatusBadge(status: .partial)
        LinkStatusBadge(status: .failed)
        LinkStatusBadge(status: nil)
    }
    .padding()
}
