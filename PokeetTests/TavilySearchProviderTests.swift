import PokeetCore
import XCTest
@testable import Pokeet

private let host = "api.tavily.com"
private let keyName = "secret.websearch.tavily.apiKey"

final class TavilySearchProviderTests: XCTestCase {
    private var secrets: StubSecretStore!
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        secrets = StubSecretStore()
        session = SearchStubProtocol.session()
        SearchStubProtocol.reset()
    }

    private func makeProvider() -> TavilySearchProvider {
        TavilySearchProvider(secrets: secrets, keyName: keyName, session: session)
    }

    func testSendsJSONBodyAndDecodesResults() async throws {
        secrets.set("tvly-key", for: keyName)
        SearchStubProtocol.stub(host) { _ in
            (200, ["Content-Type": "application/json"], Data("""
            {"query":"swiftui list","results":[
              {"title":"SwiftUI Lists","url":"https://developer.apple.com/lists","content":"Rows match by identity.","score":0.81,"published_date":"Tue, 11 Mar 2025 17:00:00 GMT"},
              {"title":"Diffable","url":"https://example.com/diffable","content":"Snapshots.","published_date":null},
              {"title":"No URL","url":null,"content":"dropped"}
            ],"response_time":1.67}
            """.utf8))
        }

        let results = try await makeProvider().search(query: "swiftui list", limit: 5)

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].title, "SwiftUI Lists")
        XCTAssertEqual(results[0].url, "https://developer.apple.com/lists")
        XCTAssertEqual(results[0].snippet, "Rows match by identity.")
        let published = try XCTUnwrap(results[0].published)
        XCTAssertEqual(
            published.timeIntervalSince1970,
            1_741_712_400,
            accuracy: 1,
            "published_date arrives as RFC 1123, not ISO 8601"
        )
        XCTAssertNil(results[1].published)

        let request = try XCTUnwrap(SearchStubProtocol.lastRequest(for: host))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tvly-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.url?.absoluteString, "https://api.tavily.com/search")

        let body = request.bodyJSON
        XCTAssertEqual(body["query"] as? String, "swiftui list")
        XCTAssertEqual(body["max_results"] as? Int, 5)
        XCTAssertEqual(body["search_depth"] as? String, "basic")
        XCTAssertEqual(body["include_answer"] as? Bool, false)
        XCTAssertEqual(body["include_raw_content"] as? Bool, false)
        XCTAssertEqual(body["include_published_date"] as? Bool, true)
    }

    func testClampsResultCount() async throws {
        secrets.set("tvly-key", for: keyName)
        SearchStubProtocol.stub(host) { _ in
            (200, [:], Data(#"{"query":"q","results":[]}"#.utf8))
        }

        _ = try await makeProvider().search(query: "q", limit: 99)

        let request = try XCTUnwrap(SearchStubProtocol.lastRequest(for: host))
        XCTAssertEqual(request.bodyJSON["max_results"] as? Int, 20)
    }

    func testMapsStatusCodes() async throws {
        secrets.set("tvly-key", for: keyName)
        let provider = makeProvider()

        SearchStubProtocol.stub(host) { _ in (401, [:], Data()) }
        await assertError(.rejectedKey, from: provider)

        SearchStubProtocol.stub(host) { _ in (429, ["Retry-After": "61"], Data()) }
        await assertError(.rateLimited(retryAfter: 61), from: provider)

        SearchStubProtocol.stub(host) { _ in
            (432, [:], Data(#"{"detail":{"error":"This request exceeds your plan's set usage limit."}}"#.utf8))
        }
        do {
            _ = try await provider.search(query: "q", limit: 5)
            XCTFail("Expected a failure")
        } catch let error as WebSearchError {
            guard case .failed(let message) = error else {
                return XCTFail("Expected .failed, got \(error)")
            }
            XCTAssertTrue(message.contains("plan's set usage limit"), message)
        }

        SearchStubProtocol.stub(host) { _ in (500, [:], Data(#"{"detail":{"error":"Internal Server Error"}}"#.utf8)) }
        do {
            _ = try await provider.search(query: "q", limit: 5)
            XCTFail("Expected a failure")
        } catch let error as WebSearchError {
            guard case .failed(let message) = error else {
                return XCTFail("Expected .failed, got \(error)")
            }
            XCTAssertTrue(message.contains("Internal Server Error"), message)
        }
    }

    func testServerWithoutMessageFallsBackToStatusText() async throws {
        secrets.set("tvly-key", for: keyName)
        SearchStubProtocol.stub(host) { _ in (503, [:], Data()) }

        do {
            _ = try await makeProvider().search(query: "q", limit: 5)
            XCTFail("Expected a failure")
        } catch let error as WebSearchError {
            guard case .failed(let message) = error else {
                return XCTFail("Expected .failed, got \(error)")
            }
            XCTAssertTrue(message.contains("503"), message)
        }
    }

    func testMalformedPayload() async throws {
        secrets.set("tvly-key", for: keyName)
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
        from provider: TavilySearchProvider,
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
