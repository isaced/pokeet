import Foundation
import PokeetCore
import Testing
@testable import PokeetScripting

struct TestDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pokeet-scripting-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }

    func write(_ relativePath: String, _ content: String) throws {
        let fileURL = url.appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}

struct QuickJSRuntimeTests {
    private let runtime = QuickJSRuntime()

    @Test func runsScriptAndCapturesOutput() async throws {
        let result = try await run(
            """
            console.log('hello', 1 + 1);
            console.error('careful');
            """
        )

        #expect(result.termination == .exited)
        #expect(result.exitCode == 0)
        #expect(result.stdout == "hello 2\n")
        #expect(result.stderr == "careful\n")
    }

    @Test func reportsSyntaxError() async throws {
        let result = try await run("function (")
        #expect(result.exitCode == 1)
        guard case .threw(let message) = result.termination else {
            Issue.record("expected a thrown error, got \(result.termination)")
            return
        }
        #expect(message.lowercased().contains("syntaxerror") || message.lowercased().contains("unexpected"))
    }

    @Test func reportsAssertionFailure() async throws {
        let result = try await run(
            """
            assert.equal(1 + 1, 3, 'addition');
            """
        )
        guard case .threw(let message) = result.termination else {
            Issue.record("expected a thrown error, got \(result.termination)")
            return
        }
        #expect(message.contains("addition"))
        #expect(message.contains("expected 3"))
    }

    @Test func stopsRunawayLoopAtTheDeadline() async throws {
        let start = Date()
        let result = try await run("while (true) {}", timeout: 400)
        let elapsed = Date().timeIntervalSince(start)

        #expect(result.termination == .timedOut)
        #expect(elapsed < 5)
        #expect(elapsed > 0.3)
    }

    @Test func stopsWhenTheCallerCancels() async throws {
        let task = Task { try await run("while (true) {}", timeout: 30_000) }
        try await Task.sleep(for: .milliseconds(250))
        task.cancel()

        let result = try await task.value
        #expect(result.termination == .cancelled)
    }

    @Test func stopsRunawayAllocationAtTheMemoryLimit() async throws {
        let result = try await run(
            """
            const kept = [];
            while (true) { kept.push(new Array(4096).fill(1.5)); }
            """,
            memoryBytes: 8 * 1_024 * 1_024
        )

        #expect(result.termination == .outOfMemory)
    }

    @Test func readsWorkspaceFiles() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("src/app.js", "export const answer = 42;\n")

        let result = try await run(
            """
            const text = fs.read('src/app.js');
            console.log(text.trim());
            const info = fs.info('src/app.js');
            console.log(info.exists, info.sizeBytes > 0, info.isText);
            """,
            workspace: FileWorkspace(root: directory.url)
        )

        #expect(result.stdout == "export const answer = 42;\ntrue true true\n")
    }

    @Test func stagesWritesAsProposals() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("notes.md", "old\n")

        let workspace = FileWorkspace(root: directory.url)
        let limits = ScriptLimits()
        let files = OverlayScriptFileSystem(workspace: workspace, limits: limits)
        let result = try await runtime.run(
            ScriptRequest(source: "fs.write('notes.md', 'new\\n'); fs.write('src/added.txt', 'hi\\n');", limits: limits),
            files: files
        )

        #expect(result.termination == .exited)
        let proposals = files.proposals().sorted { $0.path < $1.path }
        #expect(proposals.map(\.path) == ["notes.md", "src/added.txt"])
        #expect(proposals[0].kind == .update)
        #expect(proposals[1].kind == .create)
        #expect(try workspace.read("notes.md", maxBytes: 100) == "old\n")
        #expect(!workspace.exists("src/added.txt"))
    }

    @Test func writesAreVisibleInsideTheRunOnly() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let result = try await run(
            """
            fs.write('out.txt', 'one');
            fs.append('out.txt', '-two');
            console.log(fs.read('out.txt'));
            console.log(fs.info('out.txt').lineCount);
            """,
            workspace: FileWorkspace(root: directory.url)
        )

        #expect(result.stdout == "one-two\n1\n")
    }

    @Test func rejectsPathEscapes() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let result = try await run(
            """
            try { fs.read('../../etc/passwd'); console.log('allowed'); }
            catch (error) { console.log('blocked'); }
            """,
            workspace: FileWorkspace(root: directory.url)
        )

        #expect(result.stdout == "blocked\n")
    }

    @Test func loadsRelativeCommonJSModules() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("lib/math.js", "exports.add = (a, b) => a + b;\n")
        try directory.write("lib/data.json", #"{"name":"pokeet"}"#)

        let result = try await run(
            """
            const math = require('./lib/math.js');
            const data = require('./lib/data.json');
            console.log(math.add(2, 3), data.name);
            """,
            workspace: FileWorkspace(root: directory.url)
        )

        #expect(result.stdout == "5 pokeet\n")
    }

    @Test func refusesToRequirePackages() async throws {
        let result = try await run(
            """
            try { require('lodash'); console.log('loaded'); }
            catch (error) { console.log(error.message.includes('node_modules')); }
            """
        )

        #expect(result.stdout == "true\n")
    }

    @Test func networkGoesThroughTheHostOrNotAtAll() async throws {
        // `fetch` exists, but a run without `ScriptNetworkAccess` has no way to use it,
        // and there is still no Node module to reach around it.
        let result = try await run(
            """
            try { http.get('https://example.com/'); console.log('net'); }
            catch (error) { console.log('blocked'); }
            console.log(typeof XMLHttpRequest, typeof WebSocket);
            try { require('http'); console.log('node'); } catch (error) { console.log('no-node'); }
            """
        )

        #expect(result.stdout == "blocked\nundefined undefined\nno-node\n")
    }

    @Test func honoursProcessExitCode() async throws {
        let result = try await run("console.log('bye'); process.exit(7); console.log('unreachable');")
        #expect(result.exitCode == 7)
        #expect(result.stdout == "bye\n")
    }

    @Test func truncatesLargeOutput() async throws {
        let result = try await run(
            """
            for (let index = 0; index < 200; index += 1) console.log('x'.repeat(100));
            """,
            outputBytes: 1_000
        )

        #expect(result.outputTruncated)
        #expect(result.stdout.utf8.count <= 1_000)
    }

    @Test func exposesArguments() async throws {
        let result = try await run("console.log(process.argv.slice(1).join(','));", arguments: ["a", "b"])
        #expect(result.stdout == "a,b\n")
    }

    private func run(
        _ source: String,
        timeout: Int = 5_000,
        memoryBytes: Int = 64 * 1_024 * 1_024,
        outputBytes: Int = 16_000,
        arguments: [String] = [],
        workspace: (any Workspace)? = nil
    ) async throws -> ScriptResult {
        let limits = ScriptLimits(
            wallClockMilliseconds: timeout,
            memoryBytes: memoryBytes,
            outputBytes: outputBytes
        )
        let root: any Workspace
        if let workspace {
            root = workspace
        } else {
            let directory = try TestDirectory()
            root = FileWorkspace(root: directory.url)
        }
        let files = OverlayScriptFileSystem(workspace: root, limits: limits)
        return try await runtime.run(
            ScriptRequest(source: source, arguments: arguments, limits: limits),
            files: files
        )
    }
}
