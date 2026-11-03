import PokeetCore
import XCTest
@testable import Pokeet

final class BraveSearchStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, [String: String], Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        guard let handler = Self.handler else {
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

private final class KeyStore: SecretStore, @unchecked Sendable {
    private var values: [String: String] = [:]

    func string(for key: String) -> String? { values[key] }
    func set(_ value: String, for key: String) { values[key] = value }
    func delete(_ key: String) { values.removeValue(forKey: key) }
}

final class BraveSearchProviderTests: XCTestCase {
    private let keyName = "secret.websearch.brave.apiKey"
    private var secrets: KeyStore!
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        secrets = KeyStore()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BraveSearchStubProtocol.self]
        session = URLSession(configuration: configuration)
        BraveSearchStubProtocol.handler = nil
        BraveSearchStubProtocol.lastRequest = nil
    }

    func testDecodesResultsAndSendsCredentials() async throws {
        secrets.set("brave-key", for: keyName)
        BraveSearchStubProtocol.handler = { request in
            (200, ["Content-Type": "application/json"], Data("""
            {"web":{"results":[
              {"title":"SwiftUI Lists","url":"https://developer.apple.com/lists","description":"Rows match by identity.","page_age":"2025-04-01T10:00:00Z"},
              {"title":"Diffable","url":"https://example.com/diffable","description":"Snapshots."}
            ]}}
            """.utf8))
        }

        let provider = BraveSearchProvider(secrets: secrets, keyName: keyName, session: session)
        let results = try await provider.search(query: "swiftui list", limit: 5)

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].title, "SwiftUI Lists")
        XCTAssertEqual(results[0].url, "https://developer.apple.com/lists")
        XCTAssertEqual(results[0].snippet, "Rows match by identity.")
        XCTAssertNotNil(results[0].published)
        XCTAssertNil(results[1].published)

        let request = try XCTUnwrap(BraveSearchStubProtocol.lastRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Subscription-Token"), "brave-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "api.search.brave.com")
        XCTAssertEqual(components.queryItems?.first { $0.name == "q" }?.value, "swiftui list")
        XCTAssertEqual(components.queryItems?.first { $0.name == "count" }?.value, "5")
    }

    func testClampsResultCount() async throws {
        secrets.set("brave-key", for: keyName)
        BraveSearchStubProtocol.handler = { _ in
            (200, [:], Data(#"{"web":{"results":[]}}"#.utf8))
        }

        let provider = BraveSearchProvider(secrets: secrets, keyName: keyName, session: session)
        _ = try await provider.search(query: "q", limit: 99)

        let request = try XCTUnwrap(BraveSearchStubProtocol.lastRequest)
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first { $0.name == "count" }?.value, "20")
    }

    func testMapsStatusCodes() async throws {
        secrets.set("brave-key", for: keyName)
        let provider = BraveSearchProvider(secrets: secrets, keyName: keyName, session: session)

        BraveSearchStubProtocol.handler = { _ in (401, [:], Data()) }
        await assertError(.rejectedKey, from: provider)

        BraveSearchStubProtocol.handler = { _ in (429, ["Retry-After": "42"], Data()) }
        await assertError(.rateLimited(retryAfter: 42), from: provider)

        BraveSearchStubProtocol.handler = { _ in (503, [:], Data()) }
        do {
            _ = try await provider.search(query: "q", limit: 5)
            XCTFail("Expected a failure")
        } catch let error as WebSearchError {
            guard case .failed(let message) = error else {
                return XCTFail("Expected .failed, got \(error)")
            }
            XCTAssertTrue(message.contains("503"))
        }
    }

    func testMalformedPayload() async throws {
        secrets.set("brave-key", for: keyName)
        BraveSearchStubProtocol.handler = { _ in (200, [:], Data("<html>nope</html>".utf8)) }

        let provider = BraveSearchProvider(secrets: secrets, keyName: keyName, session: session)
        await assertError(.malformedResponse, from: provider)
    }

    func testMissingKeyThrowsBeforeAnyRequest() async throws {
        BraveSearchStubProtocol.handler = { _ in
            XCTFail("No request should be made without a key")
            return (200, [:], Data())
        }

        let provider = BraveSearchProvider(secrets: secrets, keyName: keyName, session: session)
        await assertError(.notConfigured, from: provider)
        XCTAssertNil(BraveSearchStubProtocol.lastRequest)
    }

    private func assertError(
        _ expected: WebSearchError,
        from provider: BraveSearchProvider,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await provider.search(query: "q", limit: 5)
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as WebSearchError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error \(error)", file: file, line: line)
        }
    }
}
