import Foundation

public struct ChatImage: Sendable, Equatable, Hashable, Codable {
    public let mimeType: String
    public let data: Data

    public init(mimeType: String, data: Data) {
        self.mimeType = mimeType
        self.data = data
    }

    public var base64: String {
        data.base64EncodedString()
    }

    public var dataURL: String {
        "data:\(mimeType);base64,\(base64)"
    }
}

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
    public var images: [ChatImage]?

    public init(
        role: Role,
        content: String? = nil,
        toolCalls: [ToolCall]? = nil,
        toolCallID: String? = nil,
        images: [ChatImage]? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.images = images
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
    public var sessionID: String?

    public init(
        messages: [ChatMessage],
        tools: [ToolSchema],
        sessionID: String? = nil
    ) {
        self.messages = messages
        self.tools = tools
        self.sessionID = sessionID
    }
}

public struct ChatResponse: Sendable {
    public var message: ChatMessage
    public var finishReason: String?
    public var usage: ModelUsage?

    public init(
        message: ChatMessage,
        finishReason: String? = nil,
        usage: ModelUsage? = nil
    ) {
        self.message = message
        self.finishReason = finishReason
        self.usage = usage
    }
}
