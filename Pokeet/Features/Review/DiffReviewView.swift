import PokeetCore
import SwiftUI

struct DiffReviewView: View {
    let proposals: [FileProposal]
    let onResolve: ([ProposalDecision]) -> Void

    @State private var decisions: [UUID: ReviewDecision] = [:]
    @State private var rejecting: FileProposal?
    @State private var rejectNote = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(proposals) { proposal in
                        ProposalCard(
                            proposal: proposal,
                            decision: decisions[proposal.id],
                            onAccept: {
                                decisions[proposal.id] = .accepted
                            },
                            onReject: {
                                rejectNote = ""
                                rejecting = proposal
                            }
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
                        .disabled(decisions.count < proposals.count)
                }
            }
            .interactiveDismissDisabled()
            .sheet(item: $rejecting) { proposal in
                RejectNoteSheet(
                    note: $rejectNote,
                    onReject: {
                        let trimmed = rejectNote.trimmingCharacters(in: .whitespacesAndNewlines)
                        decisions[proposal.id] = .rejected(note: trimmed.isEmpty ? nil : trimmed)
                        rejecting = nil
                    },
                    onCancel: { rejecting = nil }
                )
            }
        }
    }

    private func submit() {
        let result = proposals.map { proposal -> ProposalDecision in
            guard let decision = decisions[proposal.id] else {
                return ProposalDecision(proposalID: proposal.id, accepted: false)
            }
            switch decision {
            case .accepted:
                return ProposalDecision(proposalID: proposal.id, accepted: true)
            case .rejected(let note):
                return ProposalDecision(proposalID: proposal.id, accepted: false, note: note)
            }
        }
        onResolve(result)
    }

    private func approveAll() {
        for proposal in proposals {
            decisions[proposal.id] = .accepted
        }
        submit()
    }

    private func cancelReview() {
        onResolve(
            proposals.map {
                ProposalDecision(
                    proposalID: $0.id,
                    accepted: false,
                    note: "User cancelled the review."
                )
            }
        )
    }
}
