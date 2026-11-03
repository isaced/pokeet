import Foundation
import Testing
@testable import PokeetCore

private struct StubSearchProvider: WebSearchProviding {
    var displayName = "Stub"
    var results: [WebSearchResult] = []
    var error: WebSearchError?
    var recorded: LockedBox<(String, Int)?> = LockedBox(nil)

    func search(query: String, limit: Int) async throws -> [WebSearchResult] {
        recorded.set((query, limit))
        if let error { throw error }
        return Array(results.prefix(limit))
    }
}

struct WebSearchToolTests {
    @Test func reportsUnconfiguredProvider() async throws {
        let output = try await search(#"{"query":"swiftui"}"#)
        #expect(output.content.contains("not configured"))
    }

    @Test func reportsDisabledNetwork() async throws {
        let output = try await search(
            #"{"query":"swiftui"}"#,
            provider: StubSearchProvider(),
            networkPolicy: NetworkAccessPolicy(isEnabled: false)
        )
        #expect(output.content.contains("Network access is disabled"))
    }

    @Test func formatsResultsAndClampsLimit() async throws {
        let provider = StubSearchProvider(results: [
            WebSearchResult(title: "Docs", url: "https://example.com/docs", snippet: "One"),
            WebSearchResult(title: "Blog", url: "https://example.com/blog", snippet: "Two")
        ])
        let output = try await search(
            #"{"query":"swiftui list","limit":99}"#,
            provider: provider
        )

        #expect(provider.recorded.get()?.0 == "swiftui list")
        #expect(provider.recorded.get()?.1 == 10)
        #expect(output.content.contains("Stub · 2 results"))
        #expect(output.content.contains("1. Docs — https://example.com/docs"))
        #expect(output.content.contains("   Two"))
    }

    @Test func clipsLongSnippets() async throws {
        let provider = StubSearchProvider(results: [
            WebSearchResult(
                title: "Long",
                url: "https://example.com",
                snippet: String(repeating: "x", count: 500)
            )
        ])
        let output = try await search(#"{"query":"q"}"#, provider: provider)

        #expect(output.content.contains(String(repeating: "x", count: 300) + "…"))
        #expect(!output.content.contains(String(repeating: "x", count: 301)))
    }

    @Test func reportsEmptyResults() async throws {
        let output = try await search(#"{"query":"zzz"}"#, provider: StubSearchProvider())
        #expect(output.content.contains("0 results"))
        #expect(output.content.contains("No results for 'zzz'"))
    }

    @Test func mapsProviderErrors() async throws {
        for (error, expected) in [
            (WebSearchError.rejectedKey, "rejected the credentials"),
            (WebSearchError.rateLimited(retryAfter: 30), "30 seconds"),
            (WebSearchError.malformedResponse, "unexpected response")
        ] {
            let output = try await search(
                #"{"query":"q"}"#,
                provider: StubSearchProvider(error: error)
            )
            #expect(output.content.contains(expected))
        }
    }

    @Test func enforcesPerRunBudget() async throws {
        let budget = WebSearchBudget(limit: 1)
        let provider = StubSearchProvider(results: [
            WebSearchResult(title: "One", url: "https://example.com", snippet: "")
        ])

        let first = try await search(#"{"query":"a"}"#, provider: provider, budget: budget)
        let second = try await search(#"{"query":"b"}"#, provider: provider, budget: budget)

        #expect(first.content.contains("1 result"))
        #expect(second.content.contains("already used its web search allowance"))
    }

    @Test func resetRestoresTheBudget() async throws {
        let budget = WebSearchBudget(limit: 1)
        #expect(budget.consume())
        #expect(!budget.consume())
        budget.reset()
        #expect(budget.consume())
    }

    @Test func rejectsEmptyQuery() async throws {
        await #expect(throws: ToolError.self) {
            _ = try await search(#"{"query":"   "}"#)
        }
    }

    @Test func runsInPlanMode() {
        let names = Set(ToolRegistry.standard.filtered(for: .plan).schemas.map(\.name))
        #expect(names.contains(WebSearchTool.toolName))
    }

    private func search(
        _ arguments: String,
        provider: (any WebSearchProviding)? = nil,
        networkPolicy: NetworkAccessPolicy = .init(),
        budget: WebSearchBudget? = nil
    ) async throws -> ToolOutput {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        return try await WebSearchTool().execute(
            arguments: Data(arguments.utf8),
            context: ToolContext(
                workspace: FileWorkspace(root: directory.url),
                networkPolicy: networkPolicy,
                webSearch: provider,
                webSearchBudget: budget
            )
        )
    }
}

struct NetworkEndpointGuardTests {
    @Test func acceptsPublicHTTPSEndpoints() throws {
        #expect(throws: Never.self) {
            try NetworkEndpointGuard.validate(URL(string: "https://api.search.brave.com/res/v1/web/search")!)
        }
    }

    @Test func refusesInsecureAndLocalEndpoints() {
        let rejected = [
            "http://api.search.brave.com",
            "https://localhost:8080/search",
            "https://127.0.0.1/search",
            "https://10.0.0.5/search",
            "https://192.168.1.10/search",
            "https://[::1]/search",
            "https://searx.local/search",
            "https://metadata.google.internal/computeMetadata/v1"
        ]
        for raw in rejected {
            let url = URL(string: raw)!
            #expect(throws: NetworkEndpointError.self) {
                try NetworkEndpointGuard.validate(url)
            }
        }
    }
}
