import PokeetCore
import SwiftUI

struct ActionReviewView: View {
    let action: ActionRequest
    let onResolve: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(action.method)
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.orange.opacity(0.15), in: Capsule())

                        Text(action.url)
                            .font(.subheadline.monospaced())
                            .textSelection(.enabled)
                    }

                    if !action.headers.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Headers")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            ForEach(action.headers.sorted(by: { $0.key < $1.key }), id: \.key) { name, value in
                                Text("\(name): \(value)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if !action.bodyPreview.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Body")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            Text(action.bodyPreview)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(
                                    Color(.secondarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                )
                        }
                    }
                }
                .padding(20)
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 10) {
                    Button("Deny", role: .destructive) {
                        onResolve(false)
                        dismiss()
                    }
                    .buttonStyle(.bordered)

                    Spacer(minLength: 8)

                    Button("Allow") {
                        onResolve(true)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.bar)
            }
            .navigationTitle("Allow network request?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onResolve(false)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled()
    }
}
