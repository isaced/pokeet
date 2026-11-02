import Foundation

public struct CompactionPlan: Sendable {
    public let systemMessages: [ChatMessage]
    public let messagesToSummarize: [ChatMessage]
    public let keptMessages: [ChatMessage]
    public let omittedTurnCount: Int

    public var hasMessagesToSummarize: Bool {
        !messagesToSummarize.isEmpty
    }

    public init(
        systemMessages: [ChatMessage],
        messagesToSummarize: [ChatMessage],
        keptMessages: [ChatMessage],
        omittedTurnCount: Int
    ) {
        self.systemMessages = systemMessages
        self.messagesToSummarize = messagesToSummarize
        self.keptMessages = keptMessages
        self.omittedTurnCount = omittedTurnCount
    }
}

public struct ContextCompactor: Sendable {
    public let maxCharacters: Int
    public let retainedTurns: Int
    public let toolOutputCharacters: Int

    public init(
        maxCharacters: Int = 80_000,
        retainedTurns: Int = 10,
        toolOutputCharacters: Int = 8_000
    ) {
        self.maxCharacters = max(1, maxCharacters)
        self.retainedTurns = max(1, retainedTurns)
        self.toolOutputCharacters = max(1, toolOutputCharacters)
    }

    /// Returns a plan when the history exceeds the character budget, otherwise nil.
    /// Summarizable messages are the older turns; kept messages are recent turns
    /// with oversized tool output already truncated. Pass `force` to compact even
    /// when the local estimate fits, for example after a provider overflow error.
    public func plan(_ messages: [ChatMessage], force: Bool = false) -> CompactionPlan? {
        let systemMessages = messages.filter { $0.role == .system }
        let conversation = messages.filter { $0.role != .system }

        guard !conversation.isEmpty else { return nil }
        guard force || characterCount(of: messages) > maxCharacters else { return nil }

        let turns = makeTurns(from: conversation)
        var keptTurns = Array(turns.suffix(retainedTurns))

        while keptTurns.count > 1,
              characterCount(system: systemMessages, turns: keptTurns) > maxCharacters {
            keptTurns.removeFirst()
        }

        var compactedTurns = keptTurns.map { turn in
            turn.map(compact(message:))
        }

        while compactedTurns.count > 1,
              characterCount(system: systemMessages, turns: compactedTurns) > maxCharacters {
            compactedTurns.removeFirst()
        }

        let omittedTurnCount = max(0, turns.count - compactedTurns.count)
        let messagesToSummarize = turns
            .prefix(omittedTurnCount)
            .flatMap { $0 }

        return CompactionPlan(
            systemMessages: systemMessages,
            messagesToSummarize: messagesToSummarize,
            keptMessages: compactedTurns.flatMap { $0 },
            omittedTurnCount: omittedTurnCount
        )
    }

    /// Deterministic fallback: drop older turns and truncate large tool output
    /// without asking the model for a summary.
    public func compact(_ messages: [ChatMessage], force: Bool = false) -> [ChatMessage] {
        guard let plan = plan(messages, force: force) else { return messages }

        var keptMessages = plan.keptMessages
        let note: String

        if plan.omittedTurnCount > 0 {
            note = "[Context compacted to fit the model window. "
                + "\(plan.omittedTurnCount) older turn(s) were omitted and large outputs may be truncated. "
                + "Re-read files if you need details.]"
        } else {
            note = "[Context compacted to fit the model window. "
                + "Large outputs were truncated. Re-read files if you need details.]"
        }

        if let firstUserIndex = keptMessages.firstIndex(where: { $0.role == .user }) {
            var message = keptMessages[firstUserIndex]
            let existingContent = message.content ?? ""
            message.content = existingContent.isEmpty
                ? note
                : note + "\n\n" + existingContent
            keptMessages[firstUserIndex] = message
        } else {
            keptMessages.insert(.user(note), at: 0)
        }

        // Keep the system prompt untouched so the provider's prefix cache stays warm.
        return plan.systemMessages + keptMessages
    }

    private func makeTurns(from messages: [ChatMessage]) -> [[ChatMessage]] {
        var turns: [[ChatMessage]] = []
        var current: [ChatMessage] = []

        for message in messages {
            if message.role == .user, !current.isEmpty {
                turns.append(current)
                current = []
            }
            current.append(message)
        }

        if !current.isEmpty {
            turns.append(current)
        }

        return turns
    }

    private func compact(message: ChatMessage) -> ChatMessage {
        var message = message

        switch message.role {
        case .system:
            return message
        case .tool:
            message.content = truncated(message.content, limit: toolOutputCharacters)
        case .assistant:
            message.content = truncated(message.content, limit: toolOutputCharacters)
            message.toolCalls = message.toolCalls?.map { call in
                guard call.arguments.count > toolOutputCharacters else { return call }
                return ToolCall(
                    id: call.id,
                    name: call.name,
                    arguments: #"{"_compacted":true}"#
                )
            }
        case .user:
            message.content = truncated(message.content, limit: toolOutputCharacters * 2)
        }

        return message
    }

    private func truncated(_ text: String?, limit: Int) -> String? {
        guard let text, text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n[truncated]"
    }

    private func characterCount(of messages: [ChatMessage]) -> Int {
        messages.reduce(0) { total, message in
            total + messageCharacterCount(message)
        }
    }

    private func characterCount(system: [ChatMessage], turns: [[ChatMessage]]) -> Int {
        characterCount(of: system) + turns.reduce(0) { total, turn in
            total + turn.reduce(0) { $0 + messageCharacterCount($1) }
        }
    }

    private func messageCharacterCount(_ message: ChatMessage) -> Int {
        let contentCount = message.content?.count ?? 0
        let toolCallCount = message.toolCalls?.reduce(0) { total, call in
            total + call.name.count + call.arguments.count
        } ?? 0
        return contentCount + toolCallCount
    }
}
