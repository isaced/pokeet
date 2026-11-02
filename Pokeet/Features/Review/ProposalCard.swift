import PokeetCore
import SwiftUI

struct ProposalCard: View {
    let proposal: FileProposal
    let state: ReviewItemState
    let onToggleHunk: (DiffHunk.ID) -> Void
    let onToggleFile: () -> Void
    let onEditNote: () -> Void

    private let maxLinesPerHunk = 300

    private var allHunkIDs: Set<DiffHunk.ID> {
        Set(proposal.diff.hunks.map(\.id))
    }

    private var selectedCount: Int {
        state.isIncluded ? state.selectedHunkIDs.count : 0
    }

    private var isFullySelected: Bool {
        state.isIncluded && (allHunkIDs.isEmpty || state.selectedHunkIDs == allHunkIDs)
    }

    private var hasRejectedHunks: Bool {
        state.hasRejectedHunks(in: proposal)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            diff
            footer
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onToggleFile) {
                Image(systemName: fileToggleIcon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isFullySelected ? Color.accentColor : .secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isFullySelected ? "Exclude all hunks" : "Include all hunks")

            Text(proposal.kind == .create ? "NEW" : "EDIT")
                .font(.caption2.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    proposal.kind == .create
                        ? Color.green.opacity(0.2)
                        : Color.blue.opacity(0.2)
                )
                .clipShape(Capsule())

            Text(proposal.path)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            Text("+\(proposal.addedLines)")
                .font(.caption.monospaced())
                .foregroundStyle(.green)
            Text("-\(proposal.removedLines)")
                .font(.caption.monospaced())
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var diff: some View {
        if proposal.diff.hunks.isEmpty {
            Text("(empty file)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 2)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(proposal.diff.hunks) { hunk in
                    let selected = isSelected(hunk)

                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 6) {
                            Button {
                                onToggleHunk(hunk.id)
                            } label: {
                                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                                    .frame(width: 24, height: 24)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                selected
                                    ? "Exclude hunk \(hunk.header)"
                                    : "Include hunk \(hunk.header)"
                            )

                            Text(hunk.header)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: true, vertical: false)

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)

                        ScrollView(.horizontal, showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(
                                    Array(hunk.lines.prefix(maxLinesPerHunk).enumerated()),
                                    id: \.offset
                                ) { _, line in
                                    DiffRow(line: line)
                                }

                                if hunk.lines.count > maxLinesPerHunk {
                                    Text("… \(hunk.lines.count - maxLinesPerHunk) more lines not shown")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .padding(6)
                                }
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .opacity(selected ? 1 : 0.4)
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(hasRejectedHunks ? .primary : .secondary)

                Spacer()

                if hasRejectedHunks {
                    Button(action: onEditNote) {
                        Label(
                            state.note.isEmpty ? "Add note" : "Edit note",
                            systemImage: "text.bubble"
                        )
                        .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if hasRejectedHunks, !state.note.isEmpty {
                Text("Note: \(state.note)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var summary: String {
        if proposal.diff.hunks.isEmpty {
            return isFullySelected ? "Empty file will be created" : "Empty file skipped"
        }
        if !state.isIncluded || selectedCount == 0 {
            return "No hunks selected"
        }
        if isFullySelected {
            return "All \(allHunkIDs.count) hunks selected"
        }
        return "\(selectedCount) of \(allHunkIDs.count) hunks selected"
    }

    private var fileToggleIcon: String {
        if !state.isIncluded || (selectedCount == 0 && !allHunkIDs.isEmpty) {
            return "circle"
        }
        return isFullySelected ? "checkmark.circle.fill" : "minus.circle.fill"
    }

    private func isSelected(_ hunk: DiffHunk) -> Bool {
        state.isIncluded && state.selectedHunkIDs.contains(hunk.id)
    }
}

private struct DiffRow: View {
    let line: DiffLine

    var body: some View {
        HStack(spacing: 6) {
            Text(lineNumber)
                .frame(width: 34, alignment: .trailing)
                .foregroundStyle(.secondary)
            Text(prefix)
                .frame(width: 10)
            Text(line.text.isEmpty ? " " : line.text)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(background)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var lineNumber: String {
        String(line.newNumber ?? line.oldNumber ?? 0)
    }

    private var prefix: String {
        switch line.kind {
        case .added: "+"
        case .removed: "-"
        case .context: " "
        }
    }

    private var background: Color {
        switch line.kind {
        case .added: Color.green.opacity(0.12)
        case .removed: Color.red.opacity(0.12)
        case .context: Color.clear
        }
    }
}
