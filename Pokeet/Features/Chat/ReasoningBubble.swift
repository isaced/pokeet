import SwiftUI

struct ReasoningBubble: View {
    let text: String
    let isStreaming: Bool

    @State private var isExpanded = false
    @State private var startedAt: Date?
    @State private var finishedDuration: TimeInterval?

    private let previewHeight: CGFloat = 54
    private let expandedHeight: CGFloat = 150
    private let previewLeadingInset: CGFloat = 24

    private let previewTextID = "reasoning-preview-text"
    private let previewBottomID = "reasoning-preview-bottom"
    private let expandedTextID = "reasoning-expanded-text"
    private let expandedBottomID = "reasoning-expanded-bottom"

    init(text: String, isStreaming: Bool) {
        self.text = text
        self.isStreaming = isStreaming
        _startedAt = State(initialValue: isStreaming ? Date() : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if isExpanded {
                expandedText
            } else {
                collapsedPreview
            }
        }
        .padding(12)
        .background(
            Color(.secondarySystemBackground).opacity(0.55),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .onChange(of: isStreaming) { _, streaming in
            if !streaming, let startedAt {
                finishedDuration = Date().timeIntervalSince(startedAt)
            }
        }
    }

    private var header: some View {
        Button {
            toggleExpanded()
        } label: {
            HStack(spacing: 10) {
                if isStreaming {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "brain.head.profile")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    title
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    Text(isExpanded ? "Tap to collapse" : "Tap to read my mind")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Collapse thought process" : "Expand thought process")
    }

    @ViewBuilder
    private var title: some View {
        if isStreaming {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(thinkingTitle(at: context.date))
            }
        } else if let finishedDuration {
            Text("Thought for \(durationLabel(finishedDuration))")
        } else {
            Text("Thought process")
        }
    }

    private func thinkingTitle(at date: Date) -> String {
        guard let startedAt else {
            return "Thinking…"
        }
        return "Thinking for \(durationLabel(date.timeIntervalSince(startedAt)))"
    }

    private func durationLabel(_ duration: TimeInterval) -> String {
        let seconds = max(1, Int(duration.rounded()))
        return seconds == 1 ? "1 second" : "\(seconds) seconds"
    }

    private var collapsedPreview: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .blur(radius: 1.0)
                    .opacity(0.78)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(previewTextID)

                Color.clear
                    .frame(height: 1)
                    .id(previewBottomID)
            }
            .frame(height: previewHeight)
            .scrollDisabled(true)
            .scrollIndicators(.hidden)
            .clipped()
            .mask(previewMask)
            .onAppear {
                scrollPreviewToBottom(proxy)
            }
            .onChange(of: text) { _, _ in
                proxy.scrollTo(previewBottomID, anchor: .bottom)
            }
        }
        .padding(.leading, previewLeadingInset)
        .contentShape(Rectangle())
        .onTapGesture {
            toggleExpanded()
        }
        .accessibilityHidden(true)
    }

    private var expandedText: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(expandedTextID)

                Color.clear
                    .frame(height: 1)
                    .id(expandedBottomID)
            }
            .frame(height: expandedHeight)
            .scrollIndicators(.hidden)
            .onAppear {
                scrollExpandedToBottom(proxy)
            }
            .onChange(of: text) { _, _ in
                proxy.scrollTo(expandedBottomID, anchor: .bottom)
            }
        }
        .padding(.leading, previewLeadingInset)
    }

    private var previewMask: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black.opacity(0.35), location: 0.12),
                .init(color: .black, location: 0.4),
                .init(color: .black, location: 0.7),
                .init(color: .black.opacity(0.2), location: 0.9),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func toggleExpanded() {
        withAnimation(.easeInOut(duration: 0.18)) {
            isExpanded.toggle()
        }
    }

    private func scrollPreviewToBottom(_ proxy: ScrollViewProxy) {
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(previewBottomID, anchor: .bottom)
        }
    }

    private func scrollExpandedToBottom(_ proxy: ScrollViewProxy) {
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(expandedBottomID, anchor: .bottom)
        }
    }
}
