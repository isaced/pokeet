import PokeetCore
import SwiftUI

enum ReviewDecision: Equatable {
    case accepted
    case rejected(note: String?)
}

struct ProposalCard: View {
    let proposal: FileProposal
    let decision: ReviewDecision?
    let onAccept: () -> Void
    let onReject: () -> Void

    private let maxLinesPerHunk = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(proposal.kind == .create ? "NEW" : "EDIT")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(proposal.kind == .create ? Color.green.opacity(0.2) : Color.blue.opacity(0.2))
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

            diff

            decisionView

            HStack {
                Button(role: .destructive, action: onReject) {
                    Label("Reject", systemImage: "xmark")
                }
                .buttonStyle(.bordered)

                Spacer()

                Button(action: onAccept) {
                    Label("Accept", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var diff: some View {
        if proposal.diff.hunks.isEmpty {
            Text("(empty file)")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(proposal.diff.hunks) { hunk in
                        Text(hunk.header)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .fixedSize(horizontal: true, vertical: false)

                        ForEach(Array(hunk.lines.prefix(maxLinesPerHunk).enumerated()), id: \.offset) { _, line in
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
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private var decisionView: some View {
        switch decision {
        case .accepted:
            Label("Accepted", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .rejected(let note):
            VStack(alignment: .leading, spacing: 2) {
                Label("Rejected", systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                if let note, !note.isEmpty {
                    Text("Note: \(note)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case nil:
            Label("Pending review", systemImage: "circle.dashed")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
