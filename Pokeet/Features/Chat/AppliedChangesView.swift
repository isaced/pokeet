import PokeetCore
import SwiftUI

struct AppliedChangesView: View {
    let changes: [AppliedChange]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if changes.isEmpty {
                    ContentUnavailableView(
                        "No applied changes",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Changes applied by the agent will appear here.")
                    )
                } else {
                    List(Array(changes.reversed())) { change in
                        row(change)
                    }
                }
            }
            .navigationTitle("Applied changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func row(_ change: AppliedChange) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon(for: change))
                    .font(.caption)
                    .foregroundStyle(change.didWrite ? Color.accentColor : Color.secondary)
                Text(change.path)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if change.didWrite {
                    Text("+\(change.addedLines)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.green)
                    Text("-\(change.removedLines)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.red)
                } else {
                    Text("Rejected")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Text(change.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Text(change.timestamp, format: .relative(presentation: .named))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private func icon(for change: AppliedChange) -> String {
        switch change.kind {
        case "create": return "plus.square"
        case "delete": return "trash"
        case "move": return "arrow.right.square"
        default: return "pencil"
        }
    }
}
