import Testing
@testable import PokeetCore

struct LineDiffTests {
    @Test func replacementProducesOneHunk() {
        let diff = LineDiff.compare(old: "a\nb\nc\n", new: "a\nx\nc\n")

        #expect(diff.hunks.count == 1)
        #expect(diff.addedLines == 1)
        #expect(diff.removedLines == 1)
        #expect(diff.hunks[0].lines.map(\.kind) == [.context, .removed, .added, .context])
    }

    @Test func insertion() {
        let diff = LineDiff.compare(old: "a\nc\n", new: "a\nb\nc\n")

        #expect(diff.addedLines == 1)
        #expect(diff.removedLines == 0)
        #expect(diff.hunks[0].lines.map(\.text) == ["a", "b", "c"])
    }

    @Test func deletion() {
        let diff = LineDiff.compare(old: "a\nb\nc\n", new: "a\nc\n")

        #expect(diff.addedLines == 0)
        #expect(diff.removedLines == 1)
        #expect(diff.hunks[0].lines.map(\.kind) == [.context, .removed, .context])
    }

    @Test func createdFileIsAllAdded() {
        let diff = LineDiff.compare(old: nil, new: "one\ntwo\n")

        #expect(diff.hunks.count == 1)
        #expect(diff.addedLines == 2)
        #expect(diff.removedLines == 0)
        #expect(diff.hunks[0].oldCount == 0)
        #expect(diff.hunks[0].lines.allSatisfy { $0.kind == .added })
    }

    @Test func noChanges() {
        let diff = LineDiff.compare(old: "a\nb\n", new: "a\nb\n")
        #expect(diff.isEmpty)
        #expect(diff.addedLines == 0)
        #expect(diff.removedLines == 0)
    }

    @Test func emptyNewFile() {
        let diff = LineDiff.compare(old: "a\n", new: "")
        #expect(diff.removedLines == 1)
        #expect(diff.addedLines == 0)
        #expect(diff.hunks[0].newCount == 0)
    }

    @Test func distantChangesProduceSeparateHunks() {
        let oldLines = (1...30).map(String.init)
        var newLines = oldLines
        newLines[1] = "changed-2"
        newLines[24] = "changed-25"

        let diff = LineDiff.compare(
            old: oldLines.joined(separator: "\n") + "\n",
            new: newLines.joined(separator: "\n") + "\n"
        )

        #expect(diff.hunks.count == 2)
        #expect(diff.addedLines == 2)
        #expect(diff.removedLines == 2)
    }

    @Test func nearbyChangesMergeIntoOneHunk() {
        let oldLines = (1...20).map(String.init)
        var newLines = oldLines
        newLines[5] = "changed-6"
        newLines[9] = "changed-10"

        let diff = LineDiff.compare(
            old: oldLines.joined(separator: "\n") + "\n",
            new: newLines.joined(separator: "\n") + "\n"
        )

        #expect(diff.hunks.count == 1)
    }

    @Test func largeFilesFallBackToFullReplacement() {
        let oldLines = (1...LineDiff.largeFileLineLimit + 1).map(String.init)
        var newLines = oldLines
        newLines[0] = "changed"

        let diff = LineDiff.compare(
            old: oldLines.joined(separator: "\n") + "\n",
            new: newLines.joined(separator: "\n") + "\n"
        )

        #expect(diff.hunks.count == 1)
        #expect(diff.addedLines == newLines.count)
        #expect(diff.removedLines == oldLines.count)
    }
}
