import Foundation
import SwiftUI

struct ReasoningBubble: View {
    let text: String
    let isStreaming: Bool
    let duration: TimeInterval?

    @State private var isExpanded = false
    @State private var startedAt: Date?

    private let previewHeight: CGFloat = 54
    private let contentLeadingInset: CGFloat = 20

    private let previewTextID = "reasoning-preview-text"
    private let previewBottomID = "reasoning-preview-bottom"

    init(text: String, isStreaming: Bool, duration: TimeInterval? = nil) {
        self.text = text
        self.isStreaming = isStreaming
        self.duration = duration
        _startedAt = State(initialValue: isStreaming ? Date() : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            if isExpanded {
                expandedText
            } else if isStreaming {
                collapsedPreview
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.18), value: isExpanded)
    }

    private var header: some View {
        Button {
            toggleExpanded()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 14, alignment: .center)

                if isStreaming {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(thinkingTitle(at: context.date))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(compactTitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                if !text.isEmpty {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Collapse thought process" : "Expand thought process")
    }

    private var compactTitle: String {
        if let duration {
            return "Thought for \(durationLabel(duration))"
        }
        return reasoningSnippet
    }

    private var reasoningSnippet: String {
        let firstLine = text.components(separatedBy: .newlines).first ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Thought process"
        }
        return trimmed.count > 72 ? String(trimmed.prefix(72)) + "…" : trimmed
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
        .padding(.leading, contentLeadingInset)
        .contentShape(Rectangle())
        .onTapGesture {
            toggleExpanded()
        }
        .accessibilityHidden(true)
    }

    private var expandedText: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineSpacing(2)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, contentLeadingInset)
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
        guard !text.isEmpty else { return }
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
}
