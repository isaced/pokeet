import PokeetCore
import SwiftUI

struct ReviewItemState: Equatable {
    var isIncluded = true
    var selectedHunkIDs: Set<DiffHunk.ID> = []
    var note = ""

    func hasRejectedHunks(in proposal: FileProposal) -> Bool {
        guard isIncluded else { return true }
        let allHunkIDs = Set(proposal.diff.hunks.map(\.id))
        return !allHunkIDs.isEmpty && selectedHunkIDs != allHunkIDs
    }
}

struct DiffReviewView: View {
    let proposals: [FileProposal]
    let onResolve: ([ProposalDecision]) -> Void

    @State private var states: [UUID: ReviewItemState]
    @State private var noting: FileProposal?
    @State private var noteDraft = ""

    init(proposals: [FileProposal], onResolve: @escaping ([ProposalDecision]) -> Void) {
        self.proposals = proposals
        self.onResolve = onResolve
        _states = State(initialValue: Dictionary(
            uniqueKeysWithValues: proposals.map { proposal in
                (
                    proposal.id,
                    ReviewItemState(selectedHunkIDs: Set(proposal.diff.hunks.map(\.id)))
                )
            }
        ))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    Text("Include or exclude files. In an edit, tap a hunk to include only part of it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    ForEach(proposals) { proposal in
                        ProposalCard(
                            proposal: proposal,
                            state: state(for: proposal),
                            onToggleHunk: { toggleHunk($0, for: proposal) },
                            onToggleFile: { toggleFile(for: proposal) },
                            onEditNote: { openNote(for: proposal) }
                        )
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Review changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancelReview() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Approve all") { approveAll() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Submit") { submit() }
                }
            }
            .interactiveDismissDisabled()
            .sheet(item: $noting) { proposal in
                ReviewNoteSheet(
                    note: $noteDraft,
                    onSave: {
                        var state = state(for: proposal)
                        state.note = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        states[proposal.id] = state
                        noting = nil
                    },
                    onCancel: { noting = nil }
                )
            }
        }
    }

    private func state(for proposal: FileProposal) -> ReviewItemState {
        states[proposal.id]
            ?? ReviewItemState(selectedHunkIDs: Set(proposal.diff.hunks.map(\.id)))
    }

    private func toggleHunk(_ hunkID: DiffHunk.ID, for proposal: FileProposal) {
        guard proposal.kind != .delete, proposal.kind != .move else { return }
        var state = state(for: proposal)
        if state.selectedHunkIDs.contains(hunkID) {
            state.selectedHunkIDs.remove(hunkID)
        } else {
            state.selectedHunkIDs.insert(hunkID)
        }

        if !proposal.diff.hunks.isEmpty {
            state.isIncluded = !state.selectedHunkIDs.isEmpty
        }

        states[proposal.id] = state
    }

    private func toggleFile(for proposal: FileProposal) {
        var state = state(for: proposal)
        let allHunkIDs = Set(proposal.diff.hunks.map(\.id))
        let fullySelected = state.isIncluded
            && (allHunkIDs.isEmpty || state.selectedHunkIDs == allHunkIDs)

        if fullySelected {
            state.isIncluded = false
            state.selectedHunkIDs = []
        } else {
            state.isIncluded = true
            state.selectedHunkIDs = allHunkIDs
        }

        states[proposal.id] = state
    }

    private func openNote(for proposal: FileProposal) {
        noteDraft = state(for: proposal).note
        noting = proposal
    }

    private func submit() {
        onResolve(proposals.map { decision(for: $0) })
    }

    private func decision(for proposal: FileProposal) -> ProposalDecision {
        let state = state(for: proposal)
        let allHunkIDs = Set(proposal.diff.hunks.map(\.id))
        let trimmedNote = state.note.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = trimmedNote.isEmpty ? nil : trimmedNote

        guard state.isIncluded else {
            return .reject(proposalID: proposal.id, note: note)
        }
        if proposal.kind == .delete || proposal.kind == .move {
            return .acceptAll(proposalID: proposal.id)
        }
        guard !allHunkIDs.isEmpty else {
            return .acceptAll(proposalID: proposal.id)
        }
        guard !state.selectedHunkIDs.isEmpty else {
            return .reject(proposalID: proposal.id, note: note)
        }
        guard state.selectedHunkIDs != allHunkIDs else {
            return .acceptAll(proposalID: proposal.id)
        }
        return .acceptHunks(
            proposalID: proposal.id,
            hunkIDs: state.selectedHunkIDs,
            note: note
        )
    }

    private func approveAll() {
        for proposal in proposals {
            states[proposal.id] = ReviewItemState(
                selectedHunkIDs: Set(proposal.diff.hunks.map(\.id))
            )
        }
        submit()
    }

    private func cancelReview() {
        onResolve(
            proposals.map {
                .reject(proposalID: $0.id, note: "User cancelled the review.")
            }
        )
    }
}
