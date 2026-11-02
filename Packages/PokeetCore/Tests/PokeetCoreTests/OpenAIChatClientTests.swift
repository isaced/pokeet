import Foundation
import Testing
@testable import PokeetCore

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) {
        self.value = value
    }

    func set(_ newValue: T) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> T {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var handler:
        (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    private static let lock = NSLock()

    static func setHandler(_ newHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?) {
        lock.lock()
        handler = newHandler
        lock.unlock()
    }

    private static func currentHandler() -> (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? {
        lock.lock()
        defer { lock.unlock() }
        return handler
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.currentHandler() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func requestBody(from request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else {
        return nil
    }

    stream.open()
    defer { stream.close() }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let read = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let baseAddress = raw.bindMemory(to: UInt8.self).baseAddress else {
                return 0
            }
            return stream.read(baseAddress, maxLength: raw.count)
        }
        if read <= 0 {
            break
        }
        data.append(buffer, count: read)
    }
    return data.isEmpty ? nil : data
}

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

    @Test func requiresConfiguration() async throws {
        let client = OpenAIChatClient(baseURL: "", model: "", apiKey: "")
        do {
            _ = try await client.complete(ChatRequest(messages: [.user("hi")], tools: []))
            Issue.record("Expected notConfigured")
        } catch let error as ModelError {
            #expect(error == .notConfigured)
        }
    }
}
