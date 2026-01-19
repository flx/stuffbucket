import SwiftUI

struct SearchBarView: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

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
        .padding(.vertical, verticalPadding)
        .padding(.horizontal, 12)
        .background(
            Capsule()
                .fill(backgroundColor)
        )
        .overlay(
            Capsule()
                .strokeBorder(borderColor, lineWidth: borderWidth)
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
            .focused($isFocused)
            .frame(maxWidth: .infinity)
            .layoutPriority(1)
#else
        TextField("Search", text: $text)
            .textFieldStyle(.plain)
            .controlSize(.small)
            .focused($isFocused)
            .frame(maxWidth: .infinity)
            .layoutPriority(1)
#endif
    }

    private var verticalPadding: CGFloat {
#if os(macOS)
        return 5
#else
        return 8
#endif
    }

    private var borderColor: Color {
#if os(macOS)
        return isFocused ? Color.accentColor.opacity(0.8) : Color.secondary.opacity(0.2)
#else
        return Color.secondary.opacity(0.2)
#endif
    }

    private var borderWidth: CGFloat {
#if os(macOS)
        return 1
#else
        return 1
#endif
    }
}

#Preview {
    SearchBarView(text: .constant(""))
        .padding()
}
