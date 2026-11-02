import Foundation
import PokeetCore

@MainActor
final class ProposalCoordinator {
    var onPending: (@MainActor ([FileProposal]) -> Void)?
    var onCleared: (@MainActor () -> Void)?

    private var continuation: CheckedContinuation<[ProposalDecision], Never>?
    private var isCancelled = false

    func request(_ proposals: [FileProposal]) async -> [ProposalDecision] {
        if Task.isCancelled {
            isCancelled = true
        }
        if isCancelled {
            onCleared?()
            return []
        }
        isCancelled = false

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if self.isCancelled {
                    continuation.resume(returning: [])
                    return
                }
                self.continuation = continuation
                self.onPending?(proposals)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPending()
            }
        }
    }

    func resolve(_ decisions: [ProposalDecision]) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: decisions)
    }

    func reset() {
        isCancelled = false
    }

    func cancelPending() {
        isCancelled = true
        guard let continuation else {
            onCleared?()
            return
        }
        self.continuation = nil
        onCleared?()
        continuation.resume(returning: [])
    }
}
