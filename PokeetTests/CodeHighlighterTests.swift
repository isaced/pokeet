import PokeetCore
import UIKit
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

    func testDiffHighlightMapsLinesToEachSide() {
        let highlight = DiffHighlight(
            oldLines: [AttributedString("before")],
            newLines: [AttributedString("after")]
        )

        XCTAssertEqual(
            highlight.line(oldIndex: 0, newIndex: nil).map { String($0.characters) },
            "before"
        )
        XCTAssertEqual(
            highlight.line(oldIndex: nil, newIndex: 0).map { String($0.characters) },
            "after"
        )
        // Context lines exist on both sides; the new side wins.
        XCTAssertEqual(
            highlight.line(oldIndex: 0, newIndex: 0).map { String($0.characters) },
            "after"
        )
        XCTAssertNil(highlight.line(oldIndex: 1, newIndex: 1))
        XCTAssertNil(DiffHighlight.none.line(oldIndex: 0, newIndex: 0))
    }

    func testDiffHighlightCountsLinesLikeTheHighlighter() {
        XCTAssertEqual(DiffHighlight.lineCount(of: ""), 0)
        XCTAssertEqual(DiffHighlight.lineCount(of: "let a = 1"), 1)
        XCTAssertEqual(DiffHighlight.lineCount(of: "let a = 1\n"), 2)
        XCTAssertEqual(DiffHighlight.lineCount(of: "let a = 1\nlet b = 2\n"), 3)
        XCTAssertEqual(DiffHighlight.lineCount(of: "let a = 1\n\n"), 3)
    }

    func testDiffHighlightAlignsWithProposalLineNumbers() async throws {
        let before = "struct Demo {\n    let value = 1\n}\n"
        let after = "struct Demo {\n    /// The stored value.\n    let value = 2\n}\n"
        let diff = LineDiff.compare(old: before, new: after)
        let hunk = try XCTUnwrap(diff.hunks.first)

        let highlight = await DiffHighlight.load(
            path: "Demo.swift",
            oldText: before,
            newText: after,
            isDark: false
        )

        let added = try XCTUnwrap(hunk.lines.first { $0.kind == .added })
        let addedLine = try XCTUnwrap(
            highlight.line(oldIndex: nil, newIndex: added.newNumber.map { $0 - 1 })
        )
        XCTAssertEqual(String(addedLine.characters), "    /// The stored value.")
        // Highlighting is what gives the run a syntax color; plain text has none.
        XCTAssertNotNil(
            NSAttributedString(addedLine).attribute(
                .foregroundColor,
                at: 4,
                effectiveRange: nil
            )
        )

        let removed = try XCTUnwrap(hunk.lines.first { $0.kind == .removed })
        let removedLine = try XCTUnwrap(
            highlight.line(oldIndex: removed.oldNumber.map { $0 - 1 }, newIndex: nil)
        )
        XCTAssertEqual(String(removedLine.characters), "    let value = 1")

        let context = try XCTUnwrap(hunk.lines.first { $0.kind == .context })
        let contextLine = try XCTUnwrap(
            highlight.line(
                oldIndex: context.oldNumber.map { $0 - 1 },
                newIndex: context.newNumber.map { $0 - 1 }
            )
        )
        XCTAssertEqual(String(contextLine.characters), context.text)
    }

    func testDiffHighlightSkipsUnknownLanguages() async {
        let highlight = await DiffHighlight.load(
            path: "notes.txt",
            oldText: "one\n",
            newText: "one\ntwo\n",
            isDark: false
        )

        XCTAssertNil(highlight.oldLines)
        XCTAssertNil(highlight.newLines)
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
