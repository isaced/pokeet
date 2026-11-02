import Foundation

public actor AgentSession {
    private let client: any ModelClient
    private let registry: ToolRegistry
    private let workspace: any Workspace
    private let git: (any GitInspecting)?
    private let config: AgentConfiguration
    private let compactor: ContextCompactor
    private let summarizer: any ContextSummarizer
    private let instructions: ProjectInstructions
    private var messages: [ChatMessage]

    public init(
        client: any ModelClient,
        workspace: any Workspace,
        git: (any GitInspecting)? = nil,
        tools: ToolRegistry = .standard,
        systemPrompt: String = AgentPrompts.system,
        config: AgentConfiguration = AgentConfiguration(),
        summarizer: (any ContextSummarizer)? = nil
    ) {
        self.client = client
        self.registry = tools
        self.workspace = workspace
        self.git = git
        self.config = config
        self.compactor = ContextCompactor(
            maxCharacters: config.contextCharacterBudget,
            retainedTurns: config.retainedTurns,
            toolOutputCharacters: config.compactedToolOutputCharacters
        )
        self.summarizer = summarizer ?? ModelContextSummarizer(client: client)
        self.instructions = ProjectInstructions.load(from: workspace)
        self.messages = [.system(instructions.compose(with: systemPrompt))]
    }

    public var history: [ChatMessage] {
        messages
    }

    public var loadedInstructions: ProjectInstructions {
        instructions
    }

    public func reset(systemPrompt: String = AgentPrompts.system) {
        messages = [.system(instructions.compose(with: systemPrompt))]
    }

    public func restore(_ history: [ChatMessage], systemPrompt: String = AgentPrompts.system) {
        messages = [.system(instructions.compose(with: systemPrompt))]
            + history.filter { $0.role != .system }
    }

    public func send(
        _ text: String,
        images: [ChatImage] = [],
        approval: @escaping ApprovalHandler,
        onEvent: @escaping EventHandler
    ) async throws {
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
                let message = "Stopped after \(config.maxIterations) iterations without finishing."
                await onEvent(.failed(message))
                throw AgentError.iterationLimit
            }
            iteration += 1

            var request = ChatRequest(
                messages: try await messagesForRequest(onEvent: onEvent),
                tools: registry.schemas
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
                                tools: registry.schemas
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

            var executions: [ToolExecution] = []
            for call in toolCalls {
                if Task.isCancelled {
                    throw AgentError.cancelled
                }

                await onEvent(.toolStarted(call.name))

                guard let tool = registry.tool(named: call.name) else {
                    let message = "Unknown tool '\(call.name)'."
                    executions.append(ToolExecution(call: call, content: "Error: \(message)"))
                    await onEvent(.toolFinished(name: call.name, summary: message))
                    continue
                }

                do {
                    let output = try await tool.execute(
                        arguments: Data(call.arguments.utf8),
                        context: ToolContext(workspace: workspace, git: git)
                    )
                    executions.append(ToolExecution(call: call, output: output))
                    await onEvent(.toolFinished(
                        name: call.name,
                        summary: String(output.content.prefix(200))
                    ))
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                    executions.append(ToolExecution(call: call, content: "Error: \(message)"))
                    await onEvent(.toolFinished(name: call.name, summary: message))
                }
            }

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
                await onEvent(.proposalsPending(pending))

                let decisions = await approval(pending)
                if Task.isCancelled {
                    throw AgentError.cancelled
                }

                let decisionsByID = Dictionary(
                    uniqueKeysWithValues: decisions.map { ($0.proposalID, $0) }
                )

                for proposal in pending {
                    let decision = decisionsByID[proposal.id]
                        ?? .reject(proposalID: proposal.id)

                    do {
                        let application = try ProposalApplier.apply(
                            proposal,
                            decision: decision,
                            in: workspace
                        )
                        proposalResults[proposal.id] = resultMessage(
                            for: proposal,
                            decision: decision,
                            application: application
                        )
                    } catch {
                        let message = (error as? LocalizedError)?.errorDescription
                            ?? error.localizedDescription
                        proposalResults[proposal.id] = "Error applying change to \(proposal.path): \(message)"
                    }
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
        }
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

private struct ToolExecution {
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
