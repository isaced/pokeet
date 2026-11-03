import PokeetCore
import SwiftUI

struct TurnHeaderRow: View {
    let header: ChatTurnHeader
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    icon
                        .frame(width: 14, alignment: .center)

                    Text(title)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Image(systemName: header.isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                header.isExpanded ? "Collapse execution details" : "Expand execution details"
            )

            Divider()
                .opacity(0.6)
        }
    }

    @ViewBuilder
    private var icon: some View {
        if header.isRunning {
            ProgressView()
                .controlSize(.mini)
                .tint(.secondary)
        } else if header.hasFinalAnswer {
            Image(systemName: "checkmark.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            Image(systemName: "stop.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var title: String {
        if header.isRunning {
            return "Working…"
        }

        let status: String
        if header.hasFinalAnswer {
            status = header.duration.map { "Completed in \(Self.durationLabel($0))" } ?? "Completed"
        } else {
            status = header.duration.map { "Stopped after \(Self.durationLabel($0))" } ?? "Stopped"
        }

        guard header.stepCount > 0 else { return status }
        let steps = header.stepCount == 1 ? "1 step" : "\(header.stepCount) steps"
        return "\(status) · \(steps)"
    }

    static func durationLabel(_ duration: TimeInterval) -> String {
        let total = max(1, Int(duration.rounded()))
        if total < 60 {
            return "\(total)s"
        }

        let minutes = total / 60
        let seconds = total % 60
        if minutes < 60 {
            return seconds == 0 ? "\(minutes)m" : "\(minutes)m \(seconds)s"
        }

        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes == 0 ? "\(hours)h" : "\(hours)h \(remainingMinutes)m"
    }
}

struct TraceStepRow: View {
    let bubble: ChatViewModel.Bubble
    let isNotice: Bool

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if hasDetails {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
                } label: {
                    header
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Collapse script" : "Expand script")
            } else {
                header
            }

            if let errorLine {
                Text(errorLine)
                    .font(.caption.monospaced())
                    .foregroundStyle(.red.opacity(0.85))
                    .lineLimit(2)
                    .padding(.leading, 20)
            }

            if isExpanded, hasDetails {
                details
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            icon
                .frame(width: 14, alignment: .center)

            if isNotice {
                Text(bubble.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    if let detail {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text(detail)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            Spacer(minLength: 0)

            if hasDetails {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let preview = bubble.preview, !preview.isEmpty {
                block(preview)
            }
            if let output = bubble.output, !output.isEmpty {
                block(output)
            }
        }
        .padding(.leading, 20)
        .padding(.top, 2)
    }

    private func block(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
    }

    private var hasDetails: Bool {
        guard !isNotice else { return false }
        return bubble.preview?.isEmpty == false || bubble.output?.isEmpty == false
    }

    @ViewBuilder
    private var icon: some View {
        if isNotice {
            Image(systemName: "info.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if bubble.isStreaming {
            ProgressView()
                .controlSize(.mini)
                .tint(.secondary)
        } else {
            Image(systemName: errorLine == nil ? symbolName : "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(errorLine == nil ? Color.secondary : Color.red.opacity(0.85))
        }
    }

    private var firstLine: String {
        bubble.text.components(separatedBy: "\n").first ?? bubble.text
    }

    private var errorLine: String? {
        let lines = bubble.text.components(separatedBy: "\n")
        guard lines.count > 1 else { return nil }
        let line = lines[1]
        return line.hasPrefix("Error:") ? line : nil
    }

    private var name: String {
        firstLine.components(separatedBy: " · ").first ?? firstLine
    }

    private var detail: String? {
        let parts = firstLine.components(separatedBy: " · ")
        guard parts.count > 1 else { return nil }
        return parts.dropFirst().joined(separator: " · ")
    }

    private var label: String {
        switch name {
        case "read_file": "Read"
        case "list_files": "Listed"
        case "find": "Found"
        case "file_info": "Inspected"
        case "grep": "Searched"
        case "write_file": "Wrote"
        case "edit_file": "Edited"
        case "delete_file": "Deleted"
        case "move_file": "Moved"
        case "git_status": "Git status"
        case "git_diff": "Git diff"
        case "git_log": "Git log"
        case "git_show": "Viewed"
        case "http_request": "Requested"
        case "run_script": "Ran"
        case "submit_plan": "Planned"
        default: name
        }
    }

    private var symbolName: String {
        switch name {
        case "read_file": "doc.text"
        case "list_files": "folder"
        case "find", "grep": "magnifyingglass"
        case "file_info": "info.circle"
        case "write_file": "square.and.pencil"
        case "edit_file": "pencil.line"
        case "delete_file": "trash"
        case "move_file": "arrow.turn.down.right"
        case "git_status", "git_diff", "git_log": "arrow.triangle.branch"
        case "git_show": "clock.arrow.circlepath"
        case "http_request": "network"
        case "run_script": "chevron.left.forwardslash.chevron.right"
        case "submit_plan": "list.bullet.rectangle"
        default: "wrench.and.screwdriver"
        }
    }
}

struct TraceAssistantText: View {
    let bubble: ChatViewModel.Bubble

    var body: some View {
        StreamingMarkdownText(text: bubble.text, isStreaming: bubble.isStreaming)
            .padding(.leading, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
