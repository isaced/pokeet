import XCTest
@testable import Pokeet

final class StreamBufferTests: XCTestCase {
    func testDrainsAssistantAndReasoningIndependently() {
        var buffer = StreamBuffer()
        buffer.appendAssistant("Hel")
        buffer.appendReasoning("Think")
        buffer.appendAssistant("lo")

        XCTAssertFalse(buffer.isEmpty)
        XCTAssertEqual(buffer.drainAssistant(), "Hello")
        XCTAssertEqual(buffer.drainReasoning(), "Think")
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.drainAssistant(), "")
    }

    func testClearDropsPendingText() {
        var buffer = StreamBuffer()
        buffer.appendAssistant("partial")
        buffer.appendReasoning("thinking")

        buffer.clear()

        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.drainAssistant(), "")
        XCTAssertEqual(buffer.drainReasoning(), "")
    }
}
