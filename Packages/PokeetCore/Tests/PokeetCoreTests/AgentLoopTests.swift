import Foundation
import Testing
@testable import PokeetCore

actor ScriptedModelClient: ModelClient {
    private var responses: [ChatResponse]
    private(set) var requests: [ChatRequest] = []

    init(_ responses: [ChatResponse]) {
        self.responses = responses
    }

    func complete(_ request: ChatRequest) async throws -> ChatResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            throw ModelError.invalidResponse("Script exhausted")
        }
        return responses.removeFirst()
    }

    func recordedRequests() -> [ChatRequest] {
        requests
    }
}

actor EventRecorder {
    private(set) var events: [AgentEvent] = []

    func record(_ event: AgentEvent) {
        events.append(event)
    }

    func snapshot() -> [AgentEvent] {
        events
    }
}

private func toolCall(
    id: String = "call_1",
    name: String,
    arguments: String,
    content: String? = nil
) -> ChatResponse {
    ChatResponse(
        message: .assistant(content, toolCalls: [ToolCall(id: id, name: name, arguments: arguments)]),
        finishReason: "tool_calls"
    )
}

struct AgentLoopTests {
    @Test func finishesWithAssistantMessage() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let client = ScriptedModelClient([
            ChatResponse(message: .assistant("Done."), finishReason: "stop")
        ])
        let session = AgentSession(
            client: client,
            workspace: FileWorkspace(root: directory.url)
        )
        let recorder = EventRecorder()

        try await session.send(
            "hello",
            approval: { _ in [] },
            onEvent: { await recorder.record($0) }
        )

        let events = await recorder.snapshot()
        #expect(events == [.assistantMessage("Done."), .finished])
        let history = await session.history
        #expect(history.count == 3)
        #expect(history[1].role == .user)
        #expect(history[2].content == "Done.")
    }

    @Test func acceptsProposalAndWritesFile() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("README.md", "old\n")

        let workspace = FileWorkspace(root: directory.url)
        let client = ScriptedModelClient([
            toolCall(
                name: "write_file",
                arguments: #"{"path":"README.md","content":"new\n"}"#
            ),
            ChatResponse(message: .assistant("Updated the README."), finishReason: "stop")
        ])
        let session = AgentSession(client: client, workspace: workspace)
        let recorder = EventRecorder()

        try await session.send(
            "update readme",
            approval: { proposals in
                proposals.map { ProposalDecision(proposalID: $0.id, accepted: true) }
            },
            onEvent: { await recorder.record($0) }
        )

        let fileContent = try workspace.read("README.md", maxBytes: 1000)
        #expect(fileContent == "new\n")

        let events = await recorder.snapshot()
        let hasPending = events.contains {
            if case .proposalsPending = $0 { return true }
            return false
        }
        #expect(hasPending)

        let requests = await client.recordedRequests()
        #expect(requests.count == 2)
        let toolMessage = requests[1].messages.last
        #expect(toolMessage?.role == .tool)
        #expect(toolMessage?.content?.contains("Applied change to README.md") == true)
    }

    @Test func rejectionNoteReachesTheModel() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("README.md", "old\n")

        let workspace = FileWorkspace(root: directory.url)
        let client = ScriptedModelClient([
            toolCall(
                name: "write_file",
                arguments: #"{"path":"README.md","content":"new\n"}"#
            ),
            ChatResponse(message: .assistant("Understood."), finishReason: "stop")
        ])
        let session = AgentSession(client: client, workspace: workspace)

        try await session.send(
            "update readme",
            approval: { proposals in
                proposals.map {
                    ProposalDecision(proposalID: $0.id, accepted: false, note: "Add a test first")
                }
            },
            onEvent: { _ in }
        )

        let fileContent = try workspace.read("README.md", maxBytes: 1000)
        #expect(fileContent == "old\n")

        let requests = await client.recordedRequests()
        let toolMessage = requests[1].messages.last
        #expect(toolMessage?.content?.contains("Rejected by user") == true)
        #expect(toolMessage?.content?.contains("Add a test first") == true)
    }

    @Test func reportsUnknownTool() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let client = ScriptedModelClient([
            toolCall(name: "missing_tool", arguments: "{}"),
            ChatResponse(message: .assistant("Done."), finishReason: "stop")
        ])
        let session = AgentSession(
            client: client,
            workspace: FileWorkspace(root: directory.url)
        )

        try await session.send("hi", approval: { _ in [] }, onEvent: { _ in })

        let requests = await client.recordedRequests()
        let toolMessage = requests[1].messages.last
        #expect(toolMessage?.content?.contains("Unknown tool") == true)
    }

    @Test func stopsAtIterationLimit() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let client = ScriptedModelClient([
            toolCall(id: "call_1", name: "list_files", arguments: "{}"),
            toolCall(id: "call_2", name: "list_files", arguments: "{}")
        ])
        let session = AgentSession(
            client: client,
            workspace: FileWorkspace(root: directory.url),
            config: AgentConfiguration(maxIterations: 2)
        )
        let recorder = EventRecorder()

        do {
            try await session.send(
                "loop",
                approval: { _ in [] },
                onEvent: { await recorder.record($0) }
            )
            Issue.record("Expected the session to stop at the iteration limit")
        } catch let error as AgentError {
            #expect(error == .iterationLimit)
        }

        let events = await recorder.snapshot()
        let hasFailure = events.contains {
            if case .failed = $0 { return true }
            return false
        }
        #expect(hasFailure)
    }
}
