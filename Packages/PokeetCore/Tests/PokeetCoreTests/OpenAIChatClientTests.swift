import Foundation
import Testing
@testable import PokeetCore

private func stubClient(baseURL: String = "https://stub.local/v1") -> OpenAIChatClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    return OpenAIChatClient(
        baseURL: baseURL,
        model: "test-model",
        apiKey: "test-key",
        session: session
    )
}

private func stubJSONResponse(_ body: String, status: Int = 200) -> (HTTPURLResponse, Data) {
    let response = HTTPURLResponse(
        url: URL(string: "https://stub.local/v1/chat/completions")!,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
    )!
    return (response, Data(body.utf8))
}

@Suite(.serialized)
struct OpenAIChatClientTests {
    @Test func sendsChatCompletionRequestAndDecodesText() async throws {
        let capturedBody = LockedBox<Data?>(nil)
        let capturedRequest = LockedBox<URLRequest?>(nil)

        StubURLProtocol.setHandler { request in
            capturedRequest.set(request)
            capturedBody.set(requestBody(from: request))
            return stubJSONResponse(#"""
            {"choices":[{"message":{"role":"assistant","content":"Hello"},"finish_reason":"stop"}]}
            """#)
        }
        defer { StubURLProtocol.setHandler(nil) }

        let client = stubClient()
        let response = try await client.complete(ChatRequest(
            messages: [.user("hi")],
            tools: [
                ToolSchema(
                    name: "read_file",
                    description: "Read a file",
                    parameters: .object(["type": .string("object")])
                )
            ]
        ))

        #expect(response.message.content == "Hello")
        #expect(response.finishReason == "stop")

        let request = try #require(capturedRequest.get())
        #expect(request.url?.path.hasSuffix("/chat/completions") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")

        let data = try #require(capturedBody.get())
        let json = try JSONSerialization.jsonObject(with: data)
        let object = try #require(json as? [String: Any])
        #expect(object["model"] as? String == "test-model")
        #expect(object["tool_choice"] as? String == "auto")
        #expect((object["tools"] as? [[String: Any]])?.count == 1)
        let messages = try #require(object["messages"] as? [[String: Any]])
        #expect(messages.first?["role"] as? String == "user")
        #expect(messages.first?["content"] as? String == "hi")
    }

    @Test func decodesToolCalls() async throws {
        StubURLProtocol.setHandler { _ in
            stubJSONResponse(#"""
            {"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[
              {"id":"call_1","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"README.md\"}"}}
            ]},"finish_reason":"tool_calls"}]}
            """#)
        }
        defer { StubURLProtocol.setHandler(nil) }

        let client = stubClient()
        let response = try await client.complete(ChatRequest(messages: [.user("read")], tools: []))

        #expect(response.message.toolCalls?.count == 1)
        #expect(response.message.toolCalls?.first?.id == "call_1")
        #expect(response.message.toolCalls?.first?.name == "read_file")
        #expect(response.message.toolCalls?.first?.arguments == #"{"path":"README.md"}"#)
    }

    @Test func mapsHTTPErrors() async throws {
        StubURLProtocol.setHandler { _ in
            stubJSONResponse(#"{"error":{"message":"Invalid API key"}}"#, status: 401)
        }
        defer { StubURLProtocol.setHandler(nil) }

        let client = stubClient()
        do {
            _ = try await client.complete(ChatRequest(messages: [.user("hi")], tools: []))
            Issue.record("Expected an HTTP error")
        } catch let error as ModelError {
            guard case .http(let status, let message) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(status == 401)
            #expect(message == "Invalid API key")
        }
    }

    @Test func normalizesLoopbackIPToLocalhost() async throws {
        let captured = LockedBox<URLRequest?>(nil)
        StubURLProtocol.setHandler { request in
            captured.set(request)
            return stubJSONResponse(#"""
            {"choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}
            """#)
        }
        defer { StubURLProtocol.setHandler(nil) }

        let client = stubClient(baseURL: "http://127.0.0.1:3425/v1")
        _ = try await client.complete(ChatRequest(messages: [.user("hi")], tools: []))

        #expect(captured.get()?.url?.host == "localhost")
        #expect(captured.get()?.url?.port == 3425)
    }

    @Test func encodesIdenticalRequestsDeterministicallyAndSortsTools() async throws {
        let bodies = LockedBox<[Data]>([])

        StubURLProtocol.setHandler { request in
            if let body = requestBody(from: request) {
                bodies.set(bodies.get() + [body])
            }
            return stubJSONResponse(#"""
            {"choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}
            """#)
        }
        defer { StubURLProtocol.setHandler(nil) }

        let client = stubClient()
        let beta = ToolSchema(
            name: "beta_tool",
            description: "Beta",
            parameters: .object([
                "beta": .string("b"),
                "alpha": .string("a")
            ])
        )
        let alpha = ToolSchema(
            name: "alpha_tool",
            description: "Alpha",
            parameters: .object([
                "z": .number(1),
                "a": .bool(true)
            ])
        )

        let first = ChatRequest(
            messages: [.system("stable"), .user("hi")],
            tools: [beta, alpha]
        )
        let second = ChatRequest(
            messages: [.system("stable"), .user("hi")],
            tools: [alpha, beta]
        )

        _ = try await client.complete(first)
        _ = try await client.complete(second)

        let captured = bodies.get()
        #expect(captured.count == 2)
        #expect(captured[0] == captured[1])

        let json = try JSONSerialization.jsonObject(with: captured[0])
        let object = try #require(json as? [String: Any])
        let tools = try #require(object["tools"] as? [[String: Any]])
        let names = tools.compactMap {
            ($0["function"] as? [String: Any])?["name"] as? String
        }
        #expect(names == ["alpha_tool", "beta_tool"])
    }

    @Test func requiresConfiguration() async throws {
        let client = OpenAIChatClient(baseURL: "", model: "", apiKey: "")
        do {
            _ = try await client.complete(ChatRequest(messages: [.user("hi")], tools: []))
            Issue.record("Expected notConfigured")
        } catch let error as ModelError {
            #expect(error == .notConfigured)
        }
    }

    @Test func streamsTextAndAssemblesToolCalls() async throws {
        let capturedBody = LockedBox<Data?>(nil)
        let usageLine = #"data: {"choices":[],"usage":{"prompt_tokens":120,"completion_tokens":7,"prompt_tokens_details":{"cached_tokens":96},"completion_tokens_details":{"reasoning_tokens":2}}}"#
            + "\n\n"
        let body = try sseBody([
            sseChunk(reasoningContent: "Think"),
            sseChunk(reasoningContent: "ing"),
            sseChunk(content: "Hel"),
            sseChunk(content: "lo"),
            sseChunk(toolCalls: [
                sseToolCall(id: "call_1", name: "read_file", arguments: "{\"path\":")
            ]),
            sseChunk(
                toolCalls: [sseToolCall(arguments: "\"README.md\"}")],
                finishReason: "tool_calls"
            )
        ])
        .replacingOccurrences(of: "data: [DONE]", with: usageLine + "data: [DONE]")

        StubURLProtocol.setHandler { request in
            capturedBody.set(requestBody(from: request))
            return sseResponse(body)
        }
        defer { StubURLProtocol.setHandler(nil) }

        let client = stubClient()
        var reasoningDeltas: [String] = []
        var deltas: [String] = []
        var completed: ChatResponse?

        for try await event in client.stream(
            ChatRequest(messages: [.user("hi")], tools: [])
        ) {
            switch event {
            case .reasoningDelta(let delta):
                reasoningDeltas.append(delta)
            case .textDelta(let delta):
                deltas.append(delta)
            case .completed(let response):
                completed = response
            }
        }

        #expect(reasoningDeltas == ["Think", "ing"])
        #expect(deltas == ["Hel", "lo"])
        #expect(completed?.message.content == "Hello")
        #expect(completed?.message.toolCalls?.count == 1)
        #expect(completed?.message.toolCalls?.first?.id == "call_1")
        #expect(completed?.message.toolCalls?.first?.name == "read_file")
        #expect(completed?.message.toolCalls?.first?.arguments == "{\"path\":\"README.md\"}")
        #expect(completed?.usage == ModelUsage(
            inputTokens: 120,
            outputTokens: 7,
            cachedInputTokens: 96,
            reasoningTokens: 2
        ))

        let data = try #require(capturedBody.get())
        let json = try JSONSerialization.jsonObject(with: data)
        let object = try #require(json as? [String: Any])
        #expect(object["stream"] as? Bool == true)
        let streamOptions = try #require(object["stream_options"] as? [String: Any])
        #expect(streamOptions["include_usage"] as? Bool == true)
    }

    @Test func decodesUsageFromNonStreamingResponse() async throws {
        StubURLProtocol.setHandler { _ in
            stubJSONResponse(#"""
            {"choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":120,"completion_tokens":7,"prompt_tokens_details":{"cached_tokens":96},"completion_tokens_details":{"reasoning_tokens":2}}}
            """#)
        }
        defer { StubURLProtocol.setHandler(nil) }

        let client = stubClient()
        let response = try await client.complete(
            ChatRequest(messages: [.user("hi")], tools: [])
        )

        #expect(response.usage == ModelUsage(
            inputTokens: 120,
            outputTokens: 7,
            cachedInputTokens: 96,
            reasoningTokens: 2
        ))
    }
}

private struct StubSSEChunk: Encodable {
    struct Choice: Encodable {
        let delta: Delta
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }

    struct Delta: Encodable {
        let content: String?
        let reasoningContent: String?
        let toolCalls: [ToolCall]?

        init(
            content: String? = nil,
            reasoningContent: String? = nil,
            toolCalls: [ToolCall]? = nil
        ) {
            self.content = content
            self.reasoningContent = reasoningContent
            self.toolCalls = toolCalls
        }

        enum CodingKeys: String, CodingKey {
            case content
            case reasoningContent = "reasoning_content"
            case toolCalls = "tool_calls"
        }
    }

    struct ToolCall: Encodable {
        struct Function: Encodable {
            let name: String?
            let arguments: String?
        }

        let index: Int
        let id: String?
        let type: String?
        let function: Function?
    }

    let choices: [Choice]
}

private func sseChunk(
    content: String? = nil,
    reasoningContent: String? = nil,
    toolCalls: [StubSSEChunk.ToolCall]? = nil,
    finishReason: String? = nil
) -> StubSSEChunk {
    StubSSEChunk(choices: [
        StubSSEChunk.Choice(
            delta: StubSSEChunk.Delta(
                content: content,
                reasoningContent: reasoningContent,
                toolCalls: toolCalls
            ),
            finishReason: finishReason
        )
    ])
}

private func sseToolCall(
    index: Int = 0,
    id: String? = nil,
    name: String? = nil,
    arguments: String? = nil
) -> StubSSEChunk.ToolCall {
    StubSSEChunk.ToolCall(
        index: index,
        id: id,
        type: id == nil ? nil : "function",
        function: StubSSEChunk.ToolCall.Function(name: name, arguments: arguments)
    )
}

private func sseBody(_ chunks: [StubSSEChunk]) throws -> String {
    var body = ""
    for chunk in chunks {
        let data = try JSONEncoder().encode(chunk)
        body += "data: " + String(decoding: data, as: UTF8.self) + "\n\n"
    }
    body += "data: [DONE]\n\n"
    return body
}

private func sseResponse(_ body: String) -> (HTTPURLResponse, Data) {
    let response = HTTPURLResponse(
        url: URL(string: "https://stub.local/v1/chat/completions")!,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "text/event-stream"]
    )!
    return (response, Data(body.utf8))
}
