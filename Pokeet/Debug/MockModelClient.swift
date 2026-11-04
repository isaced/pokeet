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
            if lastTool.contains("JPEG") {
                return ChatResponse(
                    message: .assistant("The layout reads cleanly: one diff card per file, hunks aligned."),
                    finishReason: "stop"
                )
            }
            if lastTool.contains("[~]") {
                return ChatResponse(
                    message: .assistant("Working through the list — the guard is in progress."),
                    finishReason: "stop"
                )
            }
            if lastTool.contains("JavaScript · exit 0"),
               request.messages.contains(where: { $0.content?.lowercased().contains("net check") == true }) {
                return ChatResponse(
                    message: .assistant(
                        "Both runtimes reached GitHub: Python with urllib, JavaScript with fetch. "
                            + "No socket, no proxy."
                    ),
                    finishReason: "stop"
                )
            }
            if lastTool.contains("JavaScript · exit 0") {
                if request.messages.contains(where: { $0.content?.lowercased().contains("fibonacci") == true }) {
                    return ChatResponse(
                        message: .assistant(
                            "Both runtimes agree: the first ten Fibonacci numbers match, computed "
                                + "independently in Python and JavaScript. Neither needed a server."
                        ),
                        finishReason: "stop"
                    )
                }
                return ChatResponse(
                    message: .assistant("All three checks passed — the parser returns the expected values."),
                    finishReason: "stop"
                )
            }
            if lastTool.contains("Python · exit 0"),
               request.messages.contains(where: { $0.content?.lowercased().contains("fibonacci") == true }) {
                let arguments = #"{"script":"const fib = n => {\n  let a = 0, b = 1;\n  for (let i = 0; i < n; i++) {\n    const next = a + b;\n    a = b;\n    b = next;\n  }\n  return a;\n};\nconst series = Array.from({ length: 10 }, (_, i) => fib(i));\nassert.deepEqual(series, [0, 1, 1, 2, 3, 5, 8, 13, 21, 34]);\nconsole.log(series.join(' '));"}"#
                return ChatResponse(
                    message: .assistant(
                        nil,
                        toolCalls: [
                            ToolCall(
                                id: "mock-demo-js-\(UUID().uuidString)",
                                name: "run_script",
                                arguments: arguments
                            )
                        ]
                    ),
                    finishReason: "tool_calls"
                )
            }
            if lastTool.contains("Python · exit 0"),
               request.messages.contains(where: { $0.content?.lowercased().contains("net check") == true }),
               !request.messages.contains(where: {
                   $0.role == .tool && ($0.content?.contains("JavaScript · exit 0") ?? false)
               }) {
                let arguments = #"{"script":"const res = await fetch('https://api.github.com/repos/isaced/pokeet');\nconst data = await res.json();\nconsole.log(res.status, data.name, data.language);"}"#
                return ChatResponse(
                    message: .assistant(
                        nil,
                        toolCalls: [
                            ToolCall(
                                id: "mock-net-js-\(UUID().uuidString)",
                                name: "run_script",
                                arguments: arguments
                            )
                        ]
                    ),
                    finishReason: "tool_calls"
                )
            }
            if lastTool.contains("JavaScript · exit 0"),
               request.messages.contains(where: { $0.content?.lowercased().contains("net check") == true }) {
                return ChatResponse(
                    message: .assistant(
                        "Both runtimes reached GitHub: Python with urllib, JavaScript with fetch. "
                            + "No socket, no proxy."
                    ),
                    finishReason: "stop"
                )
            }
            if lastTool.contains("Python · exit 0") {
                return ChatResponse(
                    message: .assistant(
                        "Python agrees: the first ten Fibonacci numbers are correct, and `json` "
                            + "is available. The same script would run unchanged on the project's "
                            + "own interpreter."
                    ),
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
           text.contains("script test") {
            let arguments = #"{"script":"const cases = [['3+4', 7], ['2*21', 42], ['10/4', 2.5]];\nfor (const [expression, expected] of cases) {\n  const value = Function('return ' + expression)();\n  assert.equal(value, expected, expression);\n  console.log(expression, '=', value);\n}\nconsole.log('all checks passed');"}"#
            return ChatResponse(
                message: .assistant(
                    nil,
                    toolCalls: [
                        ToolCall(
                            id: "mock-script-\(UUID().uuidString)",
                            name: "run_script",
                            arguments: arguments
                        )
                    ]
                ),
                finishReason: "tool_calls"
            )
        }

        if lastMessage?.role == .user,
           let text = lastMessage?.content?.lowercased(),
           text.contains("net check") {
            let arguments = #"{"runtime":"python","script":"from urllib.request import urlopen\nimport json\n\nwith urlopen('https://api.github.com/repos/isaced/pokeet', timeout=15) as response:\n    print('status', response.status)\n    payload = json.load(response)\n\nprint('stars', payload['stargazers_count'])\nprint('language', payload['language'])"}"#
            return ChatResponse(
                message: .assistant(
                    nil,
                    toolCalls: [
                        ToolCall(
                            id: "mock-net-\(UUID().uuidString)",
                            name: "run_script",
                            arguments: arguments
                        )
                    ]
                ),
                finishReason: "tool_calls"
            )
        }

        if lastMessage?.role == .user,
           let text = lastMessage?.content?.lowercased(),
           text.contains("fibonacci") {
            let arguments = #"{"runtime":"python","script":"import json\n\ndef fib(n):\n    a, b = 0, 1\n    for _ in range(n):\n        a, b = b, a + b\n    return a\n\nseries = [fib(i) for i in range(10)]\nassert series == [0, 1, 1, 2, 3, 5, 8, 13, 21, 34]\nprint(series)\nprint(json.dumps({\"checks\": \"passed\"}))"}"#
            return ChatResponse(
                message: .assistant(
                    nil,
                    toolCalls: [
                        ToolCall(
                            id: "mock-demo-py-\(UUID().uuidString)",
                            name: "run_script",
                            arguments: arguments
                        )
                    ]
                ),
                finishReason: "tool_calls"
            )
        }

        if lastMessage?.role == .user,
           let text = lastMessage?.content?.lowercased(),
           text.contains("python test") {
            let arguments = #"{"runtime":"python","script":"import json\n\ndef fib(n):\n    a, b = 0, 1\n    for _ in range(n):\n        a, b = b, a + b\n    return a\n\nseries = [fib(i) for i in range(10)]\nassert series == [0, 1, 1, 2, 3, 5, 8, 13, 21, 34]\nprint(series)\nprint(json.dumps({\"checks\": \"passed\"}))"}"#
            return ChatResponse(
                message: .assistant(
                    nil,
                    toolCalls: [
                        ToolCall(
                            id: "mock-python-\(UUID().uuidString)",
                            name: "run_script",
                            arguments: arguments
                        )
                    ]
                ),
                finishReason: "tool_calls"
            )
        }

        if lastMessage?.role == .user,
           let text = lastMessage?.content?.lowercased(),
           text.contains("image test") {
            return ChatResponse(
                message: .assistant(
                    nil,
                    toolCalls: [
                        ToolCall(
                            id: "mock-image-\(UUID().uuidString)",
                            name: "read_image",
                            arguments: #"{"path":"shot.png"}"#
                        )
                    ]
                ),
                finishReason: "tool_calls"
            )
        }

        if lastMessage?.role == .user,
           let text = lastMessage?.content?.lowercased(),
           text.contains("todo test") {
            let arguments = #"{"items":[{"content":"Read the parser and its call sites","status":"done"},{"content":"Add the empty-username guard","status":"in_progress"},{"content":"Update the form tests"},{"content":"Run the checks"}]}"#
            return ChatResponse(
                message: .assistant(
                    nil,
                    toolCalls: [
                        ToolCall(
                            id: "mock-todos-\(UUID().uuidString)",
                            name: "todo_write",
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
