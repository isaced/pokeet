import Foundation
import Testing
@testable import PokeetCore

@Suite(.serialized)
struct AnthropicMessagesClientTests {
    private let host = "anthropic-client.test"

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func client() -> AnthropicMessagesClient {
        AnthropicMessagesClient(
            baseURL: "https://anthropic-client.test/v1",
            model: "claude-test",
            apiKey: "test-key",
            session: makeSession()
        )
    }

    private func request() -> ChatRequest {
        ChatRequest(
            messages: [
                .system("System rules"),
                .user("Read a file."),
                .assistant(nil, toolCalls: [
                    ToolCall(id: "call_1", name: "read_file", arguments: #"{"path":"a.txt"}"#)
                ]),
                .tool("file contents", callID: "call_1")
            ],
            tools: [
                ToolSchema(
                    name: "read_file",
                    description: "Read a file.",
                    parameters: .object([
                        "type": .string("object"),
                        "properties": .object([:])
                    ])
                )
            ]
        )
    }

    @Test func sendsAnthropicRequestAndDecodesContent() async throws {
        let captured = LockedBox<URLRequest?>(nil)
        StubURLProtocol.setHandler(forHost: host) { request in
            captured.set(request)
            let body = """
            {"content":[
              {"type":"text","text":"Hi"},
              {"type":"tool_use","id":"tool_1","name":"read_file","input":{"path":"a.txt"}}
            ],"stop_reason":"tool_use","usage":{
              "input_tokens":10,"output_tokens":5,
              "cache_read_input_tokens":3,"cache_creation_input_tokens":2
            }}
            """
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(body.utf8))
        }
        defer { StubURLProtocol.setHandler(forHost: host, nil) }

        let response = try await client().complete(request())

        #expect(response.message.content == "Hi")
        #expect(response.message.toolCalls == [
            ToolCall(id: "tool_1", name: "read_file", arguments: #"{"path":"a.txt"}"#)
        ])
        #expect(response.finishReason == "tool_use")
        #expect(response.usage == ModelUsage(
            inputTokens: 15,
            outputTokens: 5,
            cachedInputTokens: 3,
            reasoningTokens: nil
        ))

        let urlRequest = try #require(captured.get())
        #expect(urlRequest.url?.absoluteString == "https://anthropic-client.test/v1/messages")
        #expect(urlRequest.value(forHTTPHeaderField: "x-api-key") == "test-key")
        #expect(urlRequest.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")

        let body = try #require(requestBody(from: urlRequest))
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["system"] as? String == "System rules")
        #expect(object["max_tokens"] as? Int == 8192)
        #expect(object["stream"] as? Bool == false)

        let messages = try #require(object["messages"] as? [[String: Any]])
        #expect(messages.count == 3)
        #expect(messages[0]["role"] as? String == "user")
        #expect(messages[1]["role"] as? String == "assistant")
        #expect(messages[2]["role"] as? String == "user")

        let assistantBlocks = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(assistantBlocks.first?["type"] as? String == "tool_use")
        #expect(assistantBlocks.first?["id"] as? String == "call_1")

        let toolBlocks = try #require(messages[2]["content"] as? [[String: Any]])
        #expect(toolBlocks.first?["type"] as? String == "tool_result")
        #expect(toolBlocks.first?["tool_use_id"] as? String == "call_1")
    }

    @Test func encodesUserImagesAsImageBlocks() async throws {
        let captured = LockedBox<URLRequest?>(nil)
        StubURLProtocol.setHandler(forHost: host) { request in
            captured.set(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"content":[{"type":"text","text":"ok"}]}"#.utf8))
        }
        defer { StubURLProtocol.setHandler(forHost: host, nil) }

        let image = ChatImage(mimeType: "image/png", data: Data("img".utf8))
        _ = try await client().complete(ChatRequest(
            messages: [ChatMessage(role: .user, content: "Describe", images: [image])],
            tools: []
        ))

        let urlRequest = try #require(captured.get())
        let body = try #require(requestBody(from: urlRequest))
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(object["messages"] as? [[String: Any]])
        let blocks = try #require(messages.first?["content"] as? [[String: Any]])

        #expect(blocks.count == 2)
        #expect(blocks[0]["type"] as? String == "image")
        let source = try #require(blocks[0]["source"] as? [String: Any])
        #expect(source["type"] as? String == "base64")
        #expect(source["media_type"] as? String == "image/png")
        #expect(source["data"] as? String == "aW1n")
        #expect(blocks[1]["type"] as? String == "text")
    }

    @Test func streamsTextThinkingToolsAndUsage() async throws {
        let stream = """
        event: message_start
        data: {"type":"message_start","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":4,"cache_creation_input_tokens":2}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text"}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}
        data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Think"}}

        event: content_block_start
        data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"tool_1","name":"read_file"}}

        data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"path\\":"}}
        data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\\"a.txt\\"}"}}
        data: {"type":"content_block_stop","index":1}
        data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":9}}
        data: {"type":"message_stop"}

        """.data(using: .utf8)!
        StubURLProtocol.setHandler(forHost: host) { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, stream)
        }
        defer { StubURLProtocol.setHandler(forHost: host, nil) }

        var text = ""
        var reasoning = ""
        var completed: ChatResponse?

        for try await event in client().stream(request()) {
            switch event {
            case .textDelta(let delta):
                text += delta
            case .reasoningDelta(let delta):
                reasoning += delta
            case .completed(let response):
                completed = response
            }
        }

        #expect(text == "Hello")
        #expect(reasoning == "Think")
        #expect(completed?.finishReason == "tool_use")
        #expect(completed?.message.toolCalls == [
            ToolCall(id: "tool_1", name: "read_file", arguments: #"{"path":"a.txt"}"#)
        ])
        #expect(completed?.usage == ModelUsage(
            inputTokens: 16,
            outputTokens: 9,
            cachedInputTokens: 4,
            reasoningTokens: nil
        ))
    }

    @Test func mapsHTTPErrors() async throws {
        StubURLProtocol.setHandler(forHost: host) { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 400,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"bad request"}}"#.utf8))
        }
        defer { StubURLProtocol.setHandler(forHost: host, nil) }

        do {
            _ = try await client().complete(request())
            Issue.record("Expected an HTTP error")
        } catch let error as ModelError {
            #expect(error == .http(status: 400, message: "bad request"))
        }
    }
}
