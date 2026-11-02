import Foundation
import Testing
@testable import PokeetCore

struct EditFileToolTests {
    @Test func proposesSingleReplacement() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("README.md", "hello world\n")

        let workspace = FileWorkspace(root: directory.url)
        let output = try await EditFileTool().execute(
            arguments: Data(#"{"path":"README.md","edits":[{"old_text":"world","new_text":"Pokeet"}]}"#.utf8),
            context: ToolContext(workspace: workspace)
        )

        #expect(output.proposals.count == 1)
        let proposal = try #require(output.proposals.first)
        #expect(proposal.kind == .update)
        #expect(proposal.baseContent == "hello world\n")
        #expect(proposal.newContent == "hello Pokeet\n")

        let onDisk = try workspace.read("README.md", maxBytes: 1_000)
        #expect(onDisk == "hello world\n")
    }

    @Test func appliesMultipleDisjointEditsToOriginal() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("file.txt", "one two three\n")

        let workspace = FileWorkspace(root: directory.url)
        let output = try await EditFileTool().execute(
            arguments: Data(#"{"path":"file.txt","edits":[{"old_text":"one","new_text":"ONE"},{"old_text":"three","new_text":"THREE"}]}"#.utf8),
            context: ToolContext(workspace: workspace)
        )

        let proposal = try #require(output.proposals.first)
        #expect(proposal.newContent == "ONE two THREE\n")
    }

    @Test func deletesText() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("file.txt", "one two three\n")

        let workspace = FileWorkspace(root: directory.url)
        let output = try await EditFileTool().execute(
            arguments: Data(#"{"path":"file.txt","edits":[{"old_text":" two","new_text":""}]}"#.utf8),
            context: ToolContext(workspace: workspace)
        )

        let proposal = try #require(output.proposals.first)
        #expect(proposal.newContent == "one three\n")
    }

    @Test func rejectsAmbiguousOldText() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("file.txt", "foo foo\n")

        let workspace = FileWorkspace(root: directory.url)
        do {
            _ = try await EditFileTool().execute(
                arguments: Data(#"{"path":"file.txt","edits":[{"old_text":"foo","new_text":"bar"}]}"#.utf8),
                context: ToolContext(workspace: workspace)
            )
            Issue.record("Expected an ambiguity error")
        } catch is ToolError {
        }
    }

    @Test func rejectsMissingOldText() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("file.txt", "foo\n")

        let workspace = FileWorkspace(root: directory.url)
        do {
            _ = try await EditFileTool().execute(
                arguments: Data(#"{"path":"file.txt","edits":[{"old_text":"missing","new_text":"bar"}]}"#.utf8),
                context: ToolContext(workspace: workspace)
            )
            Issue.record("Expected a missing text error")
        } catch is ToolError {
        }
    }

    @Test func rejectsOverlappingEdits() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("file.txt", "abcd\n")

        let workspace = FileWorkspace(root: directory.url)
        do {
            _ = try await EditFileTool().execute(
                arguments: Data(#"{"path":"file.txt","edits":[{"old_text":"abc","new_text":"X"},{"old_text":"bcd","new_text":"Y"}]}"#.utf8),
                context: ToolContext(workspace: workspace)
            )
            Issue.record("Expected an overlap error")
        } catch is ToolError {
        }
    }

    @Test func identicalReplacementProducesNoProposal() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("file.txt", "foo\n")

        let workspace = FileWorkspace(root: directory.url)
        let output = try await EditFileTool().execute(
            arguments: Data(#"{"path":"file.txt","edits":[{"old_text":"foo","new_text":"foo"}]}"#.utf8),
            context: ToolContext(workspace: workspace)
        )

        #expect(output.proposals.isEmpty)
        #expect(output.content.contains("No changes"))
    }
}
