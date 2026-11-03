import Foundation
import Testing
@testable import PokeetCore

struct FileInfoToolTests {
    @Test func describesTextFile() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("Sources/App.swift", "line one\nline two\n")

        let output = try await probe(#"{"path":"Sources/App.swift"}"#, in: directory)

        #expect(output.contains("kind: file"))
        #expect(output.contains("lines: 2"))
        #expect(output.contains("text: yes"))
        #expect(output.contains("read_file: ok"))
    }

    @Test func flagsBinaryFiles() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        let binary = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x0D, 0x0A, 0x1A, 0x0A])
        try binary.write(to: directory.url.appending(path: "icon.png"))

        let output = try await probe(#"{"path":"icon.png"}"#, in: directory)

        #expect(output.contains("text: no (binary)"))
        #expect(output.contains("lines: unknown"))
        #expect(output.contains("read_file: not readable as text"))
    }

    @Test func describesDirectories() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("Sources/a.swift", "1\n")
        try directory.write("Sources/b.swift", "2\n")

        let output = try await probe(#"{"path":"Sources"}"#, in: directory)

        #expect(output.contains("kind: directory"))
        #expect(output.contains("entries: 2"))
    }

    @Test func reportsMissingPaths() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let output = try await probe(#"{"path":"nope.txt"}"#, in: directory)
        #expect(output.contains("No such file or directory"))
    }

    @Test func suggestsPagedReadsForLargeFiles() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write(
            "data/log.txt",
            String(repeating: "0123456789abcdef\n", count: 20_000)
        )

        let output = try await probe(#"{"path":"data/log.txt"}"#, in: directory)
        #expect(output.contains("read_file: large; pass offset and limit"))
    }

    @Test func rejectsPathsOutsideTheWorkspace() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        await #expect(throws: ToolError.self) {
            _ = try await probe(#"{"path":"../escape.txt"}"#, in: directory)
        }
    }

    private func probe(_ arguments: String, in directory: TestDirectory) async throws -> String {
        let output = try await FileInfoTool().execute(
            arguments: Data(arguments.utf8),
            context: ToolContext(workspace: FileWorkspace(root: directory.url))
        )
        return output.content
    }
}
