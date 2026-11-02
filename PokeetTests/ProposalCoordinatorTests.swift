import PokeetCore
import XCTest
@testable import Pokeet

@MainActor
final class ProposalCoordinatorTests: XCTestCase {
    private func makeProposal() -> FileProposal {
        FileProposal(
            path: "README.md",
            kind: .update,
            baseContent: "old\n",
            newContent: "new\n",
            diff: LineDiff.compare(old: "old\n", new: "new\n")
        )
    }

    func testResolveReturnsDecisions() async {
        let coordinator = ProposalCoordinator()
        let proposal = makeProposal()
        let pending = expectation(description: "pending")
        coordinator.onPending = { _ in pending.fulfill() }

        let task = Task { await coordinator.request([proposal]) }
        await fulfillment(of: [pending], timeout: 1)
        coordinator.resolve([
            ProposalDecision(proposalID: proposal.id, accepted: true)
        ])

        let decisions = await task.value
        XCTAssertEqual(decisions.count, 1)
        XCTAssertTrue(decisions[0].accepted)
    }

    func testCancelBeforeRequestReturnsEmpty() async {
        let coordinator = ProposalCoordinator()
        coordinator.cancelPending()

        let decisions = await coordinator.request([])
        XCTAssertTrue(decisions.isEmpty)
    }

    func testCancelledRequestResumesWithRejection() async {
        let coordinator = ProposalCoordinator()
        let proposal = makeProposal()
        let pending = expectation(description: "pending")
        coordinator.onPending = { _ in pending.fulfill() }

        let task = Task { await coordinator.request([proposal]) }
        await fulfillment(of: [pending], timeout: 1)
        task.cancel()

        let decisions = await task.value
        XCTAssertTrue(decisions.isEmpty)
    }

    func testLateCancelDoesNotHangNextRequest() async {
        let coordinator = ProposalCoordinator()
        let proposal = makeProposal()
        let pending = expectation(description: "pending")
        coordinator.onPending = { _ in pending.fulfill() }

        let task = Task { await coordinator.request([proposal]) }
        await fulfillment(of: [pending], timeout: 1)
        task.cancel()
        _ = await task.value

        coordinator.reset()
        let nextPending = expectation(description: "next pending")
        coordinator.onPending = { _ in nextPending.fulfill() }

        let next = Task { await coordinator.request([proposal]) }
        await fulfillment(of: [nextPending], timeout: 1)
        coordinator.resolve([
            ProposalDecision(proposalID: proposal.id, accepted: false)
        ])

        let decisions = await next.value
        XCTAssertEqual(decisions.first?.accepted, false)
    }
}
