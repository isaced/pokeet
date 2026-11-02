import Foundation

public actor AgentSession {
    private let client: any ModelClient
    private let registry: ToolRegistry
    private let workspace: any Workspace
    private let config: AgentConfiguration
    private var messages: [ChatMessage]

    public init(
        client: any ModelClient,
        workspace: any Workspace,
        tools: ToolRegistry = .standard,
        systemPrompt: String = AgentPrompts.system,
        config: AgentConfiguration = AgentConfiguration()
    ) {
        self.client = client
        self.registry = tools
        self.workspace = workspace
        self.config = config
        self.messages = [.system(systemPrompt)]
    }

    public var history: [ChatMessage] {
        messages
    }

    public func reset(systemPrompt: String = AgentPrompts.system) {
        messages = [.system(systemPrompt)]
    }

    public func send(
        _ text: String,
        approval: @escaping ApprovalHandler,
        onEvent: @escaping EventHandler
    ) async throws {
        messages.append(.user(text))

        var iteration = 0
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

            let request = ChatRequest(messages: messages, tools: registry.schemas)
            var assistantContent = ""
            var assistantToolCalls: [ToolCall] = []

            do {
                for try await event in client.stream(request) {
                    if Task.isCancelled {
                        throw AgentError.cancelled
                    }

                    switch event {
                    case .reasoningDelta(let delta):
                        if !delta.isEmpty {
                            await onEvent(.assistantReasoningDelta(delta))
                        }
                    case .textDelta(let delta):
                        assistantContent += delta
                        if !delta.isEmpty {
                            await onEvent(.assistantTextDelta(delta))
                        }
                    case .completed(let response):
                        if let content = response.message.content {
                            assistantContent = content
                        }
                        assistantToolCalls = response.message.toolCalls ?? []
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

            let assistantMessage = ChatMessage.assistant(
                assistantContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil
                    : assistantContent,
                toolCalls: assistantToolCalls.isEmpty ? nil : assistantToolCalls
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
                        context: ToolContext(workspace: workspace)
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

        if application.totalHunkCount == 0 {
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
