import Foundation
import Testing
@testable import PokeetCore

@Suite(.serialized)
struct OpenAIResponsesClientTests {
    private let host = "responses.test"

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func client(baseURL: String = "https://responses.test/v1") -> OpenAIResponsesClient {
        OpenAIResponsesClient(
            baseURL: baseURL,
            model: "test-model",
            apiKey: "test-key",
            session: makeSession()
        )
    }

    private func respond(_ body: String, status: Int = 200, host: String? = nil) {
        let targetHost = host ?? self.host
        StubURLProtocol.setHandler(forHost: targetHost) { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(body.utf8))
        }
    }

    private func request() -> ChatRequest {
        ChatRequest(
            messages: [
                .system("You are helpful."),
                .user("Read a file."),
                .assistant(nil, toolCalls: [
                    ToolCall(id: "call_1", name: "read_file", arguments: #"{"path":"a.txt"}"#)
                ]),
                .tool("contents", callID: "call_1")
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

    @Test func sendsResponsesRequestAndDecodesOutput() async throws {
        let captured = LockedBox<URLRequest?>(nil)
        StubURLProtocol.setHandler(forHost: host) { request in
            captured.set(request)
            let body = """
            {"status":"completed","output":[
              {"type":"message","content":[{"type":"output_text","text":"Hello"}]},
              {"type":"function_call","call_id":"call_9","name":"read_file","arguments":"{\\"path\\":\\"a.txt\\"}"}
            ],"usage":{
              "input_tokens":100,"output_tokens":10,
              "input_tokens_details":{"cached_tokens":64},
              "output_tokens_details":{"reasoning_tokens":2}
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

        #expect(response.message.content == "Hello")
        #expect(response.message.toolCalls == [
            ToolCall(id: "call_9", name: "read_file", arguments: #"{"path":"a.txt"}"#)
        ])
        #expect(response.usage == ModelUsage(
            inputTokens: 100,
            outputTokens: 10,
            cachedInputTokens: 64,
            reasoningTokens: 2
        ))

        let urlRequest = try #require(captured.get())
        #expect(urlRequest.url?.absoluteString == "https://responses.test/v1/responses")
        #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")

        let body = try #require(requestBody(from: urlRequest))
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(object["instructions"] as? String == "You are helpful.")
        #expect(object["store"] as? Bool == false)
        #expect(object["stream"] as? Bool == false)

        let input = try #require(object["input"] as? [[String: Any]])
        #expect(input[0]["role"] as? String == "user")
        #expect(input[1]["type"] as? String == "function_call")
        #expect(input[1]["call_id"] as? String == "call_1")
        #expect(input[2]["type"] as? String == "function_call_output")
        #expect(input[2]["output"] as? String == "contents")

        let tools = try #require(object["tools"] as? [[String: Any]])
        #expect(tools.first?["type"] as? String == "function")
        #expect(tools.first?["name"] as? String == "read_file")
    }

    @Test func streamsTextReasoningAndToolArguments() async throws {
        let stream = """
        data: {"type":"response.reasoning_summary_text.delta","delta":"Think"}
        data: {"type":"response.output_text.delta","delta":"Hel"}
        data: {"type":"response.output_text.delta","delta":"lo"}
        data: {"type":"response.output_item.added","item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"read_file","arguments":""}}
        data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"{\\"path\\":"}
        data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"\\"a.txt\\"}"}
        data: {"type":"response.output_item.done","item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"read_file","arguments":"{\\"path\\":\\"a.txt\\"}"}}
        data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":12,"output_tokens":6,"input_tokens_details":{"cached_tokens":4}}}}
        data: [DONE]
        """.data(using: .utf8)!
        respond(String(decoding: stream, as: UTF8.self))
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
        #expect(completed?.message.content == "Hello")
        #expect(completed?.message.toolCalls == [
            ToolCall(id: "call_1", name: "read_file", arguments: #"{"path":"a.txt"}"#)
        ])
        #expect(completed?.usage == ModelUsage(
            inputTokens: 12,
            outputTokens: 6,
            cachedInputTokens: 4,
            reasoningTokens: nil
        ))
    }

    @Test func mapsHTTPErrors() async throws {
        respond(#"{"error":{"message":"bad key"}}"#, status: 401)
        defer { StubURLProtocol.setHandler(forHost: host, nil) }

        do {
            _ = try await client().complete(request())
            Issue.record("Expected an HTTP error")
        } catch let error as ModelError {
            #expect(error == .http(status: 401, message: "bad key"))
        }
    }

}
