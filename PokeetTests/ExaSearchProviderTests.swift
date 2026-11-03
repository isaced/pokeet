import PokeetCore
import XCTest
@testable import Pokeet

private let host = "api.exa.ai"
private let keyName = "secret.websearch.exa.apiKey"

final class ExaSearchProviderTests: XCTestCase {
    private var secrets: StubSecretStore!
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        secrets = StubSecretStore()
        session = SearchStubProtocol.session()
        SearchStubProtocol.reset()
    }

    private func makeProvider() -> ExaSearchProvider {
        ExaSearchProvider(secrets: secrets, keyName: keyName, session: session)
    }

    func testRequestsHighlightsAndJoinsThem() async throws {
        secrets.set("exa-key", for: keyName)
        SearchStubProtocol.stub(host) { _ in
            (200, ["Content-Type": "application/json"], Data("""
            {"requestId":"c3174df2","resolvedSearchType":"","results":[
              {"id":"https://example.com/a","title":"Retrieval techniques","url":"https://example.com/a",
               "publishedDate":"2025-04-14T00:00:00.000Z",
               "highlights":["First excerpt.","Second excerpt."],"summary":null,"text":null},
              {"id":"https://example.com/b","title":"No highlights","url":"https://example.com/b",
               "publishedDate":null,"highlights":[],"summary":"Summary fallback."},
              {"id":"https://example.com/c","title":"Bad scheme","url":"ftp://example.com/c","highlights":[]}
            ],"searchTime":1324.3,"costDollars":{"total":0.007}}
            """.utf8))
        }

        let results = try await makeProvider().search(query: "recent RAG techniques", limit: 5)

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].title, "Retrieval techniques")
        XCTAssertEqual(results[0].url, "https://example.com/a")
        XCTAssertEqual(results[0].snippet, "First excerpt. … Second excerpt.")
        XCTAssertNotNil(results[0].published, "publishedDate arrives with milliseconds")
        XCTAssertEqual(results[1].snippet, "Summary fallback.", "falls back when no highlights come back")

        let request = try XCTUnwrap(SearchStubProtocol.lastRequest(for: host))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.exa.ai/search")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer exa-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = request.bodyJSON
        XCTAssertEqual(body["query"] as? String, "recent RAG techniques")
        XCTAssertEqual(body["numResults"] as? Int, 5)
        XCTAssertEqual(body["type"] as? String, "auto", "deep would block the turn for up to 15 seconds")
        let contents = try XCTUnwrap(body["contents"] as? [String: Any])
        XCTAssertEqual(contents["highlights"] as? Bool, true, "highlights, not full text")
        XCTAssertNil(contents["text"])
    }

    func testClampsResultCount() async throws {
        secrets.set("exa-key", for: keyName)
        SearchStubProtocol.stub(host) { _ in
            (200, [:], Data(#"{"results":[]}"#.utf8))
        }

        _ = try await makeProvider().search(query: "q", limit: 500)

        let request = try XCTUnwrap(SearchStubProtocol.lastRequest(for: host))
        XCTAssertEqual(request.bodyJSON["numResults"] as? Int, 100)
    }

    func testMapsStatusCodes() async throws {
        secrets.set("exa-key", for: keyName)
        let provider = makeProvider()

        SearchStubProtocol.stub(host) { _ in (401, [:], Data()) }
        await assertError(.rejectedKey, from: provider)

        SearchStubProtocol.stub(host) { _ in (429, ["Retry-After": "9"], Data()) }
        await assertError(.rateLimited(retryAfter: 9), from: provider)

        SearchStubProtocol.stub(host) { _ in (429, [:], Data()) }
        await assertError(.rateLimited(retryAfter: nil), from: provider)
    }

    func testExplainsExhaustedCredits() async throws {
        secrets.set("exa-key", for: keyName)
        SearchStubProtocol.stub(host) { _ in
            (402, [:], Data(#"{"requestId":"6720","error":"No credits left","tag":"NO_MORE_CREDITS"}"#.utf8))
        }

        do {
            _ = try await makeProvider().search(query: "q", limit: 5)
            XCTFail("Expected a failure")
        } catch let error as WebSearchError {
            guard case .failed(let message) = error else {
                return XCTFail("Expected .failed, got \(error)")
            }
            XCTAssertTrue(message.contains("credits are exhausted"), message)
        }
    }

    func testSurfacesValidationMessage() async throws {
        secrets.set("exa-key", for: keyName)
        SearchStubProtocol.stub(host) { _ in
            (400, [:], Data(#"{"requestId":"6720","error":"Invalid request body | Validation error: Invalid value for type","tag":"INVALID_REQUEST_BODY"}"#.utf8))
        }

        do {
            _ = try await makeProvider().search(query: "q", limit: 5)
            XCTFail("Expected a failure")
        } catch let error as WebSearchError {
            guard case .failed(let message) = error else {
                return XCTFail("Expected .failed, got \(error)")
            }
            XCTAssertTrue(message.contains("Invalid value for type"), message)
        }
    }

    func testMalformedPayload() async throws {
        secrets.set("exa-key", for: keyName)
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
        from provider: ExaSearchProvider,
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
