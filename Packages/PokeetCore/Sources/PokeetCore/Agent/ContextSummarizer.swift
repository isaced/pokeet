import Foundation

public protocol ContextSummarizer: Sendable {
    func summarize(_ messages: [ChatMessage]) async throws -> String
}

public enum ContextSummarizerError: Error, Sendable, Equatable, LocalizedError {
    case emptySummary

    public var errorDescription: String? {
        switch self {
        case .emptySummary:
            "The model returned an empty context summary."
        }
    }
}

public struct ModelContextSummarizer: ContextSummarizer {
    private let client: any ModelClient

    private static let maxToolResultCharacters = 2_000
    private static let maxToolArgumentsCharacters = 1_000
    private static let maxContentCharacters = 8_000

    public init(client: any ModelClient) {
        self.client = client
    }

    public func summarize(_ messages: [ChatMessage]) async throws -> String {
        let conversation = Self.serialize(messages)
        let request = ChatRequest(
            messages: [
                .system(Self.systemPrompt),
                .user(conversation.isEmpty ? "(No messages)" : conversation)
            ],
            tools: []
        )

        let response = try await client.complete(request)
        guard let summary = response.message.content?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !summary.isEmpty
        else {
            throw ContextSummarizerError.emptySummary
        }
        return summary
    }

    static let systemPrompt = """
    The messages above are a conversation to summarize. Create a structured context checkpoint summary that another LLM will use to continue the work.

    Use exactly these sections:
    ## Goal
    ## Constraints & Preferences
    ## Progress
    ### Done
    ### In Progress
    ### Blocked
    ## Key Decisions
    ## Next Steps
    ## Critical Context
    ## Files

    Include read and modified file paths in the Files section when visible. Preserve important details from any previous context summary. Do not call tools. Output only the summary.
    """

    static func serialize(_ messages: [ChatMessage]) -> String {
        messages.compactMap { message -> String? in
            switch message.role {
            case .user:
                return "[User]: \(truncated(message.content ?? "", limit: maxContentCharacters))"
            case .assistant:
                var parts: [String] = []

                if let content = message.content, !content.isEmpty {
                    parts.append("[Assistant]: \(truncated(content, limit: maxContentCharacters))")
                }
                if let calls = message.toolCalls, !calls.isEmpty {
                    let callsText = calls.map { call in
                        let arguments = truncated(
                            call.arguments,
                            limit: maxToolArgumentsCharacters
                        )
                        return "\(call.name)(\(arguments))"
                    }.joined(separator: "; ")
                    parts.append("[Assistant tool calls]: \(callsText)")
                }

                return parts.isEmpty ? nil : parts.joined(separator: "\n")
            case .tool:
                return "[Tool result]: \(truncated(message.content ?? "", limit: maxToolResultCharacters))"
            case .system:
                return nil
            }
        }
        .joined(separator: "\n\n")
    }

    private static func truncated(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n[truncated]"
    }
}
