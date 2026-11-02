import Foundation
import Testing
@testable import PokeetCore

struct ContextSummarizerTests {
    @Test func requestsStructuredSummaryFromSerializedConversation() async throws {
        let client = ScriptedModelClient([
            ChatResponse(message: .assistant("## Goal\n- done"), finishReason: "stop")
        ])
        let summarizer = ModelContextSummarizer(client: client)
        let longToolOutput = String(repeating: "a", count: 2_500)

        let summary = try await summarizer.summarize([
            .user("Fix the bug"),
            .assistant(nil, toolCalls: [
                ToolCall(
                    id: "call_1",
                    name: "read_file",
                    arguments: #"{"path":"A.swift"}"#
                )
            ]),
            .tool(longToolOutput, callID: "call_1"),
            .assistant("Done")
        ])

        #expect(summary == "## Goal\n- done")

        let requests = await client.recordedRequests()
        let request = try #require(requests.first)
        #expect(request.tools.isEmpty)
        #expect(request.messages.first?.role == .system)
        #expect(request.messages.first?.content?.contains("structured context checkpoint") == true)

        let serialized = request.messages.last?.content ?? ""
        #expect(serialized.contains("[User]: Fix the bug"))
        #expect(serialized.contains("[Assistant tool calls]"))
        #expect(serialized.contains("[Tool result]"))
        #expect(serialized.contains("[truncated]"))
    }

    @Test func rejectsEmptySummary() async throws {
        let client = ScriptedModelClient([
            ChatResponse(message: .assistant(""), finishReason: "stop")
        ])
        let summarizer = ModelContextSummarizer(client: client)

        do {
            _ = try await summarizer.summarize([.user("hi")])
            Issue.record("Expected an empty summary error")
        } catch let error as ContextSummarizerError {
            #expect(error == .emptySummary)
        }
    }
}
