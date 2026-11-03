import PokeetCore
import SwiftUI

struct PlanProgressView: View {
    let plan: AgentPlan
    let isExecuting: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: plan.isComplete ? "checkmark.circle.fill" : "checklist")
                    .foregroundStyle(plan.isComplete ? Color.green : Color.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if !plan.steps.isEmpty {
                    Text("\(plan.completedStepCount)/\(plan.steps.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Image(systemName: "chevron.up")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Color(.secondarySystemBackground).opacity(0.8),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Plan progress")
    }

    private var subtitle: String {
        if plan.isComplete {
            return "Plan complete"
        }
        if plan.steps.isEmpty {
            return isExecuting ? "Executing plan" : "Plan ready · Tap to review"
        }
        if isExecuting {
            let current = min(plan.completedStepCount + 1, plan.steps.count)
            return "Executing step \(current) of \(plan.steps.count)"
        }
        return "Plan ready · \(plan.steps.count) steps"
    }
}
