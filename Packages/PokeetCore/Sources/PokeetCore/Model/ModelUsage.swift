public struct ModelUsage: Sendable, Codable, Equatable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let cachedInputTokens: Int
    public let reasoningTokens: Int?

    public var totalTokens: Int {
        inputTokens + outputTokens
    }

    public init(
        inputTokens: Int,
        outputTokens: Int,
        cachedInputTokens: Int = 0,
        reasoningTokens: Int? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.reasoningTokens = reasoningTokens
    }
}

public struct CacheStats: Sendable, Codable, Equatable {
    public static let noiseFloorTokens = 1_024

    public private(set) var requests = 0
    public private(set) var promptTokens = 0
    public private(set) var cachedTokens = 0
    public private(set) var missedTokens = 0
    public private(set) var previousPromptTokens: Int?
    public private(set) var previousReportedCache = false

    public init() {}

    public var hasData: Bool {
        requests > 0
    }

    public var hitRate: Double? {
        guard promptTokens > 0 else { return nil }
        return Double(cachedTokens) / Double(promptTokens)
    }

    public mutating func record(_ usage: ModelUsage) {
        requests += 1
        promptTokens += usage.inputTokens
        cachedTokens += usage.cachedInputTokens

        // Tokens that were already in the previous prompt but were re-billed.
        if let previousPromptTokens, previousReportedCache {
            let overlap = min(previousPromptTokens, usage.inputTokens)
            let missed = max(0, overlap - usage.cachedInputTokens)
            if missed > Self.noiseFloorTokens {
                missedTokens += missed
            }
        }

        self.previousPromptTokens = usage.inputTokens
        previousReportedCache = previousReportedCache || usage.cachedInputTokens > 0
    }

    public mutating func resetWindow() {
        previousPromptTokens = nil
        previousReportedCache = false
    }

    public mutating func reset() {
        self = CacheStats()
    }
}
