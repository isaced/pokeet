import Foundation
import Testing
@testable import PokeetCore

struct WorkspaceTests {
    @Test func readWriteRoundtrip() throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let workspace = FileWorkspace(root: directory.url)
        try workspace.write("src/main.swift", content: "print(\"hi\")\n")

        #expect(workspace.exists("src/main.swift"))
        #expect(try workspace.read("src/main.swift", maxBytes: 1000) == "print(\"hi\")\n")
    }

    @Test func writeCreatesNestedDirectories() throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let workspace = FileWorkspace(root: directory.url)
        try workspace.write("a/b/c.txt", content: "hello\n")

        let url = directory.url.appending(path: "a/b/c.txt")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func rejectsBinaryFile() throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let data = Data([0x48, 0x00, 0x49])
        try data.write(to: directory.url.appending(path: "binary.bin"))

        let workspace = FileWorkspace(root: directory.url)
        #expect(throws: WorkspaceError.self) {
            try workspace.read("binary.bin", maxBytes: 100)
        }
    }

    @Test func truncatesLongText() throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let workspace = FileWorkspace(root: directory.url)
        try workspace.write("long.txt", content: String(repeating: "a", count: 100) + "\n")

        let text = try workspace.read("long.txt", maxBytes: 10)
        #expect(text.contains("[truncated at 10 bytes]"))
    }

    @Test func deletesFile() throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let workspace = FileWorkspace(root: directory.url)
        try workspace.write("temp.txt", content: "bye\n")
        try workspace.delete("temp.txt")

        #expect(!workspace.exists("temp.txt"))
    }

    @Test func movesFileAndCreatesParentDirectories() throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let workspace = FileWorkspace(root: directory.url)
        try workspace.write("old.txt", content: "content\n")
        try workspace.move("old.txt", to: "nested/new.txt")

        #expect(!workspace.exists("old.txt"))
        #expect(try workspace.read("nested/new.txt", maxBytes: 100) == "content\n")
    }

    @Test func moveRejectsExistingDestination() throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let workspace = FileWorkspace(root: directory.url)
        try workspace.write("a.txt", content: "a\n")
        try workspace.write("b.txt", content: "b\n")

        #expect(throws: WorkspaceError.staleContent("b.txt")) {
            try workspace.move("a.txt", to: "b.txt")
        }
        #expect(workspace.exists("a.txt"))
    }

    @Test func listSkipsGitAndDependencies() throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        try directory.write(".git/config", "[core]\n")
        try directory.write(".gitignore", "build/\n")
        try directory.write("node_modules/pkg/index.js", "x\n")
        try directory.write("Sources/main.swift", "print(1)\n")

        let workspace = FileWorkspace(root: directory.url)
        let entries = try workspace.list("", recursive: true, maxEntries: 100)
        let paths = Set(entries.map(\.path))

        #expect(paths.contains(".gitignore"))
        #expect(paths.contains("Sources/main.swift"))
        #expect(!paths.contains { $0.hasPrefix(".git/") })
        #expect(!paths.contains { $0.hasPrefix("node_modules") })
    }
}
