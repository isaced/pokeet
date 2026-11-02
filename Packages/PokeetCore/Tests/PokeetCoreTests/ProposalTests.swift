import Foundation
import Testing
@testable import PokeetCore

struct ProposalTests {
    @Test func appliesFullUpdate() throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let workspace = FileWorkspace(root: directory.url)
        try workspace.write("README.md", content: "old\n")

        let proposal = FileProposal(
            path: "README.md",
            kind: .update,
            baseContent: "old\n",
            newContent: "new\n",
            diff: LineDiff.compare(old: "old\n", new: "new\n")
        )

        let application = try ProposalApplier.apply(
            proposal,
            decision: .acceptAll(proposalID: proposal.id),
            in: workspace
        )

        #expect(application.didWrite)
        #expect(application.acceptedHunkCount == application.totalHunkCount)
        let content = try workspace.read("README.md", maxBytes: 1000)
        #expect(content == "new\n")
    }

    @Test func appliesOnlyAcceptedHunks() throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let workspace = FileWorkspace(root: directory.url)
        let oldLines = (1...30).map(String.init)
        var newLines = oldLines
        newLines[1] = "changed-2"
        newLines[24] = "changed-25"
        let base = oldLines.joined(separator: "\n") + "\n"
        let new = newLines.joined(separator: "\n") + "\n"
        try workspace.write("file.txt", content: base)

        let diff = LineDiff.compare(old: base, new: new)
        #expect(diff.hunks.count == 2)

        let proposal = FileProposal(
            path: "file.txt",
            kind: .update,
            baseContent: base,
            newContent: new,
            diff: diff
        )

        let application = try ProposalApplier.apply(
            proposal,
            decision: .acceptHunks(
                proposalID: proposal.id,
                hunkIDs: [diff.hunks[0].id],
                note: "Keep the second change as-is"
            ),
            in: workspace
        )

        #expect(application.didWrite)
        #expect(application.isPartial)
        #expect(application.acceptedHunkCount == 1)
        #expect(application.totalHunkCount == 2)

        let content = try workspace.read("file.txt", maxBytes: 10_000)
        #expect(content.contains("\nchanged-2\n"))
        #expect(!content.contains("changed-25"))
        #expect(content.contains("\n25\n"))
    }

    @Test func rejectedUpdateDoesNotWrite() throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let workspace = FileWorkspace(root: directory.url)
        try workspace.write("README.md", content: "old\n")

        let proposal = FileProposal(
            path: "README.md",
            kind: .update,
            baseContent: "old\n",
            newContent: "new\n",
            diff: LineDiff.compare(old: "old\n", new: "new\n")
        )

        let application = try ProposalApplier.apply(
            proposal,
            decision: .reject(proposalID: proposal.id, note: "Not now"),
            in: workspace
        )

        #expect(!application.didWrite)
        let content = try workspace.read("README.md", maxBytes: 1000)
        #expect(content == "old\n")
    }

    @Test func rejectsStaleUpdate() throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let workspace = FileWorkspace(root: directory.url)
        try workspace.write("README.md", content: "old\n")

        let proposal = FileProposal(
            path: "README.md",
            kind: .update,
            baseContent: "old\n",
            newContent: "new\n",
            diff: LineDiff.compare(old: "old\n", new: "new\n")
        )

        try directory.write("README.md", "changed-on-disk\n")

        #expect(throws: WorkspaceError.staleContent("README.md")) {
            try ProposalApplier.apply(
                proposal,
                decision: .acceptAll(proposalID: proposal.id),
                in: workspace
            )
        }
        let content = try workspace.read("README.md", maxBytes: 1000)
        #expect(content == "changed-on-disk\n")
    }

    @Test func createsNewFile() throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let workspace = FileWorkspace(root: directory.url)
        let proposal = FileProposal(
            path: "Sources/new.swift",
            kind: .create,
            baseContent: nil,
            newContent: "let x = 1\n",
            diff: LineDiff.compare(old: nil, new: "let x = 1\n")
        )

        let application = try ProposalApplier.apply(
            proposal,
            decision: .acceptAll(proposalID: proposal.id),
            in: workspace
        )

        #expect(application.didWrite)
        let content = try workspace.read("Sources/new.swift", maxBytes: 1000)
        #expect(content == "let x = 1\n")
    }

    @Test func createsEmptyFile() throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let workspace = FileWorkspace(root: directory.url)
        let proposal = FileProposal(
            path: "empty.txt",
            kind: .create,
            baseContent: nil,
            newContent: "",
            diff: LineDiff.compare(old: nil, new: "")
        )

        let application = try ProposalApplier.apply(
            proposal,
            decision: .acceptAll(proposalID: proposal.id),
            in: workspace
        )

        #expect(application.didWrite)
        #expect(application.totalHunkCount == 0)
        let content = try workspace.read("empty.txt", maxBytes: 1000)
        #expect(content == "")
    }

    @Test func deletesFileAfterApproval() throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let workspace = FileWorkspace(root: directory.url)
        try workspace.write("temp.txt", content: "old\n")

        let proposal = FileProposal(
            path: "temp.txt",
            kind: .delete,
            baseContent: "old\n",
            newContent: "",
            diff: LineDiff.compare(old: "old\n", new: "")
        )

        let application = try ProposalApplier.apply(
            proposal,
            decision: .acceptAll(proposalID: proposal.id),
            in: workspace
        )

        #expect(application.didWrite)
        #expect(!workspace.exists("temp.txt"))
    }

    @Test func movesFileAfterApproval() throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let workspace = FileWorkspace(root: directory.url)
        try workspace.write("old/name.txt", content: "content\n")

        let proposal = FileProposal(
            path: "old/name.txt",
            kind: .move,
            destinationPath: "new/name.txt",
            baseContent: "content\n",
            newContent: "content\n",
            diff: .empty
        )

        let application = try ProposalApplier.apply(
            proposal,
            decision: .acceptAll(proposalID: proposal.id),
            in: workspace
        )

        #expect(application.didWrite)
        #expect(!workspace.exists("old/name.txt"))
        #expect(try workspace.read("new/name.txt", maxBytes: 100) == "content\n")
    }

    @Test func moveRejectsStaleSource() throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let workspace = FileWorkspace(root: directory.url)
        try workspace.write("old.txt", content: "original\n")

        let proposal = FileProposal(
            path: "old.txt",
            kind: .move,
            destinationPath: "new.txt",
            baseContent: "original\n",
            newContent: "original\n",
            diff: .empty
        )

        try directory.write("old.txt", "changed\n")

        #expect(throws: WorkspaceError.staleContent("old.txt")) {
            try ProposalApplier.apply(
                proposal,
                decision: .acceptAll(proposalID: proposal.id),
                in: workspace
            )
        }
        #expect(!workspace.exists("new.txt"))
    }

    @Test func createFailsWhenFileExists() throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let workspace = FileWorkspace(root: directory.url)
        try workspace.write("Sources/new.swift", content: "existing\n")

        let proposal = FileProposal(
            path: "Sources/new.swift",
            kind: .create,
            baseContent: nil,
            newContent: "new\n",
            diff: LineDiff.compare(old: nil, new: "new\n")
        )

        #expect(throws: WorkspaceError.staleContent("Sources/new.swift")) {
            try ProposalApplier.apply(
                proposal,
                decision: .acceptAll(proposalID: proposal.id),
                in: workspace
            )
        }
    }
}
