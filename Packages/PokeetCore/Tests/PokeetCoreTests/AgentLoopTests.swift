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

actor FlakyModelClient: ModelClient {
    private var outcomes: [Result<ChatResponse, ModelError>]
    private(set) var requests: [ChatRequest] = []

    init(_ outcomes: [Result<ChatResponse, ModelError>]) {
        self.outcomes = outcomes
    }

    func complete(_ request: ChatRequest) async throws -> ChatResponse {
        requests.append(request)
        guard !outcomes.isEmpty else {
            throw ModelError.invalidResponse("Script exhausted")
        }
        return try outcomes.removeFirst().get()
    }

    func recordedRequests() -> [ChatRequest] {
        requests
    }
}

private struct DeltaStreamingClient: ModelClient {
    func complete(_ request: ChatRequest) async throws -> ChatResponse {
        throw ModelError.invalidResponse("complete is not used")
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.reasoningDelta("Think"))
            continuation.yield(.reasoningDelta("ing"))
            continuation.yield(.textDelta("Hel"))
            continuation.yield(.textDelta("lo"))
            continuation.yield(.completed(ChatResponse(
                message: .assistant("Hello"),
                finishReason: "stop",
                usage: ModelUsage(
                    inputTokens: 100,
                    outputTokens: 5,
                    cachedInputTokens: 64,
                    reasoningTokens: 2
                )
            )))
            continuation.finish()
        }
    }
}

actor RecordingSummarizer: ContextSummarizer {
    private let summary: String
    private(set) var received: [[ChatMessage]] = []

    init(summary: String) {
        self.summary = summary
    }

    func summarize(_ messages: [ChatMessage]) async throws -> String {
        received.append(messages)
        return summary
    }

    func receivedMessages() -> [[ChatMessage]] {
        received
    }
}

struct FailingSummarizer: ContextSummarizer {
    func summarize(_ messages: [ChatMessage]) async throws -> String {
        throw ContextSummarizerError.emptySummary
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

    @Test func forwardsSessionIDToModelRequests() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let client = ScriptedModelClient([
            ChatResponse(message: .assistant("Done."), finishReason: "stop")
        ])
        let session = AgentSession(
            client: client,
            workspace: FileWorkspace(root: directory.url),
            sessionID: "sess-42"
        )

        try await session.send("hi", approval: { _ in [] }, onEvent: { _ in })

        let requests = await client.recordedRequests()
        #expect(requests.first?.sessionID == "sess-42")
    }

    @Test func forwardsStreamingTextDeltas() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let session = AgentSession(
            client: DeltaStreamingClient(),
            workspace: FileWorkspace(root: directory.url)
        )
        let recorder = EventRecorder()

        try await session.send(
            "hi",
            approval: { _ in [] },
            onEvent: { await recorder.record($0) }
        )

        let events = await recorder.snapshot()
        #expect(events == [
            .assistantReasoningDelta("Think"),
            .assistantReasoningDelta("ing"),
            .assistantTextDelta("Hel"),
            .assistantTextDelta("lo"),
            .usage(ModelUsage(
                inputTokens: 100,
                outputTokens: 5,
                cachedInputTokens: 64,
                reasoningTokens: 2
            )),
            .assistantMessage("Hello"),
            .finished
        ])
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
                proposals.map { .acceptAll(proposalID: $0.id) }
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
                    .reject(proposalID: $0.id, note: "Add a test first")
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

    @Test func partialApprovalAppliesOnlySelectedHunks() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let oldLines = (1...30).map(String.init)
        var newLines = oldLines
        newLines[1] = "changed-2"
        newLines[28] = "changed-29"
        let base = oldLines.joined(separator: "\n") + "\n"
        let new = newLines.joined(separator: "\n") + "\n"
        try directory.write("file.txt", base)

        let argumentsData = try JSONSerialization.data(withJSONObject: [
            "path": "file.txt",
            "content": new
        ])
        let arguments = String(decoding: argumentsData, as: UTF8.self)

        let workspace = FileWorkspace(root: directory.url)
        let client = ScriptedModelClient([
            toolCall(name: "write_file", arguments: arguments),
            ChatResponse(message: .assistant("Partial change applied."), finishReason: "stop")
        ])
        let session = AgentSession(client: client, workspace: workspace)

        try await session.send(
            "edit file",
            approval: { proposals in
                guard let proposal = proposals.first,
                      let firstHunk = proposal.diff.hunks.first
                else { return [] }
                return [
                    .acceptHunks(
                        proposalID: proposal.id,
                        hunkIDs: [firstHunk.id],
                        note: "Leave the end change for later"
                    )
                ]
            },
            onEvent: { _ in }
        )

        let content = try workspace.read("file.txt", maxBytes: 10_000)
        #expect(content.contains("\nchanged-2\n"))
        #expect(!content.contains("changed-29"))

        let requests = await client.recordedRequests()
        let toolMessage = requests[1].messages.last?.content ?? ""
        #expect(toolMessage.contains("Partially applied change to file.txt"))
        #expect(toolMessage.contains("1 of 2 hunks accepted"))
        #expect(toolMessage.contains("Leave the end change for later"))
    }

    @Test func retriesTransientFailure() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let client = FlakyModelClient([
            .failure(.http(status: 429, message: "rate limited")),
            .success(ChatResponse(message: .assistant("Done."), finishReason: "stop"))
        ])
        let session = AgentSession(
            client: client,
            workspace: FileWorkspace(root: directory.url),
            config: AgentConfiguration(maxRetries: 2, retryBaseDelayMilliseconds: 0)
        )
        let recorder = EventRecorder()

        try await session.send(
            "hi",
            approval: { _ in [] },
            onEvent: { await recorder.record($0) }
        )

        let requests = await client.recordedRequests()
        #expect(requests.count == 2)

        let events = await recorder.snapshot()
        #expect(events == [
            .assistantResponseRestarted,
            .retryScheduled(
                attempt: 1,
                maxAttempts: 2,
                delayMilliseconds: 0,
                reason: "Model request failed (HTTP 429): rate limited"
            ),
            .assistantMessage("Done."),
            .finished
        ])
    }

    @Test func doesNotRetryNonTransientFailure() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let client = FlakyModelClient([
            .failure(.http(status: 401, message: "invalid api key")),
            .success(ChatResponse(message: .assistant("should not run"), finishReason: "stop"))
        ])
        let session = AgentSession(
            client: client,
            workspace: FileWorkspace(root: directory.url),
            config: AgentConfiguration(maxRetries: 3, retryBaseDelayMilliseconds: 0)
        )

        do {
            try await session.send("hi", approval: { _ in [] }, onEvent: { _ in })
            Issue.record("Expected the request to fail")
        } catch let error as AgentError {
            #expect(error == .model("Model request failed (HTTP 401): invalid api key"))
        }

        let requests = await client.recordedRequests()
        #expect(requests.count == 1)
    }

    @Test func recoversFromContextOverflowOnce() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let filler = String(repeating: "x", count: 150)
        var history: [ChatMessage] = [.system("old prompt")]
        for index in 0..<20 {
            history.append(.user("question \(index) \(filler)"))
            history.append(.assistant("answer \(index) \(filler)"))
        }

        let client = FlakyModelClient([
            .failure(.http(
                status: 400,
                message: "This model's maximum context length is 8192 tokens."
            )),
            .success(ChatResponse(message: .assistant("Recovered."), finishReason: "stop"))
        ])
        let summarizer = RecordingSummarizer(summary: "## Goal\nContinue")
        let recorder = EventRecorder()
        let session = AgentSession(
            client: client,
            workspace: FileWorkspace(root: directory.url),
            config: AgentConfiguration(
                contextCharacterBudget: 10_000,
                retainedTurns: 2,
                compactedToolOutputCharacters: 1_000,
                maxRetries: 0,
                maxOverflowRecoveries: 1
            ),
            summarizer: summarizer
        )
        await session.restore(history)

        try await session.send(
            "continue",
            approval: { _ in [] },
            onEvent: { await recorder.record($0) }
        )

        let requests = await client.recordedRequests()
        #expect(requests.count == 2)
        #expect((requests.last?.messages.count ?? 0) < (requests.first?.messages.count ?? 0))

        let summarized = await summarizer.receivedMessages()
        #expect(summarized.count == 1)

        let events = await recorder.snapshot()
        #expect(events.prefix(3) == [
            .assistantResponseRestarted,
            .contextCompactionStarted,
            .contextCompactionFinished(success: true)
        ])
        #expect(events.contains(.assistantMessage("Recovered.")))
    }

    @Test func injectsProjectInstructionsIntoSystemPrompt() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("AGENTS.md", "# Conventions\nUse tabs and write tests.\n")

        let client = ScriptedModelClient([
            ChatResponse(message: .assistant("Done."), finishReason: "stop")
        ])
        let session = AgentSession(
            client: client,
            workspace: FileWorkspace(root: directory.url)
        )

        let instructions = await session.loadedInstructions
        #expect(instructions.path == "AGENTS.md")

        try await session.send(
            "hi",
            approval: { _ in [] },
            onEvent: { _ in }
        )

        let requests = await client.recordedRequests()
        let system = requests.first?.messages.first?.content ?? ""
        #expect(system.hasPrefix(AgentPrompts.system))
        #expect(system.contains("Use tabs and write tests."))
        #expect(system.contains("Project instructions from AGENTS.md"))

        await session.restore([
            .system("stale prompt"),
            .user("hi")
        ])
        let history = await session.history
        #expect(history.first?.content?.hasPrefix(AgentPrompts.system) == true)
        #expect(history.first?.content?.contains("Use tabs and write tests.") == true)
    }

    @Test func restoresHistoryWithCurrentSystemPrompt() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let session = AgentSession(
            client: ScriptedModelClient([]),
            workspace: FileWorkspace(root: directory.url)
        )
        await session.restore([
            .system("old prompt"),
            .user("hi"),
            .assistant("hello")
        ])

        let history = await session.history
        #expect(history.count == 3)
        #expect(history[0].role == .system)
        #expect(history[0].content == AgentPrompts.system)
        #expect(history[1].content == "hi")
        #expect(history[2].content == "hello")
    }

    @Test func compactsRestoredHistoryWithStructuredSummary() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let filler = String(repeating: "x", count: 200)
        var history: [ChatMessage] = [.system("old prompt")]
        for index in 0..<20 {
            history.append(.user("question \(index) \(filler)"))
            history.append(.assistant("answer \(index) \(filler)"))
        }

        let client = ScriptedModelClient([
            ChatResponse(message: .assistant("done"), finishReason: "stop")
        ])
        let summarizer = RecordingSummarizer(summary: "## Goal\nContinue the work")
        let recorder = EventRecorder()
        // The budget must leave room above the system prompt, which grows as tools are added.
        let budget = AgentPrompts.system.count + 1_200
        let session = AgentSession(
            client: client,
            workspace: FileWorkspace(root: directory.url),
            config: AgentConfiguration(
                contextCharacterBudget: budget,
                retainedTurns: 2,
                compactedToolOutputCharacters: 100
            ),
            summarizer: summarizer
        )
        await session.restore(history)

        try await session.send(
            "hi",
            approval: { _ in [] },
            onEvent: { await recorder.record($0) }
        )

        let requests = await client.recordedRequests()
        let messages = requests.first?.messages ?? []
        let totalCharacters = messages.reduce(0) { $0 + ($1.content?.count ?? 0) }

        #expect(requests.count == 1)
        #expect(messages.count < history.count)
        #expect(messages.first?.role == .system)
        #expect(messages.first?.content == AgentPrompts.system)
        #expect(messages.contains {
            $0.role == .user && $0.content?.contains("## Goal\nContinue the work") == true
        })
        #expect(totalCharacters <= budget)

        let summarized = await summarizer.receivedMessages()
        #expect(summarized.count == 1)
        #expect(summarized.first?.contains {
            $0.content?.contains("question 0") == true
        } == true)

        let events = await recorder.snapshot()
        #expect(events.first == .contextCompactionStarted)
        #expect(events.dropFirst().first == .contextCompactionFinished(success: true))
    }

    @Test func fallsBackToDeterministicCompactionWhenSummaryFails() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let filler = String(repeating: "x", count: 200)
        var history: [ChatMessage] = [.system("old prompt")]
        for index in 0..<20 {
            history.append(.user("question \(index) \(filler)"))
            history.append(.assistant("answer \(index) \(filler)"))
        }

        let client = ScriptedModelClient([
            ChatResponse(message: .assistant("done"), finishReason: "stop")
        ])
        let recorder = EventRecorder()
        let session = AgentSession(
            client: client,
            workspace: FileWorkspace(root: directory.url),
            config: AgentConfiguration(
                contextCharacterBudget: 2_400,
                retainedTurns: 2,
                compactedToolOutputCharacters: 100
            ),
            summarizer: FailingSummarizer()
        )
        await session.restore(history)

        try await session.send(
            "hi",
            approval: { _ in [] },
            onEvent: { await recorder.record($0) }
        )

        let requests = await client.recordedRequests()
        let messages = requests.first?.messages ?? []

        #expect(messages.first?.content == AgentPrompts.system)
        #expect(messages.contains {
            $0.role == .user && $0.content?.contains("Context compacted") == true
        })

        let events = await recorder.snapshot()
        #expect(events.first == .contextCompactionStarted)
        #expect(events.dropFirst().first == .contextCompactionFinished(success: false))
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
        let failure = events.compactMap { event -> String? in
            if case .failed(let message) = event { return message }
            return nil
        }.first
        #expect(failure?.contains("continue") == true)

        let requests = await client.recordedRequests()
        #expect(requests.count == 2)
        #expect(requests[0].messages.contains {
            $0.content?.contains("Tool budget") == true
        } == false)
        #expect(requests[1].messages.last?.content?.contains("final tool round") == true)
    }
}

struct AgentModeLoopTests {
    @Test func planModeHidesWriteToolsAndDeniesCalls() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("README.md", "old\n")

        let workspace = FileWorkspace(root: directory.url)
        let client = ScriptedModelClient([
            toolCall(
                name: "write_file",
                arguments: #"{"path":"README.md","content":"new\n"}"#
            ),
            ChatResponse(message: .assistant("Plan ready."), finishReason: "stop")
        ])
        let session = AgentSession(client: client, workspace: workspace, mode: .plan)
        let recorder = EventRecorder()
        let approvalCalls = LockedBox(0)

        try await session.send(
            "update readme",
            approval: { proposals in
                approvalCalls.set(approvalCalls.get() + 1)
                return proposals.map { .acceptAll(proposalID: $0.id) }
            },
            onEvent: { await recorder.record($0) }
        )

        #expect(try workspace.read("README.md", maxBytes: 1000) == "old\n")
        #expect(approvalCalls.get() == 0)

        let requests = await client.recordedRequests()
        let toolNames = Set(requests[0].tools.map(\.name))
        #expect(!toolNames.contains("write_file"))
        #expect(toolNames.contains("read_file"))
        #expect(requests[0].messages.first?.content?.contains("Current mode: Plan") == true)

        let toolMessage = requests[1].messages.last { $0.role == .tool }
        #expect(toolMessage?.content?.contains("disabled in Plan mode") == true)

        let events = await recorder.snapshot()
        #expect(!hasProposalsPending(events))
    }

    @Test func autoModeAppliesSafeChangesWithoutApproval() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("README.md", "old\n")

        let workspace = FileWorkspace(root: directory.url)
        let client = ScriptedModelClient([
            toolCall(
                name: "write_file",
                arguments: #"{"path":"README.md","content":"new\n"}"#
            ),
            ChatResponse(message: .assistant("Updated."), finishReason: "stop")
        ])
        let session = AgentSession(client: client, workspace: workspace, mode: .auto)
        let recorder = EventRecorder()
        let approvalCalls = LockedBox(0)

        try await session.send(
            "update readme",
            approval: { proposals in
                approvalCalls.set(approvalCalls.get() + 1)
                return proposals.map { .acceptAll(proposalID: $0.id) }
            },
            onEvent: { await recorder.record($0) }
        )

        #expect(try workspace.read("README.md", maxBytes: 1000) == "new\n")
        #expect(approvalCalls.get() == 0)

        let events = await recorder.snapshot()
        #expect(!hasProposalsPending(events))
        let changes = appliedChanges(events)
        #expect(changes.count == 1)
        #expect(changes.first?.didWrite == true)

        let requests = await client.recordedRequests()
        let toolMessage = requests[1].messages.last { $0.role == .tool }
        #expect(toolMessage?.content?.contains("Applied change to README.md") == true)
        #expect(requests[0].messages.first?.content?.contains("Current mode: Auto") == true)
    }

    @Test func autoModeReviewsDeleteAndMove() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("temp.txt", "bye\n")

        let workspace = FileWorkspace(root: directory.url)
        let client = ScriptedModelClient([
            toolCall(name: "delete_file", arguments: #"{"path":"temp.txt"}"#),
            ChatResponse(message: .assistant("Deleted."), finishReason: "stop")
        ])
        let session = AgentSession(client: client, workspace: workspace, mode: .auto)
        let recorder = EventRecorder()
        let approvalCalls = LockedBox(0)
        let reviewedKinds = LockedBox<[FileProposal.Kind]>([])

        try await session.send(
            "delete temp",
            approval: { proposals in
                approvalCalls.set(approvalCalls.get() + 1)
                reviewedKinds.set(proposals.map(\.kind))
                return proposals.map { .acceptAll(proposalID: $0.id) }
            },
            onEvent: { await recorder.record($0) }
        )

        #expect(!workspace.exists("temp.txt"))
        #expect(approvalCalls.get() == 1)
        #expect(reviewedKinds.get() == [.delete])

        let events = await recorder.snapshot()
        #expect(hasProposalsPending(events))
        #expect(appliedChanges(events).contains { $0.didWrite })
    }

    @Test func bypassModeAppliesDestructiveChangesWithoutApproval() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("temp.txt", "bye\n")

        let workspace = FileWorkspace(root: directory.url)
        let client = ScriptedModelClient([
            toolCall(name: "delete_file", arguments: #"{"path":"temp.txt"}"#),
            ChatResponse(message: .assistant("Deleted."), finishReason: "stop")
        ])
        let session = AgentSession(client: client, workspace: workspace, mode: .bypass)
        let recorder = EventRecorder()
        let approvalCalls = LockedBox(0)

        try await session.send(
            "delete temp",
            approval: { proposals in
                approvalCalls.set(approvalCalls.get() + 1)
                return proposals.map { .acceptAll(proposalID: $0.id) }
            },
            onEvent: { await recorder.record($0) }
        )

        #expect(!workspace.exists("temp.txt"))
        #expect(approvalCalls.get() == 0)

        let events = await recorder.snapshot()
        #expect(!hasProposalsPending(events))
        #expect(appliedChanges(events).contains { $0.didWrite })
        #expect(requestsContainBypassGuidance(await client.recordedRequests()))
    }

    @Test func setModeRebuildsSystemPrompt() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let client = ScriptedModelClient([
            ChatResponse(message: .assistant("Plan ready."), finishReason: "stop")
        ])
        let session = AgentSession(
            client: client,
            workspace: FileWorkspace(root: directory.url),
            mode: .ask
        )

        #expect(await session.currentMode == .ask)
        await session.setMode(.plan)
        #expect(await session.currentMode == .plan)

        try await session.send(
            "plan",
            approval: { _ in [] },
            onEvent: { _ in }
        )

        let requests = await client.recordedRequests()
        #expect(requests[0].messages.first?.content?.contains("Current mode: Plan") == true)
        #expect(requests[0].messages.first?.content?.hasPrefix(AgentPrompts.system) == true)
    }

    private func hasProposalsPending(_ events: [AgentEvent]) -> Bool {
        events.contains {
            if case .proposalsPending = $0 { return true }
            return false
        }
    }

    private func appliedChanges(_ events: [AgentEvent]) -> [AppliedChange] {
        events.flatMap { event -> [AppliedChange] in
            if case .changesApplied(let changes) = event {
                return changes
            }
            return []
        }
    }

    private func requestsContainBypassGuidance(_ requests: [ChatRequest]) -> Bool {
        requests.first?.messages.first?.content?.contains("Current mode: Bypass") == true
    }
}

struct AgentPlanLoopTests {
    @Test func submittedPlanEndsTheRun() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let client = ScriptedModelClient([
            toolCall(
                name: "submit_plan",
                arguments: #"{"title":"Ship it","steps":[{"title":"Edit README","files":["README.md"]}]}"#
            )
        ])
        let session = AgentSession(
            client: client,
            workspace: FileWorkspace(root: directory.url),
            mode: .plan
        )
        let recorder = EventRecorder()

        try await session.send(
            "plan",
            approval: { _ in [] },
            onEvent: { await recorder.record($0) }
        )

        let events = await recorder.snapshot()
        let plans = events.compactMap { event -> AgentPlan? in
            if case .planSubmitted(let plan) = event {
                return plan
            }
            return nil
        }
        #expect(plans.first?.title == "Ship it")
        #expect(plans.first?.steps.first?.title == "Edit README")
        #expect(events.last == .finished)

        let requests = await client.recordedRequests()
        #expect(requests.count == 1)
        #expect(requests[0].tools.map(\.name).contains("submit_plan"))

        let history = await session.history
        #expect(history.last?.role == .tool)
        #expect(history.last?.content == "Plan submitted.")
    }
}

private struct SleepyReadTool: AgentTool {
    let name: String
    let delayMilliseconds: Int

    var capabilities: Set<ToolCapability> { [.readFiles] }

    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: name,
            parameters: .object(["type": .string("object")])
        )
    }

    func execute(arguments: Data, context: ToolContext) async throws -> ToolOutput {
        try await Task.sleep(for: .milliseconds(delayMilliseconds))
        return ToolOutput(content: name)
    }
}

private struct SleepyWriteTool: AgentTool {
    let name: String
    let delayMilliseconds: Int

    var capabilities: Set<ToolCapability> { [.writeFiles] }

    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: name,
            parameters: .object(["type": .string("object")])
        )
    }

    func execute(arguments: Data, context: ToolContext) async throws -> ToolOutput {
        try await Task.sleep(for: .milliseconds(delayMilliseconds))
        return ToolOutput(content: name)
    }
}

struct ToolConcurrencyTests {
    private func multiToolCall(_ calls: [ToolCall]) -> ChatResponse {
        ChatResponse(
            message: .assistant(nil, toolCalls: calls),
            finishReason: "tool_calls"
        )
    }

    @Test func readOnlyToolsRunConcurrentlyAndKeepCallOrder() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let client = ScriptedModelClient([
            multiToolCall([
                ToolCall(id: "1", name: "slow_a", arguments: "{}"),
                ToolCall(id: "2", name: "slow_b", arguments: "{}")
            ]),
            ChatResponse(message: .assistant("done"), finishReason: "stop")
        ])
        let session = AgentSession(
            client: client,
            workspace: FileWorkspace(root: directory.url),
            tools: ToolRegistry([
                SleepyReadTool(name: "slow_a", delayMilliseconds: 300),
                SleepyReadTool(name: "slow_b", delayMilliseconds: 300)
            ]),
            config: AgentConfiguration(
                maxConcurrentReadTools: 2,
                toolTimeoutMilliseconds: 5_000
            )
        )
        let recorder = EventRecorder()

        let start = Date()
        try await session.send(
            "run",
            approval: { _ in [] },
            onEvent: { await recorder.record($0) }
        )
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 0.55)

        let requests = await client.recordedRequests()
        let toolMessages = requests[1].messages
            .filter { $0.role == .tool }
            .compactMap(\.content)
        #expect(toolMessages == ["slow_a", "slow_b"])

        let events = await recorder.snapshot()
        let started = events.compactMap { event -> String? in
            if case .toolStarted(let name, _, _, _) = event { return name }
            return nil
        }
        #expect(started == ["slow_a", "slow_b"])

        let finished = events.compactMap { event -> String? in
            if case .toolFinished(let name, _, _) = event { return name }
            return nil
        }
        #expect(finished == ["slow_a", "slow_b"])
    }

    @Test func toolEventsCarryCallIDAndPathDetail() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try "hello".write(
            to: directory.url.appendingPathComponent("sample.txt"),
            atomically: true,
            encoding: .utf8
        )

        let client = ScriptedModelClient([
            toolCall(id: "read_1", name: "read_file", arguments: #"{"path":"sample.txt"}"#),
            ChatResponse(message: .assistant("done"), finishReason: "stop")
        ])
        let session = AgentSession(
            client: client,
            workspace: FileWorkspace(root: directory.url),
            mode: .bypass
        )
        let recorder = EventRecorder()

        try await session.send(
            "read it",
            approval: { _ in [] },
            onEvent: { await recorder.record($0) }
        )

        let events = await recorder.snapshot()
        let starts = events.compactMap { event -> (String, String, String?)? in
            if case .toolStarted(let name, let callID, let detail, _) = event {
                return (name, callID, detail)
            }
            return nil
        }
        #expect(starts.count == 1)
        #expect(starts.first?.0 == "read_file")
        #expect(starts.first?.1 == "read_1")
        #expect(starts.first?.2 == "sample.txt")

        let finishes = events.compactMap { event -> (String, String)? in
            if case .toolFinished(let name, let callID, _) = event {
                return (name, callID)
            }
            return nil
        }
        #expect(finishes.count == 1)
        #expect(finishes.first?.1 == "read_1")
    }

    @Test func scriptToolEventsCarryPreviewAndOutput() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let client = ScriptedModelClient([
            toolCall(name: "run_script", arguments: #"{"script":"console.log('ok')"}"#),
            ChatResponse(message: .assistant("done"), finishReason: "stop")
        ])
        let session = AgentSession(
            client: client,
            workspace: FileWorkspace(root: directory.url),
            mode: .bypass,
            scripting: ScriptRuntimes([FakeScriptRuntime { _, _ in
                ScriptResult(
                    exitCode: 0,
                    stdout: "ok\n",
                    stderr: "",
                    termination: .exited,
                    durationMilliseconds: 3
                )
            }])
        )
        let recorder = EventRecorder()

        try await session.send(
            "run it",
            approval: { _ in [] },
            onEvent: { await recorder.record($0) }
        )

        let events = await recorder.snapshot()
        let previews = events.compactMap { event -> String? in
            if case .toolStarted(_, _, _, let preview) = event { return preview }
            return nil
        }
        #expect(previews == ["console.log('ok')"])

        let summaries = events.compactMap { event -> String? in
            if case .toolFinished(_, _, let summary) = event { return summary }
            return nil
        }
        #expect(summaries.first?.contains("exit 0") == true)
        #expect(summaries.first?.contains("ok") == true)
    }

    @Test func writeToolsRemainSequential() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let client = ScriptedModelClient([
            multiToolCall([
                ToolCall(id: "1", name: "slow_write_a", arguments: "{}"),
                ToolCall(id: "2", name: "slow_write_b", arguments: "{}")
            ]),
            ChatResponse(message: .assistant("done"), finishReason: "stop")
        ])
        let session = AgentSession(
            client: client,
            workspace: FileWorkspace(root: directory.url),
            tools: ToolRegistry([
                SleepyWriteTool(name: "slow_write_a", delayMilliseconds: 150),
                SleepyWriteTool(name: "slow_write_b", delayMilliseconds: 150)
            ]),
            config: AgentConfiguration(
                maxConcurrentReadTools: 4,
                toolTimeoutMilliseconds: 5_000
            )
        )

        let start = Date()
        try await session.send(
            "run",
            approval: { _ in [] },
            onEvent: { _ in }
        )
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed >= 0.25)
    }

    @Test func toolTimeoutReturnsAnErrorAndRunContinues() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let client = ScriptedModelClient([
            multiToolCall([ToolCall(id: "1", name: "too_slow", arguments: "{}")]),
            ChatResponse(message: .assistant("done"), finishReason: "stop")
        ])
        let session = AgentSession(
            client: client,
            workspace: FileWorkspace(root: directory.url),
            tools: ToolRegistry([
                SleepyReadTool(name: "too_slow", delayMilliseconds: 5_000)
            ]),
            config: AgentConfiguration(
                maxConcurrentReadTools: 1,
                toolTimeoutMilliseconds: 1_000
            )
        )

        let start = Date()
        try await session.send(
            "run",
            approval: { _ in [] },
            onEvent: { _ in }
        )
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 2.5)
        let requests = await client.recordedRequests()
        let toolMessage = requests[1].messages.last { $0.role == .tool }
        #expect(toolMessage?.content?.contains("timed out") == true)
    }
}

private struct ReviewedTool: AgentTool {
    let name: String
    let executed: LockedBox<Int>

    var capabilities: Set<ToolCapability> { [.network] }

    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: name,
            parameters: .object(["type": .string("object")])
        )
    }

    func review(arguments: Data, context: ToolContext) async throws -> ActionRequest? {
        ActionRequest(
            method: "POST",
            url: "https://example.com/write",
            headers: ["Content-Type": "text/plain"],
            bodyPreview: "payload"
        )
    }

    func execute(arguments: Data, context: ToolContext) async throws -> ToolOutput {
        executed.set(executed.get() + 1)
        return ToolOutput(content: "executed")
    }
}

struct ActionApprovalTests {
    private func run(
        directory: URL,
        mode: AgentMode,
        decision: ActionDecision,
        approvalCalls: LockedBox<Int>
    ) async throws -> (executed: Int, events: [AgentEvent], requests: [ChatRequest]) {
        let executed = LockedBox(0)
        let tool = ReviewedTool(name: "network_write", executed: executed)
        let client = ScriptedModelClient([
            toolCall(name: "network_write", arguments: "{}"),
            ChatResponse(message: .assistant("done"), finishReason: "stop")
        ])
        let session = AgentSession(
            client: client,
            workspace: FileWorkspace(root: directory),
            tools: ToolRegistry([tool]),
            mode: mode
        )
        let recorder = EventRecorder()

        try await session.send(
            "run",
            approval: { _ in [] },
            actionApproval: { _ in
                approvalCalls.set(approvalCalls.get() + 1)
                return decision
            },
            onEvent: { await recorder.record($0) }
        )

        let events = await recorder.snapshot()
        let requests = await client.recordedRequests()
        return (executed.get(), events, requests)
    }

    private func hasActionPending(_ events: [AgentEvent]) -> Bool {
        events.contains {
            if case .actionPending = $0 { return true }
            return false
        }
    }

    @Test func askModeAllowsApprovedNetworkWrite() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        let calls = LockedBox(0)

        let result = try await run(
            directory: directory.url,
            mode: .ask,
            decision: .allowed,
            approvalCalls: calls
        )

        #expect(result.executed == 1)
        #expect(calls.get() == 1)
        #expect(hasActionPending(result.events))
        let toolMessage = result.requests[1].messages.last { $0.role == .tool }
        #expect(toolMessage?.content == "executed")
    }

    @Test func askModeDeniesRejectedNetworkWrite() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        let calls = LockedBox(0)

        let result = try await run(
            directory: directory.url,
            mode: .ask,
            decision: .denied,
            approvalCalls: calls
        )

        #expect(result.executed == 0)
        #expect(calls.get() == 1)
        #expect(hasActionPending(result.events))
        let toolMessage = result.requests[1].messages.last { $0.role == .tool }
        #expect(toolMessage?.content?.contains("denied by the user") == true)
    }

    @Test func bypassModeSkipsApprovalForNetworkWrite() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        let calls = LockedBox(0)

        let result = try await run(
            directory: directory.url,
            mode: .bypass,
            decision: .denied,
            approvalCalls: calls
        )

        #expect(result.executed == 1)
        #expect(calls.get() == 0)
        #expect(!hasActionPending(result.events))
    }

    @Test func planModeBlocksNetworkWrite() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        let calls = LockedBox(0)

        let result = try await run(
            directory: directory.url,
            mode: .plan,
            decision: .allowed,
            approvalCalls: calls
        )

        #expect(result.executed == 0)
        #expect(calls.get() == 0)
        #expect(!hasActionPending(result.events))
        let toolMessage = result.requests[1].messages.last { $0.role == .tool }
        #expect(toolMessage?.content?.contains("disabled in Plan mode") == true)
    }
}
