import XCTest
@testable import Pokeet

final class CodeHighlighterTests: XCTestCase {
    func testLanguageAliases() {
        XCTAssertEqual(CodeLanguage.alias(for: "Sources/App.swift"), "swift")
        XCTAssertEqual(CodeLanguage.alias(for: "web/app.tsx"), "typescript")
        XCTAssertEqual(CodeLanguage.alias(for: "config.yml"), "yaml")
        XCTAssertEqual(CodeLanguage.alias(for: "project.yml"), "yaml")
        XCTAssertEqual(CodeLanguage.alias(for: "Makefile"), "makefile")
        XCTAssertEqual(CodeLanguage.alias(for: "Package.resolved"), "json")
        XCTAssertNil(CodeLanguage.alias(for: "notes.txt"))
    }

    func testSwiftHighlightPreservesLinesAndIndentation() async throws {
        let text = "struct Demo {\n    let value = 1\n}\n"
        let lines = await CodeHighlighter.highlight(
            text: text,
            language: "swift",
            isDark: false,
            expectedLineCount: 4
        )

        let unwrapped = try XCTUnwrap(lines)
        XCTAssertEqual(unwrapped.count, 4)
        XCTAssertEqual(
            unwrapped.map { String($0.characters) },
            ["struct Demo {", "    let value = 1", "}", ""]
        )
    }

    func testLeadingBlankLinesAndIndentationArePreserved() async throws {
        let text = "\n\n  let value = 1\n"
        let lines = await CodeHighlighter.highlight(
            text: text,
            language: "swift",
            isDark: true,
            expectedLineCount: 4
        )

        let unwrapped = try XCTUnwrap(lines)
        XCTAssertEqual(
            unwrapped.map { String($0.characters) },
            ["", "", "  let value = 1", ""]
        )
    }

    func testLargeFilesSkipHighlighting() async {
        let text = String(repeating: "let value = 1\n", count: 12_001)
        let lines = await CodeHighlighter.highlight(
            text: text,
            language: "swift",
            isDark: false,
            expectedLineCount: 12_002
        )

        XCTAssertNil(lines)
    }
}
