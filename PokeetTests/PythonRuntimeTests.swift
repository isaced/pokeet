import PokeetCore
import XCTest
@testable import Pokeet

/// Runs CPython inside the real app, through the runtime registry the app builds.
///
/// Deliberately talks to `any ScriptRuntime` instead of importing PokeetPython: the
/// test bundle then needs no Python symbols of its own, and what it verifies is the
/// wiring — that `AppEnvironment` found a bundled stdlib and registered a runtime that
/// actually runs. Packaging lives in `scripts/fetch-python.sh`.
@MainActor
final class PythonRuntimeTests: XCTestCase {
    private func pythonRuntime() throws -> any ScriptRuntime {
        let environment = AppEnvironment()
        let runtime = try XCTUnwrap(
            environment.scripting.runtime(named: "python"),
            "CPython is not registered — did scripts/fetch-python.sh run?"
        )
        XCTAssertEqual(runtime.displayName, "Python")
        return runtime
    }

    private func makeFileSystem(seed: [String: String] = [:]) throws -> OverlayScriptFileSystem {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pokeet-app-py-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, content) in seed {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        return OverlayScriptFileSystem(workspace: FileWorkspace(root: root))
    }

    func testRunsAScriptFromTheAppBundle() async throws {
        let runtime = try pythonRuntime()
        let result = try await runtime.run(
            ScriptRequest(source: "import sys\nprint(sys.version_info[0])\nprint(1 + 1)"),
            files: try makeFileSystem()
        )

        XCTAssertEqual(result.termination, .exited, result.stderr)
        XCTAssertEqual(result.stdout, "3\n2\n")
    }

    func testEditsTheWorkspaceThroughTheReviewQueue() async throws {
        let files = try makeFileSystem(seed: ["src/main.py": "print('hello')\n"])
        let runtime = try pythonRuntime()

        let result = try await runtime.run(
            ScriptRequest(source: """
            import pokeet
            print(pokeet.read('src/main.py').strip())
            with open('src/main.py', 'w') as handle:
                handle.write("print('bye')\\n")
            """),
            files: files
        )

        XCTAssertEqual(result.termination, .exited, result.stderr)
        XCTAssertEqual(result.stdout, "print('hello')\n")

        let proposal = try XCTUnwrap(files.proposals().first)
        XCTAssertEqual(proposal.path, "src/main.py")
        XCTAssertEqual(proposal.kind, .update)
        XCTAssertEqual(proposal.newContent, "print('bye')\n")
    }

    func testSandboxRefusesToEscapeTheProject() async throws {
        let runtime = try pythonRuntime()
        let result = try await runtime.run(
            ScriptRequest(source: """
            try:
                open('../outside.txt', 'w')
            except OSError:
                print('blocked')
            """),
            files: try makeFileSystem()
        )

        XCTAssertEqual(result.termination, .exited, result.stderr)
        XCTAssertEqual(result.stdout, "blocked\n")
    }

    func testRunawayScriptIsStopped() async throws {
        let runtime = try pythonRuntime()
        let started = Date()
        let result = try await runtime.run(
            ScriptRequest(
                source: "while True:\n    pass",
                limits: ScriptLimits(wallClockMilliseconds: 800)
            ),
            files: try makeFileSystem()
        )

        XCTAssertEqual(result.termination, .timedOut, result.stderr)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
}
