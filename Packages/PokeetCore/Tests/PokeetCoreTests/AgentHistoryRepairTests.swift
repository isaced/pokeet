import Foundation
import Testing
@testable import PokeetCore

/// A cancelled tool round used to leave `assistant(tool_calls)` with no answers behind it,
/// which every provider rejects on the next request. These cover the repair that runs on the
/// way out of a failed or cancelled turn.
struct AgentHistoryRepairTests {
    private func makeSession(directory: TestDirectory) -> AgentSession {
        AgentSession(
            client: ScriptedModelClient([]),
            workspace: FileWorkspace(root: directory.url)
        )
    }

    @Test func answersDanglingToolCalls() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        let session = makeSession(directory: directory)

        await session.restore([
            .user("check the tree"),
            .assistant(nil, toolCalls: [
                ToolCall(id: "call_1", name: "list_files", arguments: "{}"),
                ToolCall(id: "call_2", name: "grep", arguments: #"{"pattern":"x"}"#)
            ])
        ])

        await session.repairHistory()

        let history = await session.history
        let toolMessages = history.filter { $0.role == .tool }
        #expect(toolMessages.count == 2)
        #expect(toolMessages.compactMap(\.toolCallID) == ["call_1", "call_2"])
        #expect(toolMessages.allSatisfy { ($0.content ?? "").hasPrefix("Error:") })
    }

    @Test func keepsAnswersThatAlreadyArrived() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        let session = makeSession(directory: directory)

        await session.restore([
            .user("check the tree"),
            .assistant(nil, toolCalls: [
                ToolCall(id: "call_1", name: "list_files", arguments: "{}"),
                ToolCall(id: "call_2", name: "grep", arguments: #"{"pattern":"x"}"#)
            ]),
            .tool("a.txt\nb.txt", callID: "call_1")
        ])

        await session.repairHistory()

        let history = await session.history
        let toolMessages = history.filter { $0.role == .tool }
        #expect(toolMessages.count == 2)
        #expect(toolMessages.map(\.toolCallID) == ["call_1", "call_2"])
        #expect(toolMessages.first?.content == "a.txt\nb.txt")
    }

    @Test func leavesACompletedTurnAlone() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        let session = makeSession(directory: directory)

        let original: [ChatMessage] = [
            .user("hi"),
            .assistant("hello")
        ]
        await session.restore(original)

        await session.repairHistory()

        let history = await session.history
        #expect(history.filter { $0.role != .system } == original)
    }

    @Test func doesNotRewriteTheMiddleOfTheTranscript() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        let session = makeSession(directory: directory)

        await session.restore([
            .user("old"),
            .assistant(nil, toolCalls: [
                ToolCall(id: "call_1", name: "list_files", arguments: "{}")
            ]),
            .user("never mind"),
            .assistant("Okay.")
        ])

        await session.repairHistory()

        let history = await session.history
        #expect(history.contains { $0.role == .tool } == false)
    }
}
