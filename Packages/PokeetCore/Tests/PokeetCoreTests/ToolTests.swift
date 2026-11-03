import Foundation
import Testing
@testable import PokeetCore

struct ToolTests {
    @Test func listsFiles() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("Sources/main.swift", "print(1)\n")

        let workspace = FileWorkspace(root: directory.url)
        let output = try await ListFilesTool().execute(
            arguments: Data(#"{"recursive":true}"#.utf8),
            context: ToolContext(workspace: workspace)
        )

        #expect(output.content.contains("Sources/main.swift"))
        #expect(output.proposals.isEmpty)
    }

    @Test func readsNumberedLines() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("hello.txt", "one\ntwo\n")

        let workspace = FileWorkspace(root: directory.url)
        let output = try await ReadFileTool().execute(
            arguments: Data(#"{"path":"hello.txt"}"#.utf8),
            context: ToolContext(workspace: workspace)
        )

        #expect(output.content.contains("1\tone"))
        #expect(output.content.contains("2\ttwo"))
    }

    @Test func writeFileProposesWithoutWriting() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("README.md", "old\n")

        let workspace = FileWorkspace(root: directory.url)
        let output = try await WriteFileTool().execute(
            arguments: Data(#"{"path":"README.md","content":"new\n","reason":"test"}"#.utf8),
            context: ToolContext(workspace: workspace)
        )

        #expect(output.proposals.count == 1)
        #expect(output.proposals[0].kind == .update)
        #expect(output.proposals[0].addedLines == 1)
        #expect(output.proposals[0].removedLines == 1)

        let unchanged = try workspace.read("README.md", maxBytes: 1000)
        #expect(unchanged == "old\n")
    }

    @Test func writeFileReportsIdenticalContent() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("README.md", "same\n")

        let workspace = FileWorkspace(root: directory.url)
        let output = try await WriteFileTool().execute(
            arguments: Data(#"{"path":"README.md","content":"same\n"}"#.utf8),
            context: ToolContext(workspace: workspace)
        )

        #expect(output.proposals.isEmpty)
        #expect(output.content.contains("identical"))
    }

    @Test func writeFileRejectsPathEscape() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let workspace = FileWorkspace(root: directory.url)
        do {
            _ = try await WriteFileTool().execute(
                arguments: Data(#"{"path":"../escape.txt","content":"x"}"#.utf8),
                context: ToolContext(workspace: workspace)
            )
            Issue.record("Expected a path escape error")
        } catch is ToolError {
        }
    }

    @Test func readsLineRange() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("lines.txt", "one\ntwo\nthree\nfour\nfive\n")

        let workspace = FileWorkspace(root: directory.url)
        let output = try await ReadFileTool().execute(
            arguments: Data(#"{"path":"lines.txt","offset":2,"limit":2}"#.utf8),
            context: ToolContext(workspace: workspace)
        )

        #expect(output.content.contains("2\ttwo"))
        #expect(output.content.contains("3\tthree"))
        #expect(!output.content.contains("1\tone"))
        #expect(!output.content.contains("4\tfour"))
        #expect(output.content.contains("showing lines 2-3 of 5"))
    }

    @Test func reportsOffsetBeyondEnd() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("lines.txt", "one\ntwo\n")

        let workspace = FileWorkspace(root: directory.url)
        let output = try await ReadFileTool().execute(
            arguments: Data(#"{"path":"lines.txt","offset":10}"#.utf8),
            context: ToolContext(workspace: workspace)
        )

        #expect(output.content.contains("beyond the end"))
    }

    @Test func deleteFileProposesWithoutDeleting() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("temp.txt", "bye\n")

        let workspace = FileWorkspace(root: directory.url)
        let output = try await DeleteFileTool().execute(
            arguments: Data(#"{"path":"temp.txt"}"#.utf8),
            context: ToolContext(workspace: workspace)
        )

        #expect(output.proposals.count == 1)
        #expect(output.proposals[0].kind == .delete)
        #expect(output.proposals[0].removedLines == 1)
        #expect(workspace.exists("temp.txt"))
    }

    @Test func moveFileProposesWithoutMoving() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("old.txt", "content\n")

        let workspace = FileWorkspace(root: directory.url)
        let output = try await MoveFileTool().execute(
            arguments: Data(#"{"from":"old.txt","to":"new/old.txt"}"#.utf8),
            context: ToolContext(workspace: workspace)
        )

        #expect(output.proposals.count == 1)
        #expect(output.proposals[0].kind == .move)
        #expect(output.proposals[0].destinationPath == "new/old.txt")
        #expect(workspace.exists("old.txt"))
        #expect(!workspace.exists("new/old.txt"))
    }

    @Test func moveFileRejectsExistingDestination() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("a.txt", "a\n")
        try directory.write("b.txt", "b\n")

        let workspace = FileWorkspace(root: directory.url)
        do {
            _ = try await MoveFileTool().execute(
                arguments: Data(#"{"from":"a.txt","to":"b.txt"}"#.utf8),
                context: ToolContext(workspace: workspace)
            )
            Issue.record("Expected a destination conflict")
        } catch is ToolError {
        }
    }

    @Test func standardRegistryIncludesCodingTools() {
        let names = Set(ToolRegistry.standard.schemas.map(\.name))

        #expect(names == [
            "list_files",
            "read_file",
            "write_file",
            "edit_file",
            "delete_file",
            "move_file",
            "grep",
            "find",
            "run_script",
            "git_status",
            "git_diff",
            "git_log",
            "http_request",
            "submit_plan"
        ])
    }
}
