import Foundation

public struct ToolCall: Sendable, Equatable {
    public let id: String
    public let name: String
    public let arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct ChatMessage: Sendable, Equatable {
    public enum Role: String, Sendable, Equatable {
        case system
        case user
        case assistant
        case tool
    }

    public var role: Role
    public var content: String?
    public var toolCalls: [ToolCall]?
    public var toolCallID: String?

    public init(
        role: Role,
        content: String? = nil,
        toolCalls: [ToolCall]? = nil,
        toolCallID: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }

    public static func system(_ content: String) -> ChatMessage {
        ChatMessage(role: .system, content: content)
    }

    public static func user(_ content: String) -> ChatMessage {
        ChatMessage(role: .user, content: content)
    }

    public static func assistant(
        _ content: String?,
        toolCalls: [ToolCall]? = nil
    ) -> ChatMessage {
        ChatMessage(role: .assistant, content: content, toolCalls: toolCalls)
    }

    public static func tool(_ content: String, callID: String) -> ChatMessage {
        ChatMessage(role: .tool, content: content, toolCallID: callID)
    }
}

public struct ToolSchema: Sendable, Equatable {
    public let name: String
    public let description: String
    public let parameters: JSONValue

    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct ChatRequest: Sendable {
    public var messages: [ChatMessage]
    public var tools: [ToolSchema]

    public init(messages: [ChatMessage], tools: [ToolSchema]) {
        self.messages = messages
        self.tools = tools
    }
}

public struct ChatResponse: Sendable {
    public var message: ChatMessage
    public var finishReason: String?

    public init(message: ChatMessage, finishReason: String? = nil) {
        self.message = message
        self.finishReason = finishReason
    }
}
