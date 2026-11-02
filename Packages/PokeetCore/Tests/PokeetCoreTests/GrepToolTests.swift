import Foundation
import Testing
@testable import PokeetCore

struct GrepToolTests {
    private func makeWorkspace() throws -> (TestDirectory, FileWorkspace) {
        let directory = try TestDirectory()
        try directory.write("Sources/A.swift", "let foo = 1\nlet bar = 2\n")
        try directory.write("Sources/B.swift", "// FOO comment\n")
        try directory.write("README.md", "foo in readme\n")
        try directory.write(".git/config", "foo\n")
        try directory.write("node_modules/pkg/index.js", "foo\n")
        try Data([0x00, 0x66, 0x6f, 0x6f]).write(
            to: directory.url.appending(path: "binary.bin")
        )
        return (directory, FileWorkspace(root: directory.url))
    }

    @Test func findsMatchesAndSkipsBinaryAndVendoredDirectories() async throws {
        let (directory, workspace) = try makeWorkspace()
        defer { directory.cleanup() }

        let output = try await GrepTool().execute(
            arguments: Data(#"{"pattern":"foo"}"#.utf8),
            context: ToolContext(workspace: workspace)
        )

        #expect(output.content.contains("Sources/A.swift:1:"))
        #expect(output.content.contains("README.md:1:"))
        #expect(!output.content.contains("Sources/B.swift"))
        #expect(!output.content.contains("binary.bin"))
        #expect(!output.content.contains(".git/"))
        #expect(!output.content.contains("node_modules"))
    }

    @Test func supportsCaseInsensitiveSearch() async throws {
        let (directory, workspace) = try makeWorkspace()
        defer { directory.cleanup() }

        let output = try await GrepTool().execute(
            arguments: Data(#"{"pattern":"foo","ignore_case":true}"#.utf8),
            context: ToolContext(workspace: workspace)
        )

        #expect(output.content.contains("Sources/B.swift:1:"))
    }

    @Test func filtersByGlob() async throws {
        let (directory, workspace) = try makeWorkspace()
        defer { directory.cleanup() }

        let output = try await GrepTool().execute(
            arguments: Data(#"{"pattern":"foo","ignore_case":true,"glob":"*.swift"}"#.utf8),
            context: ToolContext(workspace: workspace)
        )

        #expect(output.content.contains("Sources/A.swift"))
        #expect(output.content.contains("Sources/B.swift"))
        #expect(!output.content.contains("README.md"))
    }

    @Test func limitsSearchToPath() async throws {
        let (directory, workspace) = try makeWorkspace()
        defer { directory.cleanup() }

        let output = try await GrepTool().execute(
            arguments: Data(#"{"pattern":"foo","ignore_case":true,"path":"Sources"}"#.utf8),
            context: ToolContext(workspace: workspace)
        )

        #expect(output.content.contains("Sources/A.swift"))
        #expect(output.content.contains("Sources/B.swift"))
        #expect(!output.content.contains("README.md"))
    }

    @Test func searchesSingleFile() async throws {
        let (directory, workspace) = try makeWorkspace()
        defer { directory.cleanup() }

        let output = try await GrepTool().execute(
            arguments: Data(#"{"pattern":"foo","path":"Sources/A.swift"}"#.utf8),
            context: ToolContext(workspace: workspace)
        )

        #expect(output.content.contains("Sources/A.swift:1:"))
        #expect(!output.content.contains("README.md"))
    }

    @Test func supportsLiteralSearch() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("special.txt", "foo.bar\nfooXbar\n")
        let workspace = FileWorkspace(root: directory.url)

        let literal = try await GrepTool().execute(
            arguments: Data(#"{"pattern":"foo.bar","literal":true}"#.utf8),
            context: ToolContext(workspace: workspace)
        )
        #expect(literal.content.contains("special.txt:1:"))
        #expect(!literal.content.contains("special.txt:2:"))

        let regex = try await GrepTool().execute(
            arguments: Data(#"{"pattern":"foo.bar"}"#.utf8),
            context: ToolContext(workspace: workspace)
        )
        #expect(regex.content.contains("special.txt:1:"))
        #expect(regex.content.contains("special.txt:2:"))
    }

    @Test func includesContextLines() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("context.txt", "one\ntwo\nfoo\nfour\nfive\n")
        let workspace = FileWorkspace(root: directory.url)

        let output = try await GrepTool().execute(
            arguments: Data(#"{"pattern":"foo","path":"context.txt","context":1}"#.utf8),
            context: ToolContext(workspace: workspace)
        )

        #expect(output.content.contains("context.txt-2- two"))
        #expect(output.content.contains("context.txt:3: foo"))
        #expect(output.content.contains("context.txt-4- four"))
    }

    @Test func respectsLimit() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("many.txt", "foo\nfoo\nfoo\n")
        let workspace = FileWorkspace(root: directory.url)

        let output = try await GrepTool().execute(
            arguments: Data(#"{"pattern":"foo","path":"many.txt","limit":1}"#.utf8),
            context: ToolContext(workspace: workspace)
        )

        #expect(output.content.contains("many.txt:1:"))
        #expect(!output.content.contains("many.txt:2:"))
        #expect(output.content.contains("limit reached"))
    }

    @Test func returnsNoMatchesMessage() async throws {
        let (directory, workspace) = try makeWorkspace()
        defer { directory.cleanup() }

        let output = try await GrepTool().execute(
            arguments: Data(#"{"pattern":"definitely-not-present"}"#.utf8),
            context: ToolContext(workspace: workspace)
        )

        #expect(output.content == "No matches found.")
    }

    @Test func rejectsInvalidRegex() async throws {
        let (directory, workspace) = try makeWorkspace()
        defer { directory.cleanup() }

        do {
            _ = try await GrepTool().execute(
                arguments: Data(#"{"pattern":"["}"#.utf8),
                context: ToolContext(workspace: workspace)
            )
            Issue.record("Expected an invalid regex error")
        } catch is ToolError {
        }
    }
}
