import Foundation
import PokeetCore

@MainActor
final class ActionCoordinator {
    var onPending: (@MainActor (ActionRequest) -> Void)?
    var onCleared: (@MainActor () -> Void)?

    private var continuation: CheckedContinuation<ActionDecision, Never>?
    private var isCancelled = false

    func request(_ action: ActionRequest) async -> ActionDecision {
        if Task.isCancelled {
            isCancelled = true
        }
        if isCancelled {
            onCleared?()
            return .denied
        }
        isCancelled = false

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if self.isCancelled {
                    continuation.resume(returning: .denied)
                    return
                }
                self.continuation = continuation
                self.onPending?(action)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPending()
            }
        }
    }

    func resolve(_ decision: ActionDecision) {
        guard let continuation else { return }
        self.continuation = nil
        onCleared?()
        continuation.resume(returning: decision)
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
        continuation.resume(returning: .denied)
    }
}
