import Foundation
import Testing
@testable import PokeetCore

struct ProposalTests {
    @Test func appliesUpdate() throws {
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

        try ProposalApplier.apply(proposal, in: workspace)
        #expect(try workspace.read("README.md", maxBytes: 1000) == "new\n")
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
            try ProposalApplier.apply(proposal, in: workspace)
        }
        #expect(try workspace.read("README.md", maxBytes: 1000) == "changed-on-disk\n")
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

        try ProposalApplier.apply(proposal, in: workspace)
        #expect(try workspace.read("Sources/new.swift", maxBytes: 1000) == "let x = 1\n")
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
            try ProposalApplier.apply(proposal, in: workspace)
        }
    }
}
