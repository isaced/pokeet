import Foundation
import PokeetCore

/// Minimal URLProtocol stub so the sandbox's network can be exercised without a server.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    nonisolated(unsafe) static var handler: Handler?

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

enum NetworkTestSupport {
    struct Resolver: HostResolving {
        func resolve(host: String) async throws -> [String] {
            host.lowercased() == "localhost" ? ["127.0.0.1"] : ["93.184.216.34"]
        }
    }

    static func access(
        policy: NetworkAccessPolicy = NetworkAccessPolicy()
    ) -> ScriptNetworkAccess {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return ScriptNetworkAccess(
            client: NetworkClient(
                session: URLSession(configuration: configuration),
                resolver: Resolver(),
                limits: NetworkClient.Limits()
            ),
            policy: policy
        )
    }

    static func bodyText(of request: URLRequest) -> String {
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

    static func respond(
        status: Int = 200,
        headers: [String: String] = ["Content-Type": "application/json"],
        body: String
    ) {
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            return (response, Data(body.utf8))
        }
    }
}
