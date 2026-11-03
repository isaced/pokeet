import PokeetCore
import PokeetScripting
import XCTest

/// Smoke coverage for the real QuickJS bridge on a device build.
/// The exhaustive engine tests live in `Packages/PokeetScripting`.
final class ScriptingSmokeTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pokeet-scripting-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRunsScriptAndStagesWrites() async throws {
        try "old\n".write(
            to: directory.appending(path: "notes.md"),
            atomically: true,
            encoding: .utf8
        )

        let workspace = FileWorkspace(root: directory)
        let limits = ScriptLimits()
        let files = OverlayScriptFileSystem(workspace: workspace, limits: limits)
        let result = try await QuickJSRuntime().run(
            ScriptRequest(
                source: """
                const text = fs.read('notes.md');
                fs.write('notes.md', text.replace('old', 'new'));
                console.log('patched');
                """,
                limits: limits
            ),
            files: files
        )

        XCTAssertEqual(result.termination, .exited)
        XCTAssertEqual(result.stdout, "patched\n")
        XCTAssertEqual(files.proposals().count, 1)
        XCTAssertEqual(try workspace.read("notes.md", maxBytes: 100), "old\n")
    }

    func testStopsRunawayLoop() async throws {
        let files = OverlayScriptFileSystem(workspace: FileWorkspace(root: directory))
        let result = try await QuickJSRuntime().run(
            ScriptRequest(source: "while (true) {}", limits: ScriptLimits(wallClockMilliseconds: 500)),
            files: files
        )

        XCTAssertEqual(result.termination, .timedOut)
    }

    func testStopsAllocationBomb() async throws {
        let files = OverlayScriptFileSystem(workspace: FileWorkspace(root: directory))
        let result = try await QuickJSRuntime().run(
            ScriptRequest(
                source: "const kept = []; while (true) { kept.push(new Array(4096).fill(1.5)); }",
                limits: ScriptLimits(memoryBytes: 8 * 1_024 * 1_024)
            ),
            files: files
        )

        XCTAssertEqual(result.termination, .outOfMemory)
    }

    func testToolIsRegisteredAndModeGated() {
        let registry = ToolRegistry.standard
        XCTAssertNotNil(registry.tool(named: RunScriptTool.toolName))
        XCTAssertNil(registry.filtered(for: .plan).tool(named: RunScriptTool.toolName))
        XCTAssertNotNil(registry.filtered(for: .ask).tool(named: RunScriptTool.toolName))
    }
}
