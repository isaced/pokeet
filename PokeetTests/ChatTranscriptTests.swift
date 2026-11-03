import XCTest
@testable import Pokeet

final class ChatTranscriptTests: XCTestCase {
    private func bubble(
        _ role: ChatViewModel.Bubble.Role,
        _ text: String,
        isStreaming: Bool = false,
        reasoningDuration: TimeInterval? = nil,
        runDuration: TimeInterval? = nil
    ) -> ChatViewModel.Bubble {
        ChatViewModel.Bubble(
            role: role,
            text: text,
            isStreaming: isStreaming,
            reasoningDuration: reasoningDuration,
            runDuration: runDuration
        )
    }

    func testFinishedTurnCollapsesToHeaderAndFinalAnswer() {
        let bubbles = [
            bubble(.user, "hi"),
            bubble(.reasoning, "thinking", reasoningDuration: 2),
            bubble(.tool, "read_file · Sources/main.swift"),
            bubble(.assistant, "answer", runDuration: 12)
        ]

        let rows = ChatTranscriptBuilder.rows(
            from: bubbles[...],
            isRunning: false,
            overrides: [:]
        )

        XCTAssertEqual(rows.count, 3)
        guard case .turnHeader(let header) = rows[1] else {
            return XCTFail("Expected a turn header")
        }
        XCTAssertFalse(header.isExpanded)
        XCTAssertFalse(header.isRunning)
        XCTAssertEqual(header.stepCount, 2)
        XCTAssertEqual(header.duration, 12)
        XCTAssertTrue(header.hasFinalAnswer)

        guard case .bubble(let last, .normal) = rows[2] else {
            return XCTFail("Expected the final answer")
        }
        XCTAssertEqual(last.text, "answer")
    }

    func testExpandedTurnKeepsEveryTraceStep() {
        let bubbles = [
            bubble(.user, "hi"),
            bubble(.reasoning, "thinking"),
            bubble(.assistant, "midpoint"),
            bubble(.tool, "read_file · Sources/main.swift"),
            bubble(.assistant, "answer")
        ]

        let rows = ChatTranscriptBuilder.rows(
            from: bubbles[...],
            isRunning: false,
            overrides: [bubbles[1].id: true]
        )

        XCTAssertEqual(rows.count, 6)
        guard case .turnHeader(let header) = rows[1] else {
            return XCTFail("Expected a turn header")
        }
        XCTAssertTrue(header.isExpanded)
        XCTAssertEqual(header.stepCount, 3)

        guard case .bubble(_, .traceText) = rows[3] else {
            return XCTFail("Expected the intermediate answer inside the trace")
        }
    }

    func testRunningTurnStaysExpandedAndHidesFinalAnswerUntilItArrives() {
        let bubbles = [
            bubble(.user, "hi"),
            bubble(.reasoning, "thinking", isStreaming: true),
            bubble(.tool, "read_file · Sources/main.swift", isStreaming: true)
        ]

        let rows = ChatTranscriptBuilder.rows(
            from: bubbles[...],
            isRunning: true,
            overrides: [:]
        )

        XCTAssertEqual(rows.count, 4)
        guard case .turnHeader(let header) = rows[1] else {
            return XCTFail("Expected a turn header")
        }
        XCTAssertTrue(header.isExpanded)
        XCTAssertTrue(header.isRunning)
        XCTAssertFalse(header.hasFinalAnswer)
        XCTAssertEqual(header.stepCount, 2)
    }

    func testNoticesRemainVisibleInsideCollapsedTurn() {
        let bubbles = [
            bubble(.user, "hi"),
            bubble(.notice, "Context summarized."),
            bubble(.reasoning, "thinking"),
            bubble(.assistant, "answer")
        ]

        let rows = ChatTranscriptBuilder.rows(
            from: bubbles[...],
            isRunning: false,
            overrides: [:]
        )

        XCTAssertEqual(rows.count, 4)
        guard case .bubble(let notice, .notice) = rows[2] else {
            return XCTFail("Expected the notice to stay visible")
        }
        XCTAssertEqual(notice.text, "Context summarized.")
    }

    func testSimpleAnswerHasNoHeader() {
        let bubbles = [
            bubble(.user, "hi"),
            bubble(.assistant, "answer")
        ]

        let rows = ChatTranscriptBuilder.rows(
            from: bubbles[...],
            isRunning: false,
            overrides: [:]
        )

        XCTAssertEqual(rows.count, 2)
        guard case .bubble(_, .normal) = rows[1] else {
            return XCTFail("Expected a plain answer")
        }
    }
}
