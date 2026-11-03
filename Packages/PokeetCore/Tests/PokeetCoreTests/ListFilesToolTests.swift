import Foundation
import Testing
@testable import PokeetCore

struct ListFilesToolTests {
    @Test func listsTheRootWithoutAPath() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("Package.swift", "// manifest\n")
        try directory.write("Sources/App.swift", "// app\n")

        let output = try await list(#"{}"#, in: directory)

        #expect(output.contains("Package.swift"))
        #expect(output.contains("Sources/"))
    }

    /// Models spell the repository root as "." all the time; it used to answer
    /// with "Invalid path: ." and waste a step.
    @Test func listsTheRootWhenPathIsDot() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("Package.swift", "// manifest\n")
        try directory.write("Sources/App.swift", "// app\n")

        let dot = try await list(#"{"path":"."}"#, in: directory)
        let empty = try await list(#"{}"#, in: directory)

        #expect(dot == empty)
        #expect(dot.contains("Sources/"))
    }

    @Test func listsTheRootRecursivelyWhenPathIsDot() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("Sources/App.swift", "// app\n")

        let output = try await list(#"{"path":".","recursive":true}"#, in: directory)

        #expect(output.contains("Sources/App.swift"))
    }

    @Test func stillRejectsParentTraversal() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        await #expect(throws: WorkspaceError.self) {
            _ = try await list(#"{"path":".."}"#, in: directory)
        }
    }

    private func list(_ arguments: String, in directory: TestDirectory) async throws -> String {
        let output = try await ListFilesTool().execute(
            arguments: Data(arguments.utf8),
            context: ToolContext(workspace: FileWorkspace(root: directory.url))
        )
        return output.content
    }
}
