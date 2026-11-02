import SwiftUI

struct ReasoningBubble: View {
    let text: String
    let isStreaming: Bool

    @State private var isExpanded: Bool

    init(text: String, isStreaming: Bool) {
        self.text = text
        self.isStreaming = isStreaming
        _isExpanded = State(initialValue: isStreaming)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .font(.caption)
                    Text(isStreaming ? "Thinking…" : "Thought process")
                        .font(.caption.weight(.medium))

                    if isStreaming {
                        ProgressView()
                            .controlSize(.mini)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse thought process" : "Expand thought process")

            if isExpanded {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(
            Color(.secondarySystemBackground).opacity(0.55),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .onChange(of: isStreaming) { _, streaming in
            guard !streaming else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded = false
            }
        }
    }
}
