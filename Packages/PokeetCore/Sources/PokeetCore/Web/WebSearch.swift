import Foundation

public struct WebSearchResult: Sendable, Equatable {
    public let title: String
    public let url: String
    public let snippet: String
    public let published: Date?

    public init(title: String, url: String, snippet: String, published: Date? = nil) {
        self.title = title
        self.url = url
        self.snippet = snippet
        self.published = published
    }
}

public enum WebSearchError: Error, Sendable, Equatable, LocalizedError {
    case notConfigured
    case networkDisabled
    case rejectedKey
    case rateLimited(retryAfter: Int?)
    case malformedResponse
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Web search is not configured. Pick a provider and add its credentials in Settings."
        case .networkDisabled:
            "Network access is disabled in Settings."
        case .rejectedKey:
            "The search provider rejected the credentials. Check them in Settings."
        case .rateLimited(let retryAfter):
            if let retryAfter {
                "The provider rate-limited this search. Retry in about \(retryAfter) seconds."
            } else {
                "The provider rate-limited this search. Wait a moment or search less."
            }
        case .malformedResponse:
            "The search provider returned an unexpected response."
        case .failed(let message):
            message
        }
    }
}

/// A search backend the agent can query. Implementations own their HTTP details.
public protocol WebSearchProviding: Sendable {
    var displayName: String { get }
    func search(query: String, limit: Int) async throws -> [WebSearchResult]
}

/// Caps how many searches one agent run may issue, so a loop cannot drain a quota.
public final class WebSearchBudget: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var remaining: Int

    public init(limit: Int = 6) {
        let clamped = min(max(1, limit), 20)
        self.limit = clamped
        self.remaining = clamped
    }

    public var isExhausted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return remaining == 0
    }

    public func reset() {
        lock.lock()
        remaining = limit
        lock.unlock()
    }

    /// Returns false when the run has already used its allowance.
    public func consume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard remaining > 0 else { return false }
        remaining -= 1
        return true
    }
}
