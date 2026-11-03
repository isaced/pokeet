import XCTest
@testable import Pokeet

final class StreamingMarkdownTests: XCTestCase {
    func testTrailingNewlineDoesNotCompleteTheBlock() {
        let chunks = StreamingMarkdownSplitter.split("Hello\n")

        XCTAssertEqual(chunks.stable, "")
        XCTAssertEqual(chunks.tail, "Hello\n")
        XCTAssertNil(chunks.openFence)
    }

    func testBlankLineCompletesTheBlock() {
        let chunks = StreamingMarkdownSplitter.split("Hello\n\nWorld")

        XCTAssertEqual(chunks.stable, "Hello")
        XCTAssertEqual(chunks.tail, "World")
    }

    func testCompletedFenceStaysInStablePrefix() {
        let text = """
        Intro

        ```swift
        let a = 1

        let b = 2
        ```

        After
        """

        let chunks = StreamingMarkdownSplitter.split(text)
        XCTAssertEqual(
            chunks.stable,
            """
            Intro

            ```swift
            let a = 1

            let b = 2
            ```
            """
        )
        XCTAssertEqual(chunks.tail, "After")
        XCTAssertNil(chunks.openFence)
    }

    func testUnclosedFenceIsClosedForRendering() {
        let text = """
        Intro

        ```swift
        let a = 1

        let b = 2
        """

        let chunks = StreamingMarkdownSplitter.split(text)
        XCTAssertEqual(chunks.stable, "Intro")
        XCTAssertEqual(
            chunks.tail,
            """
            ```swift
            let a = 1

            let b = 2
            """
        )
        XCTAssertEqual(chunks.openFence, "```")
        XCTAssertEqual(chunks.tailMarkdown, chunks.tail + "\n```")
    }

    func testLongerFenceIgnoresShorterMarkersInside() {
        let text = """
        ````
        ```
        still code
        ```
        ````

        After
        """

        let chunks = StreamingMarkdownSplitter.split(text)
        XCTAssertEqual(
            chunks.stable,
            """
            ````
            ```
            still code
            ```
            ````
            """
        )
        XCTAssertEqual(chunks.tail, "After")
        XCTAssertNil(chunks.openFence)
    }

    func testASingleTrailingBlankLineCompletesTheBlock() {
        let chunks = StreamingMarkdownSplitter.split("Hello\n\n")

        XCTAssertEqual(chunks.stable, "Hello")
        XCTAssertEqual(chunks.tail, "")
    }
}
