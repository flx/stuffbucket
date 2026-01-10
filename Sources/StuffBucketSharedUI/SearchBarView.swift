import SwiftUI

struct SearchBarView: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            textField
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            Capsule()
                .fill(backgroundColor)
        )
        .overlay(
            Capsule()
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    private var backgroundColor: Color {
#if os(iOS)
        return Color(.secondarySystemBackground)
#else
        return Color(nsColor: .textBackgroundColor)
#endif
    }

    @ViewBuilder
    private var textField: some View {
#if os(iOS)
        TextField("Search", text: $text)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
#else
        TextField("Search", text: $text)
#endif
    }
}

#Preview {
    SearchBarView(text: .constant(""))
        .padding()
}
