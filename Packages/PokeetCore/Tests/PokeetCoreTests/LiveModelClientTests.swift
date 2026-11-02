import Foundation
import Testing
@testable import PokeetCore

private let liveRelayEnabled = ProcessInfo.processInfo.environment["POKEET_LIVE"] == "1"

@Suite(.serialized, .enabled(if: liveRelayEnabled))
struct LiveModelClientTests {
    private let apiKey = "magpie"
    private let model = "opencode-go/deepseek-v4.1-flash"
    private let baseURL = "http://127.0.0.1:3425/v1"

    private func request() -> ChatRequest {
        ChatRequest(
            messages: [.user("Say hi in one word.")],
            tools: []
        )
    }

    private func streamedText(_ client: some ModelClient) async throws -> String {
        var text = ""
        var completed = false
        for try await event in client.stream(request()) {
            switch event {
            case .textDelta(let delta):
                text += delta
            case .completed(let response):
                completed = true
                if text.isEmpty, let content = response.message.content {
                    text = content
                }
            case .reasoningDelta:
                break
            }
        }
        #expect(completed)
        return text
    }

    @Test func chatCompletions() async throws {
        let client = OpenAIChatClient(
            baseURL: baseURL,
            model: model,
            apiKey: apiKey
        )
        let response = try await client.complete(request())
        #expect(response.message.content?.isEmpty == false)
        let streamed = try await streamedText(client)
        #expect(!streamed.isEmpty)
    }

    @Test func openAIResponses() async throws {
        let client = OpenAIResponsesClient(
            baseURL: baseURL,
            model: model,
            apiKey: apiKey
        )
        let response = try await client.complete(request())
        #expect(response.message.content?.isEmpty == false)
        let streamed = try await streamedText(client)
        #expect(!streamed.isEmpty)
    }

    @Test func anthropicMessages() async throws {
        let client = AnthropicMessagesClient(
            baseURL: baseURL,
            model: model,
            apiKey: apiKey,
            maxOutputTokens: 1024
        )
        let response = try await client.complete(request())
        #expect(response.message.content?.isEmpty == false)
        let streamed = try await streamedText(client)
        #expect(!streamed.isEmpty)
    }

    @Test func geminiGenerateContent() async throws {
        let client = GeminiGenerateContentClient(
            baseURL: "http://127.0.0.1:3425/v1beta",
            model: "auto/" + model,
            apiKey: apiKey,
            maxOutputTokens: 1024
        )
        let response = try await client.complete(request())
        #expect(response.message.content?.isEmpty == false)
        let streamed = try await streamedText(client)
        #expect(!streamed.isEmpty)
    }
}
