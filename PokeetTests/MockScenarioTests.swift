import XCTest
@testable import Pokeet
import PokeetCore

final class MockScenarioTests: XCTestCase {
    func testImageScenarioReturnsReadImage() async throws {
        let client = MockModelClient()
        let response = try await client.complete(
            ChatRequest(messages: [.user("image test")], tools: ToolRegistry.standard.schemas)
        )
        XCTAssertEqual(response.message.toolCalls?.first?.name, "read_image")
        XCTAssertEqual(response.message.toolCalls?.first?.arguments, #"{"path":"shot.png"}"#)
    }

    func testScriptScenarioReturnsRunScript() async throws {
        let client = MockModelClient()
        let response = try await client.complete(
            ChatRequest(messages: [.user("script test")], tools: ToolRegistry.standard.schemas)
        )
        XCTAssertEqual(response.message.toolCalls?.first?.name, "run_script")
    }
}
