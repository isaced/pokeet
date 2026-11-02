import Foundation
import Testing
@testable import PokeetCore

struct OpenCodeSessionTests {
    @Test func detectsOpenCodeHosts() {
        #expect(OpenCodeSession.isOpenCodeEndpoint("https://opencode.ai/inference/go/openai/v1"))
        #expect(OpenCodeSession.isOpenCodeEndpoint("https://go.opencode.ai/v1"))
        #expect(!OpenCodeSession.isOpenCodeEndpoint("https://api.openai.com/v1"))
        #expect(!OpenCodeSession.isOpenCodeEndpoint("https://example.com/opencode.ai"))
        #expect(!OpenCodeSession.isOpenCodeEndpoint("not a url"))
    }

    @Test func buildsSessionHeaderForOpenCode() {
        let headers = OpenCodeSession.headers(
            baseURL: "https://opencode.ai/inference/go/openai/v1",
            sessionID: "  sess-42  "
        )

        #expect(headers == ["x-opencode-session": "sess-42"])
    }

    @Test func ignoresMissingUnsafeOrUnrelatedSessions() {
        #expect(OpenCodeSession.headers(
            baseURL: "https://opencode.ai/inference/go/openai/v1",
            sessionID: nil
        ).isEmpty)
        #expect(OpenCodeSession.headers(
            baseURL: "https://opencode.ai/inference/go/openai/v1",
            sessionID: "  "
        ).isEmpty)
        #expect(OpenCodeSession.headers(
            baseURL: "https://opencode.ai/inference/go/openai/v1",
            sessionID: "bad\nvalue"
        ).isEmpty)
        #expect(OpenCodeSession.headers(
            baseURL: "https://api.openai.com/v1",
            sessionID: "sess-42"
        ).isEmpty)
    }
}
