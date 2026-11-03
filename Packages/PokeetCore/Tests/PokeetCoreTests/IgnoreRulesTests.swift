import Foundation
import Testing
@testable import PokeetCore

struct IgnoreRulesTests {
    @Test func skipsIgnoredDirectoriesAndFiles() throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write(".gitignore", """
        build/
        *.log
        """)
        try directory.write("build/output.txt", "generated\n")
        try directory.write("Sources/main.swift", "print(1)\n")
        try directory.write("debug.log", "noise\n")

        let workspace = FileWorkspace(root: directory.url)
        let paths = try workspace.list("", recursive: true, maxEntries: 100).map(\.path)

        #expect(paths.contains("Sources/main.swift"))
        #expect(!paths.contains("build/output.txt"))
        #expect(!paths.contains("debug.log"))
    }

    @Test func supportsNegation() throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write(".gitignore", """
        *.log
        !keep.log
        """)
        try directory.write("keep.log", "keep\n")
        try directory.write("drop.log", "drop\n")

        let workspace = FileWorkspace(root: directory.url)
        let paths = try workspace.list("", recursive: false, maxEntries: 100).map(\.path)

        #expect(paths.contains("keep.log"))
        #expect(!paths.contains("drop.log"))
    }

    @Test func anchoredPatternMatchesOnlyItsOwnDirectory() throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write(".gitignore", "/build\n")
        try directory.write("build/root.txt", "root\n")
        try directory.write("packages/build/nested.txt", "nested\n")

        let workspace = FileWorkspace(root: directory.url)
        let paths = try workspace.list("", recursive: true, maxEntries: 100).map(\.path)

        #expect(!paths.contains("build/root.txt"))
        #expect(paths.contains("packages/build/nested.txt"))
    }

    @Test func directoryOnlyPatternSparesFiles() throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write(".gitignore", "dist/\n")
        try directory.write("dist/out.js", "built\n")
        try directory.write("notes/dist", "a file that happens to share the name\n")

        let workspace = FileWorkspace(root: directory.url)
        let paths = try workspace.list("", recursive: true, maxEntries: 100).map(\.path)

        #expect(paths.contains("notes/dist"))
        #expect(!paths.contains("dist/out.js"))
    }

    @Test func nestedGitignoreAppliesToItsSubtree() throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("packages/app/.gitignore", "generated/\n")
        try directory.write("packages/app/generated/api.swift", "generated\n")
        try directory.write("packages/other/generated/api.swift", "kept\n")

        let workspace = FileWorkspace(root: directory.url)
        let paths = try workspace.list("", recursive: true, maxEntries: 100).map(\.path)

        #expect(!paths.contains("packages/app/generated/api.swift"))
        #expect(paths.contains("packages/other/generated/api.swift"))
    }

    @Test func globPatternsMatchNestedPaths() throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write(".gitignore", "*.min.js\nvendor/**\n")
        try directory.write("web/app.min.js", "min\n")
        try directory.write("web/app.js", "src\n")
        try directory.write("vendor/lib/a.js", "vendored\n")

        let workspace = FileWorkspace(root: directory.url)
        let paths = try workspace.list("", recursive: true, maxEntries: 100).map(\.path)

        #expect(paths.contains("web/app.js"))
        #expect(!paths.contains("web/app.min.js"))
        #expect(!paths.contains("vendor/lib/a.js"))
    }

    @Test func grepAndFindSkipIgnoredPaths() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write(".gitignore", "dist/\n")
        try directory.write("Sources/config.swift", "let needle = 1\n")
        try directory.write("dist/bundle.js", "let needle = 2\n")

        let workspace = FileWorkspace(root: directory.url)
        let context = ToolContext(workspace: workspace)

        let grep = try await GrepTool().execute(
            arguments: Data(#"{"pattern":"needle"}"#.utf8),
            context: context
        )
        #expect(grep.content.contains("Sources/config.swift"))
        #expect(!grep.content.contains("dist/bundle.js"))

        let find = try await FindTool().execute(
            arguments: Data(#"{"pattern":"*.js"}"#.utf8),
            context: context
        )
        #expect(!find.content.contains("dist/bundle.js"))
    }
}
