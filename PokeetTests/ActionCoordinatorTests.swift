import PokeetCore
import XCTest
@testable import Pokeet

@MainActor
final class ActionCoordinatorTests: XCTestCase {
    func testResolveReturnsDecision() async {
        let coordinator = ActionCoordinator()
        let pending = expectation(description: "pending")
        coordinator.onPending = { _ in pending.fulfill() }

        let task = Task {
            await coordinator.request(
                ActionRequest(method: "POST", url: "https://example.com")
            )
        }
        await fulfillment(of: [pending], timeout: 1)
        coordinator.resolve(.allowed)

        let decision = await task.value
        XCTAssertTrue(decision.allow)
    }

    func testCancelPendingDenies() async {
        let coordinator = ActionCoordinator()
        let pending = expectation(description: "pending")
        coordinator.onPending = { _ in pending.fulfill() }

        let task = Task {
            await coordinator.request(
                ActionRequest(method: "DELETE", url: "https://example.com")
            )
        }
        await fulfillment(of: [pending], timeout: 1)
        coordinator.cancelPending()

        let decision = await task.value
        XCTAssertFalse(decision.allow)
    }

    func testCancelBeforeRequestDeniesImmediately() async {
        let coordinator = ActionCoordinator()
        coordinator.cancelPending()

        let decision = await coordinator.request(
            ActionRequest(method: "PATCH", url: "https://example.com")
        )
        XCTAssertFalse(decision.allow)
    }
}
