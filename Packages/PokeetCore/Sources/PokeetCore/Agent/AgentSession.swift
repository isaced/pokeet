import Foundation

public actor AgentSession {
    private let client: any ModelClient
    private let registry: ToolRegistry
    private let workspace: any Workspace
    private let git: (any GitInspecting)?
    private let sessionID: String?
    private let config: AgentConfiguration
    private let compactor: ContextCompactor
    private let summarizer: any ContextSummarizer
    private let instructions: ProjectInstructions
    private let scripting: ScriptRuntimes?
    private var baseSystemPrompt: String
    private var mode: AgentMode
    private var networkPolicy: NetworkAccessPolicy
    private var messages: [ChatMessage]

    public init(
        client: any ModelClient,
        workspace: any Workspace,
        git: (any GitInspecting)? = nil,
        sessionID: String? = nil,
        tools: ToolRegistry = .standard,
        systemPrompt: String = AgentPrompts.system,
        mode: AgentMode = .ask,
        networkPolicy: NetworkAccessPolicy = .init(),
        scripting: ScriptRuntimes? = nil,
        config: AgentConfiguration = AgentConfiguration(),
        summarizer: (any ContextSummarizer)? = nil
    ) {
        self.client = client
        self.registry = tools
        self.workspace = workspace
        self.git = git
        self.sessionID = sessionID
        self.config = config
        self.compactor = ContextCompactor(
            maxCharacters: config.contextCharacterBudget,
            retainedTurns: config.retainedTurns,
            toolOutputCharacters: config.compactedToolOutputCharacters
        )
        self.summarizer = summarizer ?? ModelContextSummarizer(
            client: client,
            sessionID: sessionID
        )
        self.instructions = ProjectInstructions.load(from: workspace)
        self.baseSystemPrompt = systemPrompt
        self.mode = mode
        self.networkPolicy = networkPolicy
        self.scripting = scripting
        self.messages = [.system(instructions.compose(with: systemPrompt + mode.promptGuidance))]
    }

    public var history: [ChatMessage] {
        messages
    }

    public var loadedInstructions: ProjectInstructions {
        instructions
    }

    public var currentMode: AgentMode {
        mode
    }

    public func setMode(_ mode: AgentMode) {
        guard self.mode != mode else { return }
        self.mode = mode
        if messages.isEmpty {
            messages = [systemMessage]
        } else {
            messages[0] = systemMessage
        }
    }

    public func setNetworkPolicy(_ policy: NetworkAccessPolicy) {
        networkPolicy = policy
    }

    public func reset(systemPrompt: String = AgentPrompts.system) {
        baseSystemPrompt = systemPrompt
        messages = [systemMessage]
    }

    public func restore(_ history: [ChatMessage], systemPrompt: String = AgentPrompts.system) {
        baseSystemPrompt = systemPrompt
        messages = [systemMessage]
            + history.filter { $0.role != .system }
    }

    private var systemMessage: ChatMessage {
        .system(instructions.compose(with: baseSystemPrompt + mode.promptGuidance))
    }

    public func send(
        _ text: String,
        images: [ChatImage] = [],
        approval: @escaping ApprovalHandler,
        actionApproval: @escaping ActionApprovalHandler = { _ in .denied },
        onEvent: @escaping EventHandler
    ) async throws {
        let activeMode = mode
        let activeRegistry = registry.filtered(for: mode)
        messages.append(ChatMessage(
            role: .user,
            content: text.isEmpty ? nil : text,
            images: images.isEmpty ? nil : images
        ))

        var iteration = 0
        var overflowRecoveries = 0
        while true {
            if Task.isCancelled {
                throw AgentError.cancelled
            }

            if iteration >= config.maxIterations {
                let message = "Stopped after \(config.maxIterations) tool rounds without a final answer. "
                    + "Send “continue” to keep going."
                await onEvent(.failed(message))
                throw AgentError.iterationLimit
            }
            iteration += 1

            var requestMessages = try await messagesForRequest(onEvent: onEvent)
            let roundsLeft = config.maxIterations - iteration + 1
            if iteration > 1, roundsLeft <= 2 {
                requestMessages.append(.user(
                    roundsLeft == 1
                        ? "[Tool budget: this is your final tool round. Stop calling tools and write your final answer now.]"
                        : "[Tool budget: 2 tool rounds remain, including this one. Start wrapping up and answer.]"
                ))
            }
            var request = ChatRequest(
                messages: requestMessages,
                tools: activeRegistry.schemas,
                sessionID: sessionID
            )
            var retryAttempt = 0
            var response: StreamResult?

            do {
                while response == nil {
                    do {
                        response = try await consume(client.stream(request), onEvent: onEvent)
                    } catch let error as ModelError {
                        if case .cancelled = error {
                            throw AgentError.cancelled
                        }

                        if isContextOverflow(error), overflowRecoveries < config.maxOverflowRecoveries {
                            overflowRecoveries += 1
                            await onEvent(.assistantResponseRestarted)
                            try await compactForOverflow(onEvent: onEvent)
                            request = ChatRequest(
                                messages: messages,
                                tools: activeRegistry.schemas,
                                sessionID: sessionID
                            )
                            continue
                        }

                        if isRetryable(error), retryAttempt < config.maxRetries {
                            retryAttempt += 1
                            await onEvent(.assistantResponseRestarted)
                            let delay = retryDelayMilliseconds(attempt: retryAttempt)
                            await onEvent(.retryScheduled(
                                attempt: retryAttempt,
                                maxAttempts: config.maxRetries,
                                delayMilliseconds: delay,
                                reason: error.errorDescription ?? "Model request failed."
                            ))
                            if delay > 0 {
                                do {
                                    try await Task.sleep(
                                        nanoseconds: UInt64(delay) * 1_000_000
                                    )
                                } catch {
                                    throw AgentError.cancelled
                                }
                            }
                            if Task.isCancelled {
                                throw AgentError.cancelled
                            }
                            continue
                        }

                        throw error
                    }
                }
            } catch let error as ModelError {
                if case .cancelled = error {
                    throw AgentError.cancelled
                }
                let message = error.errorDescription ?? "Model request failed."
                await onEvent(.failed(message))
                throw AgentError.model(message)
            } catch is CancellationError {
                throw AgentError.cancelled
            } catch let error as AgentError {
                throw error
            } catch {
                let message = error.localizedDescription
                await onEvent(.failed(message))
                throw AgentError.model(message)
            }

            guard let response else {
                throw AgentError.model("Model request produced no response.")
            }

            if let usage = response.usage {
                await onEvent(.usage(usage))
            }

            let assistantMessage = ChatMessage.assistant(
                response.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil
                    : response.content,
                toolCalls: response.toolCalls.isEmpty ? nil : response.toolCalls
            )
            messages.append(assistantMessage)

            if let content = assistantMessage.content,
               !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await onEvent(.assistantMessage(content))
            }

            guard let toolCalls = assistantMessage.toolCalls, !toolCalls.isEmpty else {
                await onEvent(.finished)
                return
            }

            let toolRun = try await runTools(
                toolCalls,
                activeMode: activeMode,
                actionApproval: actionApproval,
                onEvent: onEvent
            )
            let executions = toolRun.executions
            let submittedPlan = toolRun.plan

            var proposalsByPath: [String: FileProposal] = [:]
            var proposalOwner: [String: String] = [:]
            for execution in executions {
                for proposal in execution.output?.proposals ?? [] {
                    proposalsByPath[proposal.path] = proposal
                    proposalOwner[proposal.path] = execution.call.id
                }
            }

            var proposalResults: [UUID: String] = [:]
            if !proposalsByPath.isEmpty {
                let pending = proposalsByPath.values.sorted { $0.path < $1.path }
                var decisions: [ProposalDecision] = []

                switch activeMode.approvalPolicy {
                case .review:
                    await onEvent(.proposalsPending(pending))
                    decisions = await approval(pending)
                case .autoApplySafe:
                    let risky = pending.filter { $0.kind == .delete || $0.kind == .move }
                    decisions = pending
                        .filter { $0.kind == .create || $0.kind == .update }
                        .map { .acceptAll(proposalID: $0.id) }
                    if !risky.isEmpty {
                        await onEvent(.proposalsPending(risky))
                        decisions += await approval(risky)
                    }
                case .autoApplyAll:
                    decisions = pending.map { .acceptAll(proposalID: $0.id) }
                case .deny:
                    decisions = pending.map { .reject(proposalID: $0.id) }
                }

                if Task.isCancelled {
                    throw AgentError.cancelled
                }

                let decisionsByID = Dictionary(
                    uniqueKeysWithValues: decisions.map { ($0.proposalID, $0) }
                )

                var changes: [AppliedChange] = []
                for proposal in pending {
                    let decision = decisionsByID[proposal.id]
                        ?? .reject(proposalID: proposal.id)

                    do {
                        let application = try ProposalApplier.apply(
                            proposal,
                            decision: decision,
                            in: workspace
                        )
                        let message = resultMessage(
                            for: proposal,
                            decision: decision,
                            application: application
                        )
                        proposalResults[proposal.id] = message
                        changes.append(AppliedChange(
                            path: proposal.path,
                            kind: proposal.kind.rawValue,
                            didWrite: application.didWrite,
                            addedLines: proposal.addedLines,
                            removedLines: proposal.removedLines,
                            message: message
                        ))
                    } catch {
                        let detail = (error as? LocalizedError)?.errorDescription
                            ?? error.localizedDescription
                        let message = "Error applying change to \(proposal.path): \(detail)"
                        proposalResults[proposal.id] = message
                        changes.append(AppliedChange(
                            path: proposal.path,
                            kind: proposal.kind.rawValue,
                            didWrite: false,
                            addedLines: proposal.addedLines,
                            removedLines: proposal.removedLines,
                            message: message
                        ))
                    }
                }

                if !changes.isEmpty {
                    await onEvent(.changesApplied(changes))
                }
            }

            for execution in executions {
                let content: String
                if let proposals = execution.output?.proposals, let proposal = proposals.first {
                    if proposalOwner[proposal.path] != execution.call.id {
                        content = "Superseded by a later write to \(proposal.path); no change applied."
                    } else if let result = proposalResults[proposal.id] {
                        content = result
                    } else {
                        content = "Change to \(proposal.path) was not applied."
                    }
                } else {
                    content = execution.content ?? ""
                }

                messages.append(.tool(clip(content), callID: execution.call.id))
            }

            if let submittedPlan {
                await onEvent(.planSubmitted(submittedPlan))
                await onEvent(.finished)
                return
            }
        }
    }

    private static let readOnlyCapabilities: Set<ToolCapability> = [
        .readFiles, .gitRead, .network
    ]

    private struct ToolRunResult: Sendable {
        let executions: [ToolExecution]
        let plan: AgentPlan?
    }

    private struct ToolOutcome: Sendable {
        let index: Int
        let execution: ToolExecution
        let plan: AgentPlan?
    }

    private func runTools(
        _ calls: [ToolCall],
        activeMode: AgentMode,
        actionApproval: @escaping ActionApprovalHandler,
        onEvent: @escaping EventHandler
    ) async throws -> ToolRunResult {
        var slots = [ToolExecution?](repeating: nil, count: calls.count)
        var submittedPlan: AgentPlan?
        let context = ToolContext(
            workspace: workspace,
            git: git,
            networkPolicy: networkPolicy,
            scripting: scripting
        )
        let timeout = config.toolTimeoutMilliseconds
        var actions = [ActionRequest?](repeating: nil, count: calls.count)
        var reviewErrors = [String?](repeating: nil, count: calls.count)

        for (callIndex, call) in calls.enumerated() {
            guard let tool = registry.tool(named: call.name) else { continue }
            do {
                actions[callIndex] = try await tool.review(
                    arguments: Data(call.arguments.utf8),
                    context: context
                )
            } catch {
                reviewErrors[callIndex] = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }

        var index = 0

        while index < calls.count {
            if Task.isCancelled {
                throw AgentError.cancelled
            }
            let call = calls[index]

            guard let tool = registry.tool(named: call.name) else {
                await onEvent(.toolStarted(
                    name: call.name,
                    callID: call.id,
                    detail: Self.toolDetail(for: call)
                ))
                let message = "Unknown tool '\(call.name)'."
                slots[index] = ToolExecution(call: call, content: "Error: \(message)")
                await onEvent(.toolFinished(name: call.name, callID: call.id, summary: message))
                index += 1
                continue
            }

            guard activeMode.allows(tool.capabilities) else {
                await onEvent(.toolStarted(
                    name: call.name,
                    callID: call.id,
                    detail: Self.toolDetail(for: call)
                ))
                let message = "Error: '\(call.name)' is disabled in \(activeMode.displayName) mode. "
                    + "Investigate with read-only tools and present a plan; switch modes to apply changes."
                slots[index] = ToolExecution(call: call, content: message)
                await onEvent(.toolFinished(name: call.name, callID: call.id, summary: message))
                index += 1
                continue
            }

            if let reviewError = reviewErrors[index] {
                await onEvent(.toolStarted(
                    name: call.name,
                    callID: call.id,
                    detail: Self.toolDetail(for: call)
                ))
                slots[index] = ToolExecution(call: call, content: "Error: \(reviewError)")
                await onEvent(.toolFinished(name: call.name, callID: call.id, summary: reviewError))
                index += 1
                continue
            }

            if let action = actions[index] {
                await onEvent(.toolStarted(
                    name: call.name,
                    callID: call.id,
                    detail: Self.toolDetail(for: call)
                ))

                if activeMode == .plan {
                    let message = "Error: Network write actions are disabled in Plan mode."
                    slots[index] = ToolExecution(call: call, content: message)
                    await onEvent(.toolFinished(name: call.name, callID: call.id, summary: message))
                    index += 1
                    continue
                }

                if activeMode != .bypass {
                    await onEvent(.actionPending(action))
                    let decision = await actionApproval(action)
                    if !decision.allow {
                        let message = "Error: Network action was denied by the user."
                        slots[index] = ToolExecution(call: call, content: message)
                        await onEvent(.toolFinished(name: call.name, callID: call.id, summary: message))
                        index += 1
                        continue
                    }
                }

                let execution = await Self.executeTool(
                    tool,
                    call: call,
                    context: context,
                    timeoutMilliseconds: timeout
                )
                slots[index] = execution
                if let plan = execution.output?.plan {
                    submittedPlan = plan
                }
                await onEvent(.toolFinished(
                    name: call.name,
                    callID: call.id,
                    summary: Self.summary(of: execution)
                ))
                index += 1
                continue
            }

            let isReadOnly = !tool.capabilities.isEmpty
                && tool.capabilities.isSubset(of: Self.readOnlyCapabilities)

            if isReadOnly {
                var end = index
                while end < calls.count {
                    guard let next = registry.tool(named: calls[end].name),
                          activeMode.allows(next.capabilities),
                          actions[end] == nil,
                          reviewErrors[end] == nil,
                          !next.capabilities.isEmpty,
                          next.capabilities.isSubset(of: Self.readOnlyCapabilities)
                    else {
                        break
                    }
                    end += 1
                }

                let runCalls = Array(calls[index..<end])
                for runCall in runCalls {
                    await onEvent(.toolStarted(
                        name: runCall.name,
                        callID: runCall.id,
                        detail: Self.toolDetail(for: runCall)
                    ))
                }

                let chunkSize = max(1, config.maxConcurrentReadTools)
                var offset = 0
                while offset < runCalls.count {
                    if Task.isCancelled {
                        throw AgentError.cancelled
                    }
                    let chunkEnd = min(offset + chunkSize, runCalls.count)
                    let chunk = Array(runCalls[offset..<chunkEnd])
                    let baseIndex = index + offset

                    let results = await withTaskGroup(of: ToolOutcome.self) { group in
                        for (chunkOffset, chunkCall) in chunk.enumerated() {
                            guard let chunkTool = registry.tool(named: chunkCall.name) else {
                                continue
                            }
                            let slotIndex = baseIndex + chunkOffset
                            group.addTask { [timeout] in
                                let execution = await Self.executeTool(
                                    chunkTool,
                                    call: chunkCall,
                                    context: context,
                                    timeoutMilliseconds: timeout
                                )
                                return ToolOutcome(
                                    index: slotIndex,
                                    execution: execution,
                                    plan: execution.output?.plan
                                )
                            }
                        }

                        var collected: [ToolOutcome] = []
                        for await outcome in group {
                            collected.append(outcome)
                        }
                        return collected
                    }

                    for outcome in results.sorted(by: { $0.index < $1.index }) {
                        slots[outcome.index] = outcome.execution
                        if let plan = outcome.plan {
                            submittedPlan = plan
                        }
                        await onEvent(.toolFinished(
                            name: outcome.execution.call.name,
                            callID: outcome.execution.call.id,
                            summary: Self.summary(of: outcome.execution)
                        ))
                    }
                    offset = chunkEnd
                }

                index = end
            } else {
                await onEvent(.toolStarted(
                    name: call.name,
                    callID: call.id,
                    detail: Self.toolDetail(for: call)
                ))
                let execution = await Self.executeTool(
                    tool,
                    call: call,
                    context: context,
                    timeoutMilliseconds: timeout
                )
                slots[index] = execution
                if let plan = execution.output?.plan {
                    submittedPlan = plan
                }
                await onEvent(.toolFinished(
                    name: call.name,
                    callID: call.id,
                    summary: Self.summary(of: execution)
                ))
                index += 1
            }
        }

        if Task.isCancelled {
            throw AgentError.cancelled
        }
        return ToolRunResult(executions: slots.compactMap { $0 }, plan: submittedPlan)
    }

    private enum ToolAttempt: Sendable {
        case success(ToolOutput)
        case timedOut
        case failure(String)
    }

    private nonisolated static func executeTool(
        _ tool: any AgentTool,
        call: ToolCall,
        context: ToolContext,
        timeoutMilliseconds: Int
    ) async -> ToolExecution {
        await withTaskGroup(of: ToolAttempt.self) { group in
            group.addTask {
                do {
                    return .success(try await tool.execute(
                        arguments: Data(call.arguments.utf8),
                        context: context
                    ))
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                    return .failure(message)
                }
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(timeoutMilliseconds))
                return .timedOut
            }

            let result = await group.next() ?? .timedOut
            group.cancelAll()

            switch result {
            case .success(let output):
                return ToolExecution(call: call, output: output)
            case .timedOut:
                return ToolExecution(
                    call: call,
                    content: "Error: Tool '\(call.name)' timed out after \(timeoutMilliseconds) ms."
                )
            case .failure(let message):
                return ToolExecution(call: call, content: "Error: \(message)")
            }
        }
    }

    private static func summary(of execution: ToolExecution) -> String {
        if let output = execution.output {
            return String(output.content.prefix(200))
        }
        return execution.content ?? ""
    }

    private static func toolDetail(for call: ToolCall) -> String? {
        let data = call.arguments.data(using: .utf8)
        let object = data.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        } ?? [:]

        if let detail = gitDetail(for: call.name, arguments: object) {
            return detail
        }

        if call.name == RunScriptTool.toolName {
            if let path = nonEmpty(object["path"]) {
                return path
            }
            if let script = object["script"] as? String {
                let runtime = nonEmpty(object["runtime"]) ?? "javascript"
                return "\(runtime) · \(script.split(separator: "\n").count) lines"
            }
        }

        if let from = object["from"] as? String,
           let to = object["to"] as? String,
           !from.isEmpty {
            return "\(from) → \(to)"
        }
        if let method = object["method"] as? String,
           let url = object["url"] as? String,
           !url.isEmpty {
            return "\(method.uppercased()) \(url)"
        }
        for key in ["path", "pattern", "url", "title"] {
            if let value = object[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func gitDetail(
        for name: String,
        arguments: [String: Any]
    ) -> String? {
        switch name {
        case "git_status":
            return nonEmpty(arguments["path"]) ?? "working tree"
        case "git_diff":
            let staged = arguments["staged"] as? Bool ?? false
            var parts = [staged ? "staged" : "unstaged"]
            if let path = nonEmpty(arguments["path"]) {
                parts.append(path)
            }
            return parts.joined(separator: " · ")
        case "git_log":
            let limit = max(1, min(arguments["limit"] as? Int ?? 10, 50))
            return "last \(limit) commit\(limit == 1 ? "" : "s")"
        default:
            return nil
        }
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func consume(
        _ stream: AsyncThrowingStream<ModelStreamEvent, Error>,
        onEvent: EventHandler
    ) async throws -> StreamResult {
        var result = StreamResult()

        for try await event in stream {
            if Task.isCancelled {
                throw AgentError.cancelled
            }

            switch event {
            case .reasoningDelta(let delta):
                if !delta.isEmpty {
                    await onEvent(.assistantReasoningDelta(delta))
                }
            case .textDelta(let delta):
                result.content += delta
                if !delta.isEmpty {
                    await onEvent(.assistantTextDelta(delta))
                }
            case .completed(let response):
                if let content = response.message.content {
                    result.content = content
                }
                result.toolCalls = response.message.toolCalls ?? []
                result.usage = response.usage
            }
        }

        return result
    }

    private func isRetryable(_ error: ModelError) -> Bool {
        switch error {
        case .network:
            true
        case .http(let status, _):
            status == 408 || status == 429 || (500...599).contains(status)
        default:
            false
        }
    }

    private func isContextOverflow(_ error: ModelError) -> Bool {
        guard case .http(let status, let message) = error else { return false }
        guard status == 400 || status == 413 || status == 422 else { return false }

        let lowercased = message.lowercased()
        let markers = [
            "context length",
            "context_length_exceeded",
            "maximum context",
            "context window",
            "prompt is too long",
            "input is too long",
            "too many tokens",
            "reduce the length"
        ]
        return markers.contains { lowercased.contains($0) }
    }

    private func retryDelayMilliseconds(attempt: Int) -> Int {
        guard config.retryBaseDelayMilliseconds > 0 else { return 0 }
        let exponent = min(max(0, attempt - 1), 5)
        return min(config.retryBaseDelayMilliseconds * (1 << exponent), 8_000)
    }

    /// Shrink the history harder than the normal budget after the provider
    /// rejects the request as too large, then let the caller resend once.
    private func compactForOverflow(
        onEvent: @escaping EventHandler
    ) async throws {
        let emergency = ContextCompactor(
            maxCharacters: max(1_000, config.contextCharacterBudget / 2),
            retainedTurns: config.retainedTurns,
            toolOutputCharacters: config.compactedToolOutputCharacters
        )
        guard let plan = emergency.plan(messages, force: true) else { return }

        await onEvent(.contextCompactionStarted)

        if plan.hasMessagesToSummarize {
            do {
                let summary = try await summarizer.summarize(plan.messagesToSummarize)
                applyCompaction(summary: summary, plan: plan)
                await onEvent(.contextCompactionFinished(success: true))
                return
            } catch let error as ModelError {
                if case .cancelled = error {
                    throw AgentError.cancelled
                }
            } catch is CancellationError {
                throw AgentError.cancelled
            } catch {
            }
        }

        messages = emergency.compact(messages, force: true)
        await onEvent(.contextCompactionFinished(success: false))
    }

    private func messagesForRequest(
        onEvent: @escaping EventHandler
    ) async throws -> [ChatMessage] {
        guard let plan = compactor.plan(messages) else {
            return messages
        }
        guard plan.hasMessagesToSummarize else {
            return compactor.compact(messages)
        }

        if Task.isCancelled {
            throw AgentError.cancelled
        }

        await onEvent(.contextCompactionStarted)

        do {
            let summary = try await summarizer.summarize(plan.messagesToSummarize)
            applyCompaction(summary: summary, plan: plan)
            await onEvent(.contextCompactionFinished(success: true))
            return messages
        } catch let error as ModelError {
            if case .cancelled = error {
                throw AgentError.cancelled
            }
            await onEvent(.contextCompactionFinished(success: false))
            return compactor.compact(messages)
        } catch is CancellationError {
            throw AgentError.cancelled
        } catch {
            await onEvent(.contextCompactionFinished(success: false))
            return compactor.compact(messages)
        }
    }

    private func applyCompaction(summary: String, plan: CompactionPlan) {
        var keptMessages = plan.keptMessages
        let block = "[Context summary from earlier in this session. "
            + "Earlier messages were compacted to fit the model window.]\n\n"
            + "\(summary)\n\n"
            + "[End of context summary]"

        if let firstUserIndex = keptMessages.firstIndex(where: { $0.role == .user }) {
            var message = keptMessages[firstUserIndex]
            let existingContent = message.content ?? ""
            message.content = existingContent.isEmpty
                ? block
                : block + "\n\n" + existingContent
            keptMessages[firstUserIndex] = message
        } else {
            keptMessages.insert(.user(block), at: 0)
        }

        messages = plan.systemMessages + keptMessages
    }

    private func resultMessage(
        for proposal: FileProposal,
        decision: ProposalDecision,
        application: ProposalApplication
    ) -> String {
        let note = decision.note?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard application.didWrite else {
            var message = "Rejected by user for \(proposal.path)."
            if let note, !note.isEmpty {
                message += " Note: \(note). Address this note before proposing again."
            }
            return message
        }

        switch proposal.kind {
        case .delete:
            return "Deleted \(proposal.path)."
        case .move:
            return "Moved \(proposal.path) to \(proposal.destinationPath ?? "the new path")."
        case .create, .update:
            break
        }

        if proposal.kind == .create {
            return "Created \(proposal.path)."
        }

        if application.acceptedHunkCount == application.totalHunkCount {
            return "Applied change to \(proposal.path) (+\(proposal.addedLines)/-\(proposal.removedLines))."
        }

        let rejectedHunkIDs = Set(proposal.diff.hunks.map(\.id))
            .subtracting(application.acceptedHunkIDs)
        let rejectedHeaders = proposal.diff.hunks
            .filter { rejectedHunkIDs.contains($0.id) }
            .map(\.header)
            .joined(separator: ", ")

        var message = "Partially applied change to \(proposal.path): "
            + "\(application.acceptedHunkCount) of \(application.totalHunkCount) hunks accepted. "
            + "Rejected hunks: \(rejectedHeaders)."

        if let note, !note.isEmpty {
            message += " Note: \(note). Address the note and re-propose the remaining hunks."
        } else {
            message += " Re-read the file and re-propose the remaining hunks if needed."
        }
        return message
    }

    private func clip(_ text: String) -> String {
        guard text.utf8.count > config.maxToolOutputBytes else {
            return text
        }
        let prefix = text.utf8.prefix(config.maxToolOutputBytes)
        return String(decoding: prefix, as: UTF8.self) + "\n[truncated]"
    }
}

private struct StreamResult {
    var content = ""
    var toolCalls: [ToolCall] = []
    var usage: ModelUsage?
}

private struct ToolExecution: Sendable {
    let call: ToolCall
    var output: ToolOutput?
    var content: String?

    init(call: ToolCall, output: ToolOutput) {
        self.call = call
        self.output = output
        self.content = output.content
    }

    init(call: ToolCall, content: String) {
        self.call = call
        self.output = nil
        self.content = content
    }
}
