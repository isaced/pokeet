import Foundation
import PokeetCore

#if DEBUG
struct MockModelClient: ModelClient {
    func complete(_ request: ChatRequest) async throws -> ChatResponse {
        try await Task.sleep(for: .milliseconds(350))

        let lastMessage = request.messages.last
        if lastMessage?.role == .tool {
            let lastTool = lastMessage?.content ?? ""
            if lastTool.contains("Rejected") {
                return ChatResponse(
                    message: .assistant("Okay — I left the file unchanged."),
                    finishReason: "stop"
                )
            }
            let isPlanExecution = request.messages.contains {
                $0.role == .user && ($0.content?.contains("Execute this plan") == true)
            }
            return ChatResponse(
                message: .assistant(
                    isPlanExecution
                        ? "The demo change is in place. [DONE:1]"
                        : "The demo change is in place. Review it, then commit and push when ready."
                ),
                finishReason: "stop"
            )
        }

        if lastMessage?.role == .user,
           let text = lastMessage?.content?.lowercased(),
           text.contains("markdown test") {
            return ChatResponse(
                message: .assistant("""
                # Streaming markdown

                This paragraph is **bold** and has `inline code`.

                - First item
                - Second item with a [link](https://example.com)

                ```swift
                struct Demo {
                    let value: Int
                }
                ```

                > A quote for good measure.

                Final paragraph.
                """),
                finishReason: "stop"
            )
        }

        if lastMessage?.role == .user,
           let text = lastMessage?.content?.lowercased(),
           text.contains("edit test") {
            let arguments = #"{"path":"Pokeet/App/RootView.swift","edits":[{"old_text":"    private var usesSplitLayout: Bool {","new_text":"    /// Chooses the split layout on wide or short screens.\n    private var usesSplitLayout: Bool {"}]}"#
            return ChatResponse(
                message: .assistant(
                    nil,
                    toolCalls: [
                        ToolCall(
                            id: "mock-edit-\(UUID().uuidString)",
                            name: "edit_file",
                            arguments: arguments
                        )
                    ]
                ),
                finishReason: "tool_calls"
            )
        }

        if lastMessage?.role == .user,
           let text = lastMessage?.content?.lowercased(),
           text.contains("git test") {
            return ChatResponse(
                message: .assistant(
                    nil,
                    toolCalls: [
                        ToolCall(
                            id: "mock-git-status-\(UUID().uuidString)",
                            name: "git_status",
                            arguments: "{}"
                        ),
                        ToolCall(
                            id: "mock-git-diff-\(UUID().uuidString)",
                            name: "git_diff",
                            arguments: #"{"staged":true}"#
                        ),
                        ToolCall(
                            id: "mock-git-log-\(UUID().uuidString)",
                            name: "git_log",
                            arguments: #"{"limit":5}"#
                        )
                    ]
                ),
                finishReason: "tool_calls"
            )
        }

        if lastMessage?.role == .user,
           let text = lastMessage?.content?.lowercased(),
           text.contains("read test") {
            return ChatResponse(
                message: .assistant(
                    nil,
                    toolCalls: [
                        ToolCall(
                            id: "mock-read-\(UUID().uuidString)",
                            name: "read_file",
                            arguments: #"{"path":"README.md"}"#
                        )
                    ]
                ),
                finishReason: "tool_calls"
            )
        }

        if lastMessage?.role == .user,
           let text = lastMessage?.content?.lowercased(),
           text.contains("post test") {
            let arguments = #"{"url":"https://httpbin.org/post","method":"POST","headers":{"Content-Type":"application/json"},"body":"{\"hello\":\"world\"}"}"#
            return ChatResponse(
                message: .assistant(
                    nil,
                    toolCalls: [
                        ToolCall(
                            id: "mock-http-\(UUID().uuidString)",
                            name: "http_request",
                            arguments: arguments
                        )
                    ]
                ),
                finishReason: "tool_calls"
            )
        }

        if request.tools.contains(where: { $0.name == "submit_plan" }) {
            let arguments = #"{"title":"Demo plan","summary":"Create the demo file, then review it.","steps":[{"title":"Create POKEET_DEMO.md","files":["POKEET_DEMO.md"]},{"title":"Review the demo content"}]}"#
            return ChatResponse(
                message: .assistant(
                    nil,
                    toolCalls: [
                        ToolCall(
                            id: "mock-plan-\(UUID().uuidString)",
                            name: "submit_plan",
                            arguments: arguments
                        )
                    ]
                ),
                finishReason: "tool_calls"
            )
        }

        struct Arguments: Encodable {
            let path: String
            let content: String
            let reason: String
        }

        let stamp = ISO8601DateFormatter().string(from: Date())
        let payload = Arguments(
            path: "POKEET_DEMO.md",
            content: "# Pokeet demo\n\nGenerated by the mock agent at \(stamp).\n",
            reason: "Demonstrate the diff review flow"
        )
        let arguments = (try? JSONEncoder().encode(payload))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        return ChatResponse(
            message: .assistant(
                "Here is a small demo change.",
                toolCalls: [
                    ToolCall(
                        id: "mock-\(UUID().uuidString)",
                        name: "write_file",
                        arguments: arguments
                    )
                ]
            ),
            finishReason: "tool_calls"
        )
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await complete(request)

                    let reasoning = "So I have this problem here. What is 1+1? Okay, that's pretty straightforward. I think I know the answer, but let's make sure I explain it clearly. One plus one equals two. Let me double check by counting: one apple plus another apple makes two apples. So the answer is two."
                    let reasoningCharacters = Array(reasoning)
                    let reasoningStep = max(1, reasoningCharacters.count / 10)
                    var reasoningIndex = 0
                    while reasoningIndex < reasoningCharacters.count {
                        let end = min(reasoningIndex + reasoningStep, reasoningCharacters.count)
                        continuation.yield(.reasoningDelta(
                            String(reasoningCharacters[reasoningIndex..<end])
                        ))
                        reasoningIndex = end
                        try? await Task.sleep(for: .milliseconds(50))
                    }

                    if let text = response.message.content,
                       response.message.toolCalls == nil,
                       !text.isEmpty {
                        let characters = Array(text)
                        let step = max(1, characters.count / 8)
                        let isMarkdownDemo = text.contains("Streaming markdown")
                        var index = 0
                        while index < characters.count {
                            let end = min(index + step, characters.count)
                            continuation.yield(.textDelta(String(characters[index..<end])))
                            index = end
                            try? await Task.sleep(
                                for: .milliseconds(isMarkdownDemo ? 600 : 40)
                            )
                        }
                    }
                    continuation.yield(.completed(response))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif

enum MockModelSupport {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-PokeetMockModel")
    }

    static func makeClient() -> (any ModelClient)? {
        #if DEBUG
        return isEnabled ? MockModelClient() : nil
        #else
        return nil
        #endif
    }
}
