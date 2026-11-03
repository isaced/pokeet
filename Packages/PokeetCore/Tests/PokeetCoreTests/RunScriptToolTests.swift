import Foundation
import Testing
@testable import PokeetCore

struct RunScriptToolTests {
    @Test func reportsUnavailableWithoutRuntime() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        await #expect(throws: ScriptRuntimeError.unavailable) {
            _ = try await RunScriptTool().execute(
                arguments: Data(#"{"script":"1+1"}"#.utf8),
                context: ToolContext(workspace: FileWorkspace(root: directory.url))
            )
        }
    }

    @Test func rejectsUnknownRuntime() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        do {
            _ = try await RunScriptTool().execute(
                arguments: Data(#"{"script":"1+1","runtime":"ruby"}"#.utf8),
                context: ToolContext(
                    workspace: FileWorkspace(root: directory.url),
                    scripting: ScriptRuntimes([fakeRuntime { _, _ in
                        ScriptResult(exitCode: 0, stdout: "", stderr: "", termination: .exited)
                    }])
                )
            )
            Issue.record("Expected the unknown runtime to be rejected")
        } catch let error as ScriptRuntimeError {
            #expect(error == .unknownRuntime("ruby", available: ["javascript"]))
        }
    }

    @Test func rejectsMissingAndAmbiguousSource() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        let context = ToolContext(
            workspace: FileWorkspace(root: directory.url),
            scripting: ScriptRuntimes([fakeRuntime { _, _ in
                ScriptResult(exitCode: 0, stdout: "", stderr: "", termination: .exited)
            }])
        )

        for payload in [#"{}"#, #"{"script":"1","path":"x.js"}"#] {
            await #expect(throws: ToolError.self) {
                _ = try await RunScriptTool().execute(
                    arguments: Data(payload.utf8),
                    context: context
                )
            }
        }
    }

    @Test func returnsOutputAndProposals() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("src/app.js", "old\n")

        let workspace = FileWorkspace(root: directory.url)
        let tool = RunScriptTool()
        let output = try await tool.execute(
            arguments: Data(#"{"script":"fs.write('src/app.js','new'); console.log('done')"}"#.utf8),
            context: ToolContext(
                workspace: workspace,
                scripting: ScriptRuntimes([fakeRuntime { _, files in
                    try files.write("src/app.js", content: "new\n")
                    return ScriptResult(
                        exitCode: 0,
                        stdout: "done\n",
                        stderr: "",
                        termination: .exited,
                        durationMilliseconds: 12
                    )
                }])
            )
        )

        #expect(output.content.contains("done"))
        #expect(output.content.contains("exit 0"))
        #expect(output.content.contains("src/app.js (+1/-1)"))
        #expect(output.proposals.count == 1)
        #expect(output.proposals[0].kind == .update)
        #expect(try workspace.read("src/app.js", maxBytes: 100) == "old\n")
    }

    @Test func discardsProposalsWhenTheScriptIsStopped() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let output = try await RunScriptTool().execute(
            arguments: Data(#"{"script":"while(true){}","timeout_ms":500}"#.utf8),
            context: ToolContext(
                workspace: FileWorkspace(root: directory.url),
                scripting: ScriptRuntimes([fakeRuntime { _, files in
                    try files.write("partial.txt", content: "half")
                    return ScriptResult(
                        exitCode: 1,
                        stdout: "",
                        stderr: "",
                        termination: .timedOut
                    )
                }])
            )
        )

        #expect(output.proposals.isEmpty)
        #expect(output.content.contains("500 ms limit"))
    }

    @Test func runsSourceFromARepositoryFile() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("checks/smoke.js", "console.log('file')\n")

        let sourceBox = SourceBox()
        let output = try await RunScriptTool().execute(
            arguments: Data(#"{"path":"checks/smoke.js"}"#.utf8),
            context: ToolContext(
                workspace: FileWorkspace(root: directory.url),
                scripting: ScriptRuntimes([fakeRuntime { request, _ in
                    sourceBox.value = request
                    return ScriptResult(exitCode: 0, stdout: "file\n", stderr: "", termination: .exited)
                }])
            )
        )

        #expect(output.content.contains("file"))
        #expect(sourceBox.value?.source.contains("console.log") == true)
        #expect(sourceBox.value?.filename == "checks/smoke.js")
    }

    @Test func passesArgumentsAndClampsTimeout() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let sourceBox = SourceBox()
        _ = try await RunScriptTool().execute(
            arguments: Data(#"{"script":"1","args":["a","b"],"timeout_ms":999999}"#.utf8),
            context: ToolContext(
                workspace: FileWorkspace(root: directory.url),
                scripting: ScriptRuntimes([fakeRuntime { request, _ in
                    sourceBox.value = request
                    return ScriptResult(exitCode: 0, stdout: "", stderr: "", termination: .exited)
                }])
            )
        )

        #expect(sourceBox.value?.arguments == ["a", "b"])
        #expect(sourceBox.value?.limits.wallClockMilliseconds == RunScriptTool.maximumTimeoutMilliseconds)
    }

    private func fakeRuntime(
        _ behaviour: @escaping @Sendable (ScriptRequest, any ScriptFileSystem) throws -> ScriptResult
    ) -> FakeScriptRuntime {
        FakeScriptRuntime(behaviour: behaviour)
    }
}

private final class SourceBox: @unchecked Sendable {
    var value: ScriptRequest?
}

struct OverlayScriptFileSystemTests {
    @Test func readsFallThroughAndWritesStayBuffered() throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("a.txt", "alpha\n")

        let workspace = FileWorkspace(root: directory.url)
        let overlay = OverlayScriptFileSystem(workspace: workspace)

        #expect(try overlay.read("a.txt") == "alpha\n")
        try overlay.write("a.txt", content: "beta\n")
        try overlay.write("nested/new.txt", content: "one\ntwo\n")

        #expect(try overlay.read("a.txt") == "beta\n")
        #expect(overlay.exists("nested/new.txt"))
        #expect(!workspace.exists("nested/new.txt"))
        #expect(try overlay.info("nested/new.txt").lineCount == 2)

        let proposals = overlay.proposals()
        #expect(proposals.count == 2)
        #expect(proposals.first { $0.path == "nested/new.txt" }?.kind == .create)
    }

    @Test func unchangedWritesProduceNoProposal() throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("a.txt", "same\n")

        let overlay = OverlayScriptFileSystem(workspace: FileWorkspace(root: directory.url))
        try overlay.write("a.txt", content: "same\n")

        #expect(overlay.proposals().isEmpty)
    }

    @Test func enforcesFileAndByteLimits() throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let limits = ScriptLimits(maxWriteBytes: 1_000, maxWriteFiles: 2)
        let overlay = OverlayScriptFileSystem(
            workspace: FileWorkspace(root: directory.url),
            limits: limits
        )

        try overlay.write("one.txt", content: "ok")
        try overlay.write("two.txt", content: "ok")
        #expect(throws: ScriptRuntimeError.self) {
            try overlay.write("three.txt", content: "ok")
        }
        #expect(throws: ScriptRuntimeError.self) {
            try overlay.write("big.txt", content: String(repeating: "x", count: 2_000))
        }
    }

    @Test func rejectsPathsOutsideTheWorkspace() throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let overlay = OverlayScriptFileSystem(workspace: FileWorkspace(root: directory.url))
        #expect(throws: ScriptRuntimeError.self) { try overlay.read("../secret") }
        #expect(throws: ScriptRuntimeError.self) { try overlay.write(".git/config", content: "x") }
        #expect(throws: ScriptRuntimeError.self) { try overlay.read("/etc/passwd") }
        #expect(!overlay.exists("../secret"))
    }

    @Test func listsStagedFilesBesideRealOnes() throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("src/real.js", "1\n")

        let overlay = OverlayScriptFileSystem(workspace: FileWorkspace(root: directory.url))
        try overlay.write("src/staged.js", content: "2\n")

        let paths = try overlay.list("src", recursive: false).map(\.path)
        #expect(paths == ["src/real.js", "src/staged.js"])
    }
}
