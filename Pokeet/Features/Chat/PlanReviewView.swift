import SwiftUI
import Textual

struct PlanReviewView: View {
    let plan: String
    let onExecute: () -> Void
    let onStay: () -> Void
    let onRefine: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isRefining = false
    @State private var notes = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                StructuredText(markdown: plan)
                    .textual.structuredTextStyle(.gitHub)
                    .textual.textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 10) {
                    Button("Stay") {
                        onStay()
                        dismiss()
                    }
                    .buttonStyle(.bordered)

                    Button("Refine") {
                        isRefining = true
                    }
                    .buttonStyle(.bordered)

                    Spacer(minLength: 8)

                    Button("Execute") {
                        onExecute()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.bar)
            }
            .navigationTitle("Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
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
