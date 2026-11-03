import PokeetCore
import XCTest
@testable import Pokeet

private let host = "api.deepseek.com"
private let keyName = "secret.websearch.deepseek.apiKey"

final class DeepSeekSearchProviderTests: XCTestCase {
    private var secrets: StubSecretStore!
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        secrets = StubSecretStore()
        session = SearchStubProtocol.session()
        SearchStubProtocol.reset()
    }

    private func makeProvider() -> DeepSeekSearchProvider {
        DeepSeekSearchProvider(secrets: secrets, keyName: keyName, session: session)
    }

    func testPrefersSummaryAndParsesDate() async throws {
        secrets.set("sk-deepseek", for: keyName)
        SearchStubProtocol.stub(host) { _ in
            (200, ["Content-Type": "application/json"], Data("""
            {"results":[
              {"rerank_score":2.4,"title":"DeepSeek V4","url":"https://example.com/v4",
               "snippet":"V4 is out.","summary":"DeepSeek released V4 with better tool calling.",
               "content":"","site_name":"Example","site_icon":null,"date":"2026-06-01T00:00:00+00:00","authority":3},
              {"rerank_score":1.1,"title":"Snippet only","url":"https://example.com/snippet",
               "snippet":"Short form.","summary":"","content":null,"site_name":null,"site_icon":null,"date":null,"authority":-1},
              {"rerank_score":0.9,"title":"Not http","url":"ftp://example.com/x","snippet":"","summary":"","content":null,"site_name":null,"site_icon":null,"date":null,"authority":0}
            ]}
            """.utf8))
        }

        let results = try await makeProvider().search(query: "deepseek v4", limit: 5)

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].title, "DeepSeek V4")
        XCTAssertEqual(results[0].snippet, "DeepSeek released V4 with better tool calling.")
        XCTAssertNotNil(results[0].published)
        XCTAssertEqual(results[1].snippet, "Short form.", "falls back to snippet when summary is empty")

        let request = try XCTUnwrap(SearchStubProtocol.lastRequest(for: host))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/v1/tools/search")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-deepseek")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = request.bodyJSON
        XCTAssertEqual(body["query"] as? String, "deepseek v4")
        XCTAssertEqual(body["count"] as? Int, 5)
        XCTAssertEqual(body["need_content"] as? Bool, false, "page bodies come from http_request, not search")
    }

    func testClampsResultCount() async throws {
        secrets.set("sk-deepseek", for: keyName)
        SearchStubProtocol.stub(host) { _ in (200, [:], Data(#"{"results":[]}"#.utf8)) }

        _ = try await makeProvider().search(query: "q", limit: 99)

        let request = try XCTUnwrap(SearchStubProtocol.lastRequest(for: host))
        XCTAssertEqual(request.bodyJSON["count"] as? Int, 50)
    }

    func testMapsStatusCodes() async throws {
        secrets.set("sk-deepseek", for: keyName)
        let provider = makeProvider()

        SearchStubProtocol.stub(host) { _ in (401, [:], Data()) }
        await assertError(.rejectedKey, from: provider)

        SearchStubProtocol.stub(host) { _ in (429, ["Retry-After": "5"], Data()) }
        await assertError(.rateLimited(retryAfter: 5), from: provider)

        SearchStubProtocol.stub(host) { _ in (429, [:], Data()) }
        await assertError(.rateLimited(retryAfter: nil), from: provider)
    }

    func testExplainsOutOfBalance() async throws {
        secrets.set("sk-deepseek", for: keyName)
        SearchStubProtocol.stub(host) { _ in
            (402, [:], Data(#"{"error":{"message":"Insufficient Balance","type":"invalid_request_error","param":null,"code":"invalid_request_error"}}"#.utf8))
        }

        do {
            _ = try await makeProvider().search(query: "q", limit: 5)
            XCTFail("Expected a failure")
        } catch let error as WebSearchError {
            guard case .failed(let message) = error else {
                return XCTFail("Expected .failed, got \(error)")
            }
            XCTAssertTrue(message.contains("no balance"), message)
        }
    }

    func testSurfacesProviderMessageOnBadRequest() async throws {
        secrets.set("sk-deepseek", for: keyName)
        SearchStubProtocol.stub(host) { _ in
            (400, [:], Data(#"{"error":{"message":"'count' must be between 1 and 50","type":"invalid_request_error","param":null,"code":"invalid_request_error"}}"#.utf8))
        }

        do {
            _ = try await makeProvider().search(query: "q", limit: 5)
            XCTFail("Expected a failure")
        } catch let error as WebSearchError {
            guard case .failed(let message) = error else {
                return XCTFail("Expected .failed, got \(error)")
            }
            XCTAssertTrue(message.contains("must be between 1 and 50"), message)
        }
    }

    func testMalformedPayload() async throws {
        secrets.set("sk-deepseek", for: keyName)
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
        from provider: DeepSeekSearchProvider,
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
