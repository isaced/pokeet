import SwiftUI

/// Masked text field with a reveal button.
///
/// Every credential field goes through this so the eye sits in the same place,
/// masks the same way and is announced the same way, whether it holds an LLM
/// key, a search key or a git token.
struct SecretField: View {
    let title: String
    @Binding var text: String

    @State private var isVisible = false

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if isVisible {
                    TextField(title, text: $text)
                } else {
                    SecureField(title, text: $text)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

            Button {
                isVisible.toggle()
            } label: {
                Image(systemName: isVisible ? "eye.slash" : "eye")
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isVisible ? "Hide \(title)" : "Show \(title)")
        }
    }
}
