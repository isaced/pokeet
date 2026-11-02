import SwiftUI

struct ReviewNoteSheet: View {
    @Binding var note: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Optional note for the agent", text: $note, axis: .vertical)
                        .lineLimit(3...6)
                } header: {
                    Text("Note for rejected hunks")
                } footer: {
                    Text("The note is sent back to the agent for the hunks you leave out.")
                }
            }
            .navigationTitle("Review note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: onSave)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
