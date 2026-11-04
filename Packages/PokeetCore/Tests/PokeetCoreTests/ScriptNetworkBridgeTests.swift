import Foundation
import Testing
@testable import PokeetCore

/// Its own protocol class, so this suite's handler cannot be swapped underneath it by
/// the HTTP tool tests running in parallel.
final class ScriptStubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    nonisolated(unsafe) static var handler: Handler?

    static func setHandler(_ next: Handler?) { handler = next }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
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

@Suite(.serialized)
struct ScriptNetworkBridgeTests {
    private func makeBridge(
        limits: NetworkClient.Limits = .init(),
        policy: NetworkAccessPolicy = .init()
    ) -> ScriptNetworkBridge {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptStubURLProtocol.self]
        return ScriptNetworkBridge(
            access: ScriptNetworkAccess(
                client: NetworkClient(
                    session: URLSession(configuration: configuration),
                    limits: limits
                ),
                policy: policy
            )
        )
    }

    private func respond(
        status: Int,
        headers: [String: String] = ["Content-Type": "application/json"],
        body: String
    ) -> ScriptStubURLProtocol.Handler {
        { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            return (response, Data(body.utf8))
        }
    }

    private static func bodyText(of request: URLRequest) -> String {
        if let data = request.httpBody {
            return String(decoding: data, as: UTF8.self)
        }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func payload(_ json: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
    }

    @Test("returns the status, headers and body as JSON")
    func returnsResponse() throws {
        ScriptStubURLProtocol.setHandler(respond(status: 200, body: #"{"ok":true}"#))
        defer { ScriptStubURLProtocol.setHandler(nil) }

        let result = try makeBridge().handle(
            try payload(["url": "https://example.com/data", "method": "GET"])
        )
        let decoded = try #require(
            JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any]
        )
        #expect(decoded["status"] as? Int == 200)
        #expect(decoded["body"] as? String == #"{"ok":true}"#)
        let headers = try #require(decoded["headers"] as? [[String]])
        #expect(headers.contains { $0[0] == "content-type" })
    }

    @Test("sends a POST body")
    func sendsBody() throws {
        ScriptStubURLProtocol.setHandler { request in
            // URLProtocol hands the body over as a stream, not as `httpBody`.
            let body = Self.bodyText(of: request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 201, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (response, Data(body.utf8))
        }
        defer { ScriptStubURLProtocol.setHandler(nil) }

        let result = try makeBridge().handle(
            try payload([
                "url": "https://example.com/items",
                "method": "POST",
                "body": "hello"
            ])
        )
        let decoded = try #require(
            JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any]
        )
        #expect(decoded["status"] as? Int == 201)
        #expect(decoded["body"] as? String == "hello")
    }

    @Test("reaches a local host, which the policy no longer refuses")
    func allowsLocalHost() throws {
        ScriptStubURLProtocol.setHandler(respond(status: 200, body: "local"))
        defer { ScriptStubURLProtocol.setHandler(nil) }

        let result = try makeBridge().handle(try payload(["url": "https://localhost/admin"]))
        let decoded = try #require(
            JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any]
        )
        #expect(decoded["body"] as? String == "local")
    }

    @Test("refuses plain HTTP")
    func refusesPlainHTTP() throws {
        ScriptStubURLProtocol.setHandler(respond(status: 200, body: "leak"))
        defer { ScriptStubURLProtocol.setHandler(nil) }

        #expect(throws: (any Error).self) {
            try makeBridge().handle(try payload(["url": "http://example.com/"]))
        }
    }

    @Test("honours an allowlist")
    func honoursAllowlist() throws {
        ScriptStubURLProtocol.setHandler(respond(status: 200, body: "ok"))
        defer { ScriptStubURLProtocol.setHandler(nil) }

        let policy = NetworkAccessPolicy(isEnabled: true, allowedHosts: ["other.example.com"])
        #expect(throws: (any Error).self) {
            try makeBridge(policy: policy).handle(
                try payload(["url": "https://example.com/"])
            )
        }
    }

    @Test("refuses a GET body")
    func refusesBodyOnGet() throws {
        #expect(throws: (any Error).self) {
            try makeBridge().handle(
                try payload(["url": "https://example.com/", "method": "GET", "body": "x"])
            )
        }
    }

    @Test("refuses an unsupported method")
    func refusesMethod() throws {
        #expect(throws: (any Error).self) {
            try makeBridge().handle(
                try payload(["url": "https://example.com/", "method": "TRACE"])
            )
        }
    }
}
