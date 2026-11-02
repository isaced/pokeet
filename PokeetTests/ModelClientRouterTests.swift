import PokeetCore
import XCTest
@testable import Pokeet

private struct EchoModelClient: ModelClient {
    let content: String

    func complete(_ request: ChatRequest) async throws -> ChatResponse {
        ChatResponse(message: .assistant(content), finishReason: "stop")
    }
}

final class ModelClientRouterTests: XCTestCase {
    private func request() -> ChatRequest {
        ChatRequest(messages: [.user("hi")], tools: [])
    }

    func testRoutesCompletionToCurrentClient() async throws {
        let router = ModelClientRouter()
        router.setClient(EchoModelClient(content: "first"))

        let first = try await router.complete(request())
        XCTAssertEqual(first.message.content, "first")

        router.setClient(EchoModelClient(content: "second"))

        let second = try await router.complete(request())
        XCTAssertEqual(second.message.content, "second")
    }

    func testThrowsWhenNoClientIsConfigured() async {
        let router = ModelClientRouter()

        do {
            _ = try await router.complete(request())
            XCTFail("Expected notConfigured")
        } catch let error as ModelError {
            XCTAssertEqual(error, .notConfigured)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testStreamFailsWhenNoClientIsConfigured() async {
        let router = ModelClientRouter()

        do {
            for try await _ in router.stream(request()) {}
            XCTFail("Expected notConfigured")
        } catch let error as ModelError {
            XCTAssertEqual(error, .notConfigured)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testStreamUsesCurrentClient() async throws {
        let router = ModelClientRouter()
        router.setClient(EchoModelClient(content: "streamed"))

        var completed: ChatResponse?
        for try await event in router.stream(request()) {
            if case .completed(let response) = event {
                completed = response
            }
        }

        XCTAssertEqual(completed?.message.content, "streamed")
    }
}
