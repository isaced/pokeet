import PokeetCore
import XCTest
@testable import Pokeet

/// URLProtocol stub shared by the search adapter tests.
///
/// Handlers are keyed by host, so the Brave, Tavily and DeepSeek suites can run
/// in the same process (or in parallel) without stepping on each other.
final class SearchStubProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, [String: String], Data)

    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var requests: [String: URLRequest] = [:]
    nonisolated(unsafe) private static let lock = NSLock()

    static func stub(_ host: String, handler: @escaping Handler) {
        lock.withLock { handlers[host] = handler }
    }

    static func lastRequest(for host: String) -> URLRequest? {
        lock.withLock { requests[host] }
    }

    static func reset() {
        lock.withLock {
            handlers.removeAll()
            requests.removeAll()
        }
    }

    /// A session wired to this stub, and nothing else.
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SearchStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        let handler = Self.lock.withLock { () -> Handler? in
            Self.requests[host] = request
            return Self.handlers[host]
        }

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, headers, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class StubSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func string(for key: String) -> String? {
        lock.withLock { values[key] }
    }

    func set(_ value: String, for key: String) {
        lock.withLock { values[key] = value }
    }

    func delete(_ key: String) {
        lock.withLock { values.removeValue(forKey: key) }
    }
}

extension URLRequest {
    /// Decoded JSON body, whether URLSession kept it as `httpBody` or moved it
    /// into `httpBodyStream` on the way to URLProtocol.
    var bodyJSON: [String: Any] {
        var data = httpBody
        if data == nil, let stream = httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            var collected = Data()
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                guard read > 0 else { break }
                collected.append(contentsOf: buffer[0..<read])
            }
            data = collected
        }
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }
}
