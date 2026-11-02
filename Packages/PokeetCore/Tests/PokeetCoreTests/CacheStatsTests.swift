import Testing
@testable import PokeetCore

struct CacheStatsTests {
    @Test func firstRequestDoesNotCountAsMiss() {
        var stats = CacheStats()
        stats.record(ModelUsage(inputTokens: 5_000, outputTokens: 10, cachedInputTokens: 0))

        #expect(stats.requests == 1)
        #expect(stats.promptTokens == 5_000)
        #expect(stats.cachedTokens == 0)
        #expect(stats.missedTokens == 0)
        #expect(stats.hitRate == 0)
    }

    @Test func countsMissAboveNoiseFloor() {
        var stats = CacheStats()
        stats.record(ModelUsage(inputTokens: 5_000, outputTokens: 10, cachedInputTokens: 0))
        stats.record(ModelUsage(inputTokens: 5_000, outputTokens: 10, cachedInputTokens: 3_000))
        stats.record(ModelUsage(inputTokens: 5_000, outputTokens: 10, cachedInputTokens: 3_000))

        #expect(stats.requests == 3)
        #expect(stats.promptTokens == 15_000)
        #expect(stats.cachedTokens == 6_000)
        #expect(stats.missedTokens == 2_000)
        #expect(stats.hitRate == 0.4)
    }

    @Test func ignoresMissBelowNoiseFloor() {
        var stats = CacheStats()
        stats.record(ModelUsage(inputTokens: 5_000, outputTokens: 1, cachedInputTokens: 100))
        stats.record(ModelUsage(inputTokens: 5_000, outputTokens: 1, cachedInputTokens: 4_000))

        #expect(stats.missedTokens == 0)
    }

    @Test func providerWithoutCacheNeverReportsMisses() {
        var stats = CacheStats()
        for _ in 0..<3 {
            stats.record(ModelUsage(inputTokens: 5_000, outputTokens: 1, cachedInputTokens: 0))
        }

        #expect(stats.requests == 3)
        #expect(stats.missedTokens == 0)
        #expect(stats.hitRate == 0)
    }

    @Test func resetWindowForgetsPreviousPrompt() {
        var stats = CacheStats()
        stats.record(ModelUsage(inputTokens: 5_000, outputTokens: 1, cachedInputTokens: 100))
        stats.resetWindow()
        stats.record(ModelUsage(inputTokens: 5_000, outputTokens: 1, cachedInputTokens: 0))

        #expect(stats.requests == 2)
        #expect(stats.missedTokens == 0)
    }
}
