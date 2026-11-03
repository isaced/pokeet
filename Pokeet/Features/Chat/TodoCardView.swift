import PokeetCore
import SwiftUI

/// Live checklist the agent keeps for multi-step work.
struct TodoCardView: View {
    let todos: [TaskItem]

    private var doneCount: Int {
        todos.filter { $0.status == .done }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checklist")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 14, alignment: .center)

                Text("Tasks")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                Text("\(doneCount)/\(todos.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 5) {
                ForEach(todos) { item in
                    row(for: item)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tasks, \(doneCount) of \(todos.count) done")
    }

    private func row(for item: TaskItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol(for: item.status))
                .font(.caption2)
                .foregroundStyle(item.status == .done ? Color.secondary : Color.accentColor)
                .frame(width: 14, alignment: .center)

            Text(item.title)
                .font(.footnote)
                .foregroundStyle(item.status == .done ? .tertiary : .primary)
                .strikethrough(item.status == .done, color: .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func symbol(for status: TaskItem.Status) -> String {
        switch status {
        case .pending: "circle"
        case .inProgress: "circle.lefthalf.filled"
        case .done: "checkmark.circle.fill"
        case .skipped: "minus.circle"
        }
    }
}
