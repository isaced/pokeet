import SwiftUI
import Textual

struct MessageBubble: View {
    let bubble: ChatViewModel.Bubble

    var body: some View {
        switch bubble.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(bubble.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .foregroundStyle(Color.accentColor)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        case .reasoning:
            ReasoningBubble(text: bubble.text, isStreaming: bubble.isStreaming)
        case .assistant:
            HStack {
                StructuredText(markdown: bubble.text)
                    .textual.structuredTextStyle(.gitHub)
                    .textual.textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .foregroundStyle(.primary)
                    .background(Color(.secondarySystemBackground).opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                Spacer(minLength: 32)
            }
        case .tool:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.caption2)
                Text(bubble.text)
                    .font(.caption.monospaced())
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .error:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(bubble.text)
            }
            .font(.caption)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
