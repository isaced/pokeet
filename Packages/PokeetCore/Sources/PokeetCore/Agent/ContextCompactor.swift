import Foundation

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

    public func compact(_ messages: [ChatMessage]) -> [ChatMessage] {
        let systemMessages = messages.filter { $0.role == .system }
        let conversation = messages.filter { $0.role != .system }

        guard !conversation.isEmpty else { return messages }
        guard characterCount(of: messages) > maxCharacters else { return messages }

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

        let omittedTurns = max(0, turns.count - compactedTurns.count)
        var systemText = systemMessages
            .compactMap(\.content)
            .joined(separator: "\n\n")

        if omittedTurns > 0 {
            systemText += "\n\n[Context compacted to fit the model window. "
                + "\(omittedTurns) older turn(s) were omitted and large outputs may be truncated. "
                + "Re-read files if you need details.]"
        } else {
            systemText += "\n\n[Context compacted to fit the model window. "
                + "Large outputs were truncated. Re-read files if you need details.]"
        }

        return [.system(systemText)] + compactedTurns.flatMap { $0 }
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
