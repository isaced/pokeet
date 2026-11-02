import Foundation
import PokeetCore

final class ModelClientRouter: ModelClient, @unchecked Sendable {
    private let lock = NSLock()
    private var client: (any ModelClient)?

    func setClient(_ client: (any ModelClient)?) {
        lock.lock()
        self.client = client
        lock.unlock()
    }

    func complete(_ request: ChatRequest) async throws -> ChatResponse {
        guard let client = currentClient() else {
            throw ModelError.notConfigured
        }
        return try await client.complete(request)
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        guard let client = currentClient() else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: ModelError.notConfigured)
            }
        }
        return client.stream(request)
    }

    private func currentClient() -> (any ModelClient)? {
        lock.lock()
        defer { lock.unlock() }
        return client
    }
}
