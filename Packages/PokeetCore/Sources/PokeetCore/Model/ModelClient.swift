import Foundation

public enum ModelStreamEvent: Sendable {
    case textDelta(String)
    case completed(ChatResponse)
}

public protocol ModelClient: Sendable {
    func complete(_ request: ChatRequest) async throws -> ChatResponse
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ModelStreamEvent, Error>
}

public extension ModelClient {
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await complete(request)
                    continuation.yield(.completed(response))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

public enum ModelError: Error, Sendable, Equatable, LocalizedError {
    case notConfigured
    case invalidResponse(String)
    case http(status: Int, message: String)
    case network(String)
    case decoding(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Add a model base URL, model name and API key in Settings."
        case .invalidResponse(let message):
            "Invalid model response: \(message)"
        case .http(let status, let message):
            "Model request failed (HTTP \(status)): \(message)"
        case .network(let message):
            "Network error: \(message)"
        case .decoding(let message):
            "Could not decode model response: \(message)"
        case .cancelled:
            "Model request was cancelled."
        }
    }
}
