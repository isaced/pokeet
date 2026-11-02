import Foundation
import Testing
@testable import PokeetCore

struct PathSandboxTests {
    @Test func resolvesNestedFile() throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let sandbox = PathSandbox(root: directory.url)
        let resolved = try sandbox.resolve("src/main.swift")

        #expect(resolved.path == sandbox.root.appending(path: "src/main.swift").path)
    }

    @Test func normalizesDotSegments() throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let sandbox = PathSandbox(root: directory.url)
        let resolved = try sandbox.resolve("./src/./main.swift")

        #expect(resolved.lastPathComponent == "main.swift")
    }

    @Test func rejectsAbsolutePath() throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let sandbox = PathSandbox(root: directory.url)
        #expect(throws: WorkspaceError.self) {
            try sandbox.resolve("/etc/passwd")
        }
    }

    @Test func rejectsTildePath() throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let sandbox = PathSandbox(root: directory.url)
        #expect(throws: WorkspaceError.self) {
            try sandbox.resolve("~/secrets")
        }
    }

    @Test func rejectsParentTraversal() throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let sandbox = PathSandbox(root: directory.url)
        #expect(throws: WorkspaceError.self) {
            try sandbox.resolve("src/../../outside")
        }
    }

    @Test func rejectsGitDirectory() throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let sandbox = PathSandbox(root: directory.url)
        #expect(throws: WorkspaceError.self) {
            try sandbox.resolve(".git/config")
        }
    }

    @Test func allowsGitignore() throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let sandbox = PathSandbox(root: directory.url)
        let resolved = try sandbox.resolve(".gitignore")
        #expect(resolved.lastPathComponent == ".gitignore")
    }

    @Test func rejectsControlCharacters() throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let sandbox = PathSandbox(root: directory.url)
        #expect(throws: WorkspaceError.self) {
            try sandbox.resolve("bad\u{0}name")
        }
    }

    @Test func rejectsSymlinkEscape() throws {
        let directory = try TestDirectory()
        let outside = try TestDirectory()
        defer {
            directory.cleanup()
            outside.cleanup()
        }

        let link = directory.url.appending(path: "escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.url)

        let sandbox = PathSandbox(root: directory.url)
        #expect(throws: WorkspaceError.self) {
            try sandbox.resolve("escape/secret.txt")
        }
    }

    @Test func rejectsSymlinkIntoGitDirectory() throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        try directory.write(".git/config", "[core]\n")
        try FileManager.default.createSymbolicLink(
            at: directory.url.appending(path: "gitlink"),
            withDestinationURL: directory.url.appending(path: ".git")
        )

        let sandbox = PathSandbox(root: directory.url)
        #expect(throws: WorkspaceError.self) {
            try sandbox.resolve("gitlink/config")
        }
    }

    @Test func allowsRootOnlyWhenRequested() throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let sandbox = PathSandbox(root: directory.url)
        #expect(throws: WorkspaceError.self) {
            try sandbox.resolve("")
        }
        #expect(try sandbox.resolve("", allowRoot: true).path == sandbox.root.path)
    }
}
