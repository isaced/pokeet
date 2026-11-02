import Foundation
import Testing
@testable import PokeetCore

struct LineDiffApplyTests {
    private func makeFixture(lineCount: Int = 30) -> (base: String, new: String, diff: FileDiff) {
        let oldLines = (1...lineCount).map(String.init)
        var newLines = oldLines
        newLines[1] = "changed-2"
        newLines[lineCount - 2] = "changed-\(lineCount - 1)"

        let base = oldLines.joined(separator: "\n") + "\n"
        let new = newLines.joined(separator: "\n") + "\n"
        return (base, new, LineDiff.compare(old: base, new: new))
    }

    @Test func acceptingOneHunkLeavesTheOtherUnchanged() throws {
        let fixture = makeFixture()
        #expect(fixture.diff.hunks.count == 2)

        let result = try LineDiff.applying(
            base: fixture.base,
            diff: fixture.diff,
            acceptedHunkIDs: [fixture.diff.hunks[0].id],
            newContent: fixture.new
        )

        #expect(result.contains("\nchanged-2\n"))
        #expect(!result.contains("changed-29"))
        #expect(result.hasSuffix("30\n"))
        #expect(result.hasSuffix("\n"))
    }

    @Test func acceptingAllHunksReturnsTheExactNewContent() throws {
        let fixture = makeFixture()
        let result = try LineDiff.applying(
            base: fixture.base,
            diff: fixture.diff,
            acceptedHunkIDs: Set(fixture.diff.hunks.map(\.id)),
            newContent: fixture.new
        )
        #expect(result == fixture.new)
    }

    @Test func acceptingNoHunksReturnsTheBase() throws {
        let fixture = makeFixture()
        let result = try LineDiff.applying(
            base: fixture.base,
            diff: fixture.diff,
            acceptedHunkIDs: [],
            newContent: fixture.new
        )
        #expect(result == fixture.base)
    }

    @Test func endHunkControlsTrailingNewline() throws {
        let oldLines = (1...30).map(String.init)
        var newLines = oldLines
        newLines[1] = "changed-2"
        newLines[28] = "changed-29"

        let base = oldLines.joined(separator: "\n")
        let new = newLines.joined(separator: "\n") + "\n"
        let diff = LineDiff.compare(old: base, new: new)
        #expect(diff.hunks.count == 2)

        let firstOnly = try LineDiff.applying(
            base: base,
            diff: diff,
            acceptedHunkIDs: [diff.hunks[0].id],
            newContent: new
        )
        #expect(!firstOnly.hasSuffix("\n"))
        #expect(firstOnly.contains("\nchanged-2\n"))
        #expect(!firstOnly.contains("changed-29"))

        let lastOnly = try LineDiff.applying(
            base: base,
            diff: diff,
            acceptedHunkIDs: [diff.hunks[1].id],
            newContent: new
        )
        #expect(lastOnly.hasSuffix("\n"))
        #expect(!lastOnly.contains("\nchanged-2\n"))
        #expect(lastOnly.contains("changed-29"))
    }

    @Test func rejectsInconsistentBase() throws {
        let fixture = makeFixture()
        let wrongBase = "1-changed\n" + String(fixture.base.dropFirst(2))

        #expect(throws: LineDiffError.inconsistentHunk(fixture.diff.hunks[0].header)) {
            try LineDiff.applying(
                base: wrongBase,
                diff: fixture.diff,
                acceptedHunkIDs: [fixture.diff.hunks[0].id],
                newContent: fixture.new
            )
        }
    }

    @Test func ignoresUnknownHunkIDs() throws {
        let fixture = makeFixture()
        let result = try LineDiff.applying(
            base: fixture.base,
            diff: fixture.diff,
            acceptedHunkIDs: ["unknown"],
            newContent: fixture.new
        )
        #expect(result == fixture.base)
    }
}
