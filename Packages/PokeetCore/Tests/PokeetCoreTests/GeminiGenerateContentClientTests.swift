import Foundation
import Testing
@testable import PokeetCore

@Suite(.serialized)
struct GeminiGenerateContentClientTests {
    private let host = "gemini-client.test"

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func client() -> GeminiGenerateContentClient {
        GeminiGenerateContentClient(
            baseURL: "https://gemini-client.test/v1beta",
            model: "auto/test-model",
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
                        "properties": .object([
                            "path": .object(["type": .string("string")])
                        ]),
                        "required": .array([.string("path")]),
                        "additionalProperties": .bool(false)
                    ])
                )
            ]
        )
    }

    @Test func sendsGeminiRequestAndDecodesContent() async throws {
        let captured = LockedBox<URLRequest?>(nil)
        StubURLProtocol.setHandler(forHost: host) { request in
            captured.set(request)
            let body = """
            {"candidates":[{"content":{"parts":[
              {"text":"Hello"},
              {"functionCall":{"name":"read_file","args":{"path":"a.txt"}}}
            ]},"finishReason":"STOP"}],"usageMetadata":{
              "promptTokenCount":100,"candidatesTokenCount":10,
              "cachedContentTokenCount":64,"thoughtsTokenCount":2
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
        #expect(response.message.toolCalls?.first?.name == "read_file")
        #expect(response.message.toolCalls?.first?.arguments.contains("a.txt") == true)
        #expect(response.finishReason == "STOP")
        #expect(response.usage == ModelUsage(
            inputTokens: 100,
            outputTokens: 10,
            cachedInputTokens: 64,
            reasoningTokens: 2
        ))

        let urlRequest = try #require(captured.get())
        #expect(
            urlRequest.url?.absoluteString
                == "https://gemini-client.test/v1beta/models/auto/test-model:generateContent"
        )
        #expect(urlRequest.value(forHTTPHeaderField: "x-goog-api-key") == "test-key")

        let body = try #require(requestBody(from: urlRequest))
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])

        let system = try #require(object["systemInstruction"] as? [String: Any])
        let systemParts = try #require(system["parts"] as? [[String: Any]])
        #expect(systemParts.first?["text"] as? String == "System rules")

        let contents = try #require(object["contents"] as? [[String: Any]])
        #expect(contents.map { $0["role"] as? String } == ["user", "model", "user"])

        let modelParts = try #require(contents[1]["parts"] as? [[String: Any]])
        let functionCall = try #require(modelParts.first?["functionCall"] as? [String: Any])
        #expect(functionCall["name"] as? String == "read_file")

        let resultParts = try #require(contents[2]["parts"] as? [[String: Any]])
        let functionResponse = try #require(resultParts.first?["functionResponse"] as? [String: Any])
        #expect(functionResponse["name"] as? String == "read_file")

        let tools = try #require(object["tools"] as? [[String: Any]])
        let declarations = try #require(tools.first?["functionDeclarations"] as? [[String: Any]])
        let parameters = try #require(declarations.first?["parameters"] as? [String: Any])
        #expect(parameters["additionalProperties"] == nil)
        #expect(parameters["type"] as? String == "object")

        let generation = try #require(object["generationConfig"] as? [String: Any])
        #expect(generation["maxOutputTokens"] as? Int == 8192)
    }

    @Test func encodesUserImagesAsInlineData() async throws {
        let captured = LockedBox<URLRequest?>(nil)
        StubURLProtocol.setHandler(forHost: host) { request in
            captured.set(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"candidates":[{"content":{"parts":[{"text":"ok"}]}}]}"#.utf8))
        }
        defer { StubURLProtocol.setHandler(forHost: host, nil) }

        let image = ChatImage(mimeType: "image/jpeg", data: Data("img".utf8))
        _ = try await client().complete(ChatRequest(
            messages: [ChatMessage(role: .user, content: "Describe", images: [image])],
            tools: []
        ))

        let urlRequest = try #require(captured.get())
        let body = try #require(requestBody(from: urlRequest))
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let contents = try #require(object["contents"] as? [[String: Any]])
        let parts = try #require(contents.first?["parts"] as? [[String: Any]])

        #expect(parts.count == 2)
        let inlineData = try #require(parts[0]["inlineData"] as? [String: Any])
        #expect(inlineData["mimeType"] as? String == "image/jpeg")
        #expect(inlineData["data"] as? String == "aW1n")
        #expect(parts[1]["text"] as? String == "Describe")
    }

    @Test func streamsTextThoughtsAndFunctionCalls() async throws {
        let stream = """
        data: {"candidates":[{"content":{"parts":[{"text":"Think","thought":true}]}}]}
        data: {"candidates":[{"content":{"parts":[{"text":"Hel"}]}}]}
        data: {"candidates":[{"content":{"parts":[{"text":"lo"}]}}]}
        data: {"candidates":[{"content":{"parts":[{"functionCall":{"name":"read_file","args":{"path":"a.txt"}}}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":12,"candidatesTokenCount":6}}
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
        #expect(completed?.finishReason == "STOP")
        #expect(completed?.message.toolCalls?.count == 1)
        #expect(completed?.message.toolCalls?.first?.name == "read_file")
        #expect(completed?.message.toolCalls?.first?.arguments.contains("a.txt") == true)
        #expect(completed?.usage == ModelUsage(
            inputTokens: 12,
            outputTokens: 6,
            cachedInputTokens: 0,
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
            return (response, Data(#"{"error":{"code":400,"message":"bad request","status":"INVALID_ARGUMENT"}}"#.utf8))
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
