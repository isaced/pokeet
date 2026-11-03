import XCTest
@testable import Pokeet

final class DiffDocumentTests: XCTestCase {
    private let diff = [
        "diff --git a/Sample.swift b/Sample.swift",
        "index 123..456 100644",
        "--- a/Sample.swift",
        "+++ b/Sample.swift",
        "@@ -1,3 +1,4 @@",
        " struct Demo {",
        "-    let value = 1",
        "+    let value = 2",
        "+    let added = true",
        " }"
    ].joined(separator: "\n")

    func testBuildsOldAndNewSides() {
        let document = DiffDocument(diff + "\n")

        XCTAssertEqual(document.oldText, "struct Demo {\n    let value = 1\n}")
        XCTAssertEqual(document.newText, "struct Demo {\n    let value = 2\n    let added = true\n}")
        XCTAssertEqual(document.oldLineCount, 3)
        XCTAssertEqual(document.newLineCount, 4)
    }

    func testMapsEachLineToItsSide() throws {
        let document = DiffDocument(diff)

        let removed = try XCTUnwrap(document.lines.first { $0.kind == .removed })
        XCTAssertEqual(removed.content, "    let value = 1")
        XCTAssertEqual(removed.oldIndex, 1)
        XCTAssertNil(removed.newIndex)

        let added = document.lines.filter { $0.kind == .added }
        XCTAssertEqual(added.count, 2)
        XCTAssertEqual(added[0].content, "    let value = 2")
        XCTAssertEqual(added[0].newIndex, 1)
        XCTAssertNil(added[0].oldIndex)
        XCTAssertEqual(added[1].newIndex, 2)

        let context = document.lines.filter { $0.kind == .context }
        XCTAssertEqual(context.count, 2)
        XCTAssertEqual(context[0].oldIndex, 0)
        XCTAssertEqual(context[0].newIndex, 0)
        XCTAssertEqual(context[1].oldIndex, 2)
        XCTAssertEqual(context[1].newIndex, 3)
    }

    func testHeaderLikeContentInsideHunkStaysContent() throws {
        let document = DiffDocument([
            "diff --git a/a b/a",
            "--- a/a",
            "+++ b/a",
            "@@ -1 +1 @@",
            "---weird",
            "+ok"
        ].joined(separator: "\n"))

        let removed = try XCTUnwrap(document.lines.first { $0.kind == .removed })
        XCTAssertEqual(removed.content, "--weird")
        XCTAssertEqual(document.oldText, "--weird")
        XCTAssertEqual(document.newText, "ok")
    }

    func testNoNewlineMarkerDoesNotAddContentLines() {
        let document = DiffDocument([
            "diff --git a/a b/a",
            "--- a/a",
            "+++ b/a",
            "@@ -1 +1 @@",
            "-old",
            "\\ No newline at end of file",
            "+new"
        ].joined(separator: "\n"))

        XCTAssertEqual(document.oldLineCount, 1)
        XCTAssertEqual(document.newLineCount, 1)
        XCTAssertEqual(document.oldText, "old")
        XCTAssertEqual(document.newText, "new")
    }

    func testEmptyDiff() {
        let document = DiffDocument("")

        XCTAssertTrue(document.lines.isEmpty)
        XCTAssertTrue(document.oldText.isEmpty)
        XCTAssertTrue(document.newText.isEmpty)
    }
}
