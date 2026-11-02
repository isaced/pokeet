import Foundation
import Testing
@testable import PokeetCore

struct FindToolTests {
    private func makeWorkspace() throws -> (TestDirectory, FileWorkspace) {
        let directory = try TestDirectory()
        try directory.write("Sources/A.swift", "let a = 1\n")
        try directory.write("Sources/Nested/B.swift", "let b = 2\n")
        try directory.write("tests/Spec.swift", "let spec = 3\n")
        try directory.write("src/Nested/C.swift", "let c = 4\n")
        try directory.write("README.md", "# Readme\n")
        return (directory, FileWorkspace(root: directory.url))
    }

    @Test func matchesBasenamePatternRecursively() async throws {
        let (directory, workspace) = try makeWorkspace()
        defer { directory.cleanup() }

        let output = try await FindTool().execute(
            arguments: Data(#"{"pattern":"*.swift"}"#.utf8),
            context: ToolContext(workspace: workspace)
        )

        #expect(output.content.contains("Sources/A.swift"))
        #expect(output.content.contains("Sources/Nested/B.swift"))
        #expect(output.content.contains("tests/Spec.swift"))
        #expect(output.content.contains("src/Nested/C.swift"))
        #expect(!output.content.contains("README.md"))
    }

    @Test func matchesAnchoredGlob() async throws {
        let (directory, workspace) = try makeWorkspace()
        defer { directory.cleanup() }

        let output = try await FindTool().execute(
            arguments: Data(#"{"pattern":"src/**/*.swift"}"#.utf8),
            context: ToolContext(workspace: workspace)
        )

        #expect(output.content.contains("src/Nested/C.swift"))
        #expect(!output.content.contains("Sources/A.swift"))
    }

    @Test func limitsSearchToPath() async throws {
        let (directory, workspace) = try makeWorkspace()
        defer { directory.cleanup() }

        let output = try await FindTool().execute(
            arguments: Data(#"{"pattern":"*.swift","path":"Sources"}"#.utf8),
            context: ToolContext(workspace: workspace)
        )

        #expect(output.content.contains("Sources/A.swift"))
        #expect(output.content.contains("Sources/Nested/B.swift"))
        #expect(!output.content.contains("tests/Spec.swift"))
    }

    @Test func respectsLimit() async throws {
        let (directory, workspace) = try makeWorkspace()
        defer { directory.cleanup() }

        let output = try await FindTool().execute(
            arguments: Data(#"{"pattern":"*.swift","limit":1}"#.utf8),
            context: ToolContext(workspace: workspace)
        )

        #expect(output.content.contains("limit reached"))
    }

    @Test func returnsNoFilesMessage() async throws {
        let (directory, workspace) = try makeWorkspace()
        defer { directory.cleanup() }

        let output = try await FindTool().execute(
            arguments: Data(#"{"pattern":"*.ruby"}"#.utf8),
            context: ToolContext(workspace: workspace)
        )

        #expect(output.content == "No files found.")
    }
}
