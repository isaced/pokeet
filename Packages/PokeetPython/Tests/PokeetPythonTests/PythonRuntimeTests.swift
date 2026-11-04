import Foundation
import PokeetCore
import Testing

@testable import PokeetPython

@Suite("CPython sandbox", .serialized)
struct PythonRuntimeTests {
    private func temporaryFileSystem() throws -> OverlayScriptFileSystem {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pokeet-python-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return OverlayScriptFileSystem(workspace: FileWorkspace(root: directory))
    }

    private func run(
        _ source: String,
        limits: ScriptLimits = ScriptLimits(),
        fileSystem: OverlayScriptFileSystem? = nil
    ) async throws -> ScriptResult {
        let files = try fileSystem ?? temporaryFileSystem()
        return try await PythonRuntime().run(
            ScriptRequest(source: source, filename: "script.py", limits: limits),
            files: files
        )
    }

    @Test("runs a script and captures stdout")
    func capturesOutput() async throws {
        let result = try await run("print(1 + 1)\nprint('ok')")
        #expect(result.termination == .exited)
        #expect(result.exitCode == 0)
        #expect(result.stdout == "2\nok\n")
    }

    @Test("imports the standard library")
    func importsStdlib() async throws {
        let result = try await run("import json\nprint(json.dumps({'a': 1}))")
        #expect(result.termination == .exited, "stderr: \(result.stderr)")
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == #"{"a": 1}"#)
    }

    @Test("interrupts a runaway loop on the wall clock")
    func interruptsInfiniteLoop() async throws {
        let limits = ScriptLimits(wallClockMilliseconds: 700)
        let started = Date()
        let result = try await run("while True:\n    pass", limits: limits)
        let elapsed = Date().timeIntervalSince(started)

        #expect(result.termination == .timedOut, "got \(result.termination), stderr: \(result.stderr)")
        #expect(elapsed < 3.0, "the watchdog should stop the interpreter, not the caller: \(elapsed)s")
    }

    @Test("refuses an allocation above the memory budget")
    func enforcesMemoryBudget() async throws {
        let limits = ScriptLimits(memoryBytes: 32 * 1_024 * 1_024)
        let result = try await run(
            "blob = bytearray(200 * 1024 * 1024)\nprint('allocated', len(blob))",
            limits: limits
        )

        #expect(result.termination == .outOfMemory, "got \(result.termination), stdout: \(result.stdout)")
        #expect(result.stdout.isEmpty, "the script must not reach the print")
    }

    @Test("is still usable after a timeout and after an out-of-memory run")
    func recoversAfterFailures() async throws {
        _ = try await run("while True:\n    pass", limits: ScriptLimits(wallClockMilliseconds: 500))
        _ = try await run(
            "blob = bytearray(200 * 1024 * 1024)",
            limits: ScriptLimits(memoryBytes: 32 * 1_024 * 1_024)
        )
        let result = try await run("print('alive')")
        #expect(result.stdout == "alive\n")
    }

    @Test("reports an uncaught exception with a traceback")
    func reportsExceptions() async throws {
        let result = try await run("raise ValueError('nope')")
        #expect(result.termination == .threw("ValueError: nope"))
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("ValueError"))
        #expect(result.stderr.contains("Traceback"))
    }
}
