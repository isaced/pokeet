import PokeetCore
import SwiftUI
import UIKit

extension AgentMode {
    var systemImage: String {
        switch self {
        case .plan: return "map"
        case .ask: return "questionmark.bubble"
        case .auto: return "bolt.fill"
        case .bypass: return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .plan: return .blue
        case .ask: return .secondary
        case .auto: return .orange
        case .bypass: return .red
        }
    }
}

struct ModePickerView: View {
    let selected: AgentMode
    let onSelect: (AgentMode) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pendingBypass = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(AgentMode.allCases) { mode in
                        Button {
                            choose(mode)
                        } label: {
                            row(mode)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Agent mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Enable Bypass mode?", isPresented: $pendingBypass) {
                Button("Cancel", role: .cancel) {}
                Button("Enable", role: .destructive) {
                    select(.bypass)
                }
            } message: {
                Text("Bypass applies every file change without review, including deletes and moves.")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func choose(_ mode: AgentMode) {
        if mode == .bypass {
            pendingBypass = true
        } else {
            select(mode)
        }
    }

    private func select(_ mode: AgentMode) {
        onSelect(mode)
        dismiss()
    }

    private func row(_ mode: AgentMode) -> some View {
        HStack(spacing: 12) {
            Image(systemName: mode.systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(mode.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(mode.displayName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(mode.shortDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 8)

            if mode == selected {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(14)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(mode == selected ? mode.tint.opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}
