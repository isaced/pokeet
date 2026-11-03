import PokeetCore
import XCTest
@testable import Pokeet

private let host = "api.search.brave.com"
private let keyName = "secret.websearch.brave.apiKey"

final class BraveSearchProviderTests: XCTestCase {
    private var secrets: StubSecretStore!
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        secrets = StubSecretStore()
        session = SearchStubProtocol.session()
        SearchStubProtocol.reset()
    }

    private func makeProvider() -> BraveSearchProvider {
        BraveSearchProvider(secrets: secrets, keyName: keyName, session: session)
    }

    func testDecodesResultsAndSendsCredentials() async throws {
        secrets.set("brave-key", for: keyName)
        SearchStubProtocol.stub(host) { _ in
            (200, ["Content-Type": "application/json"], Data("""
            {"web":{"results":[
              {"title":"SwiftUI Lists","url":"https://developer.apple.com/lists","description":"Rows match by identity.","page_age":"2025-04-01T10:00:00Z"},
              {"title":"Diffable","url":"https://example.com/diffable","description":"Snapshots."}
            ]}}
            """.utf8))
        }

        let results = try await makeProvider().search(query: "swiftui list", limit: 5)

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].title, "SwiftUI Lists")
        XCTAssertEqual(results[0].url, "https://developer.apple.com/lists")
        XCTAssertEqual(results[0].snippet, "Rows match by identity.")
        XCTAssertNotNil(results[0].published)
        XCTAssertNil(results[1].published)

        let request = try XCTUnwrap(SearchStubProtocol.lastRequest(for: host))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Subscription-Token"), "brave-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, host)
        XCTAssertEqual(components.queryItems?.first { $0.name == "q" }?.value, "swiftui list")
        XCTAssertEqual(components.queryItems?.first { $0.name == "count" }?.value, "5")
    }

    func testClampsResultCount() async throws {
        secrets.set("brave-key", for: keyName)
        SearchStubProtocol.stub(host) { _ in
            (200, [:], Data(#"{"web":{"results":[]}}"#.utf8))
        }

        _ = try await makeProvider().search(query: "q", limit: 99)

        let request = try XCTUnwrap(SearchStubProtocol.lastRequest(for: host))
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first { $0.name == "count" }?.value, "20")
    }

    func testMapsStatusCodes() async throws {
        secrets.set("brave-key", for: keyName)
        let provider = makeProvider()

        SearchStubProtocol.stub(host) { _ in (401, [:], Data()) }
        await assertError(.rejectedKey, from: provider)

        SearchStubProtocol.stub(host) { _ in (429, ["Retry-After": "42"], Data()) }
        await assertError(.rateLimited(retryAfter: 42), from: provider)

        SearchStubProtocol.stub(host) { _ in (503, [:], Data()) }
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
        SearchStubProtocol.stub(host) { _ in (200, [:], Data("<html>nope</html>".utf8)) }

        await assertError(.malformedResponse, from: makeProvider())
    }

    func testMissingKeyThrowsBeforeAnyRequest() async throws {
        SearchStubProtocol.stub(host) { _ in
            XCTFail("No request should be made without a key")
            return (200, [:], Data())
        }

        await assertError(.notConfigured, from: makeProvider())
        XCTAssertNil(SearchStubProtocol.lastRequest(for: host))
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
