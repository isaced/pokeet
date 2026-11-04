import PokeetCore
import SwiftUI
import Textual

struct PlanReviewView: View {
    let plan: AgentPlan
    let phase: PlanPhase
    let onExecute: () -> Void
    let onStay: () -> Void
    let onRefine: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isRefining = false
    @State private var notes = ""

    private var isFinished: Bool {
        if case .finished = phase { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(plan.title)
                        .font(.title3.weight(.semibold))

                    if let summary = plan.summary, !summary.isEmpty {
                        StructuredText(markdown: summary)
                            .textual.structuredTextStyle(.gitHub)
                            .textual.textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if !plan.steps.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                                stepRow(index: index, step: step)
                            }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .safeAreaInset(edge: .bottom) {
                actionBar
            }
            .navigationTitle("Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isFinished ? "Done" : "Close") {
                        onStay()
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $isRefining) {
                refineSheet
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button(isFinished || phase == .executing ? "Done" : "Stay") {
                onStay()
                dismiss()
            }
            .buttonStyle(.bordered)

            if phase == .reviewing {
                Button("Refine") {
                    isRefining = true
                }
                .buttonStyle(.bordered)
            }

            Spacer(minLength: 8)

            if isFinished {
                // The plan already ran; another press is a deliberate re-run, not an approval.
                Button("Re-run") {
                    onExecute()
                    dismiss()
                }
                .buttonStyle(.bordered)
            } else if phase == .reviewing {
                Button("Execute") {
                    onExecute()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func stepRow(index: Int, step: AgentPlan.Step) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: step.status == .done ? "checkmark.circle.fill" : "\(index + 1).circle")
                .foregroundStyle(step.status == .done ? Color.green : Color.secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text(step.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)

                if let detail = step.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !step.files.isEmpty {
                    Text(step.files.joined(separator: ", "))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var refineSheet: some View {
        NavigationStack {
            TextEditor(text: $notes)
                .padding()
                .navigationTitle("Refine plan")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            isRefining = false
                            notes = ""
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Send") {
                            let feedback = notes
                            isRefining = false
                            notes = ""
                            onRefine(feedback)
                            dismiss()
                        }
                    }
                }
        }
        .presentationDetents([.medium])
    }
}
