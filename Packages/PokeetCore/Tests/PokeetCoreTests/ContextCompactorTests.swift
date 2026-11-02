import Testing
@testable import PokeetCore

struct ContextCompactorTests {
    @Test func keepsHistoryThatFitsTheBudget() {
        let messages: [ChatMessage] = [
            .system("sys"),
            .user("hi"),
            .assistant("hello")
        ]
        let compactor = ContextCompactor(
            maxCharacters: 1_000,
            retainedTurns: 10,
            toolOutputCharacters: 100
        )

        #expect(compactor.compact(messages) == messages)
    }

    @Test func planReturnsNilWhenHistoryFits() {
        let messages: [ChatMessage] = [
            .system("sys"),
            .user("hi"),
            .assistant("hello")
        ]
        let compactor = ContextCompactor(
            maxCharacters: 1_000,
            retainedTurns: 10,
            toolOutputCharacters: 100
        )

        #expect(compactor.plan(messages) == nil)
    }

    @Test func planSplitsOlderAndKeptMessages() throws {
        let filler = String(repeating: "x", count: 200)
        let messages: [ChatMessage] = [
            .system("sys"),
            .user("old \(filler)"),
            .assistant("old answer \(filler)"),
            .user("middle \(filler)"),
            .assistant("middle answer \(filler)"),
            .user("latest question"),
            .assistant("latest answer")
        ]
        let compactor = ContextCompactor(
            maxCharacters: 700,
            retainedTurns: 2,
            toolOutputCharacters: 100
        )

        let plan = try #require(compactor.plan(messages))

        #expect(plan.systemMessages == [.system("sys")])
        #expect(plan.messagesToSummarize.contains { $0.content?.contains("old ") == true })
        #expect(plan.keptMessages.contains { $0.content == "latest question" })
        #expect(plan.keptMessages.contains { $0.content?.contains("middle ") == true })
        #expect(plan.omittedTurnCount == 1)
    }

    @Test func dropsOldTurnsAndKeepsRecentOnes() {
        let filler = String(repeating: "x", count: 200)
        let messages: [ChatMessage] = [
            .system("sys"),
            .user("old \(filler)"),
            .assistant("old answer \(filler)"),
            .user("middle \(filler)"),
            .assistant("middle answer \(filler)"),
            .user("latest question"),
            .assistant("latest answer")
        ]
        let compactor = ContextCompactor(
            maxCharacters: 700,
            retainedTurns: 2,
            toolOutputCharacters: 100
        )

        let compacted = compactor.compact(messages)

        #expect(compacted.first?.role == .system)
        #expect(compacted.first?.content == "sys")
        #expect(compacted.contains { $0.role == .user && $0.content?.contains("Context compacted") == true })
        #expect(compacted.contains { $0.content == "latest question" })
        #expect(compacted.contains { $0.content?.contains("middle ") == true })
        #expect(!compacted.contains { $0.content?.hasPrefix("old ") == true })
    }

    @Test func truncatesLargeToolOutput() {
        let longOutput = String(repeating: "a", count: 500)
        let messages: [ChatMessage] = [
            .system("sys"),
            .user("read"),
            .assistant(nil, toolCalls: [
                ToolCall(id: "call_1", name: "read_file", arguments: "{}")
            ]),
            .tool(longOutput, callID: "call_1")
        ]
        let compactor = ContextCompactor(
            maxCharacters: 100,
            retainedTurns: 5,
            toolOutputCharacters: 50
        )

        let compacted = compactor.compact(messages)
        let toolMessage = compacted.first { $0.role == .tool }

        #expect(toolMessage?.content?.hasSuffix("[truncated]") == true)
        #expect((toolMessage?.content?.count ?? 0) <= 50 + "\n[truncated]".count)
    }

    @Test func compactsLargeToolCallArguments() {
        let largeArguments = String(repeating: "x", count: 500)
        let messages: [ChatMessage] = [
            .system("sys"),
            .user("write"),
            .assistant(nil, toolCalls: [
                ToolCall(id: "call_1", name: "write_file", arguments: largeArguments)
            ]),
            .tool("ok", callID: "call_1")
        ]
        let compactor = ContextCompactor(
            maxCharacters: 100,
            retainedTurns: 5,
            toolOutputCharacters: 50
        )

        let compacted = compactor.compact(messages)
        let call = compacted.first { $0.role == .assistant }?.toolCalls?.first

        #expect(call?.id == "call_1")
        #expect(call?.name == "write_file")
        #expect(call?.arguments == #"{"_compacted":true}"#)
    }
}
