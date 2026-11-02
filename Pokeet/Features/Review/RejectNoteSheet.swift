import SwiftUI

struct RejectNoteSheet: View {
    @Binding var note: String
    let onReject: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Optional note for the agent", text: $note, axis: .vertical)
                        .lineLimit(3...6)
                } footer: {
                    Text("The note is sent back to the agent so it can revise the change.")
                }
            }
            .navigationTitle("Reject change")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Reject", role: .destructive, action: onReject)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
