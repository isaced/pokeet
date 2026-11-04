import Foundation
import PokeetCore
import Testing

@testable import PokeetScripting

@Suite("JavaScript network", .serialized)
struct ScriptNetworkTests {
    private func run(_ source: String, access: ScriptNetworkAccess? = nil) async throws -> ScriptResult {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pokeet-jsnet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try await QuickJSRuntime().run(
            ScriptRequest(
                source: source,
                filename: "script.js",
                network: access ?? NetworkTestSupport.access()
            ),
            files: OverlayScriptFileSystem(workspace: FileWorkspace(root: directory))
        )
    }

    @Test("http.get returns the status and body")
    func httpGet() async throws {
        NetworkTestSupport.respond(body: #"{"ok":true}"#)
        defer { StubURLProtocol.handler = nil }

        let result = try await run("""
        const res = http.get('https://example.com/data');
        console.log(res.status, res.ok, res.headers.get('content-type'));
        console.log(res.text());
        """)

        #expect(result.termination == .exited, "\(result.stderr)")
        #expect(result.stdout.contains("200 true application/json"))
        #expect(result.stdout.contains(#"{"ok":true}"#))
    }

    @Test("fetch works with await, which needs the module path")
    func fetchWithAwait() async throws {
        NetworkTestSupport.respond(body: #"{"items":[1,2]}"#)
        defer { StubURLProtocol.handler = nil }

        let result = try await run("""
        const res = await fetch('https://example.com/items');
        const data = await res.json();
        console.log(data.items.length);
        """)

        #expect(result.termination == .exited, "\(result.stderr)")
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "2")
    }

    @Test("a local host is reachable, since the policy no longer refuses one")
    func localHostIsAllowed() async throws {
        NetworkTestSupport.respond(body: "local")
        defer { StubURLProtocol.handler = nil }

        let result = try await run("""
        console.log(http.get('https://localhost/admin').text());
        """)

        #expect(result.termination == .exited, "\(result.stderr)")
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "local")
    }

    @Test("a run without network access cannot reach out")
    func noNetwork() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pokeet-jsnet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let result = try await QuickJSRuntime().run(
            ScriptRequest(source: "try { http.get('https://example.com'); } catch (e) { console.log('off'); }"),
            files: OverlayScriptFileSystem(workspace: FileWorkspace(root: directory))
        )
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "off")
    }
}

@Suite("run_script network wiring", .serialized)
struct RunScriptNetworkTests {
    private func tool(policy: NetworkAccessPolicy = NetworkAccessPolicy()) -> RunScriptTool {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ToolStubURLProtocol.self]
        return RunScriptTool(
            network: NetworkClient(
                session: URLSession(configuration: configuration),
                limits: NetworkClient.Limits()
            )
        )
    }

    private func context(policy: NetworkAccessPolicy = NetworkAccessPolicy()) throws -> ToolContext {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pokeet-runs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return ToolContext(
            workspace: FileWorkspace(root: directory),
            networkPolicy: policy,
            scripting: ScriptRuntimes([QuickJSRuntime()])
        )
    }

    @Test("a script reaches the network through the tool")
    func toolPassesNetwork() async throws {
        NetworkTestSupport.respondForTool(body: "pong")
        defer { ToolStubURLProtocol.handler = nil }

        let output = try await tool().execute(
            arguments: Data(#"{"script":"console.log(http.get('https://example.com/ping').text());"}"#.utf8),
            context: try context()
        )
        #expect(output.content.contains("pong"), "\(output.content)")
    }

    @Test("the tool's allowlist still applies inside a script")
    func toolPolicyApplies() async throws {
        NetworkTestSupport.respondForTool(body: "leak")
        defer { ToolStubURLProtocol.handler = nil }

        let output = try await tool().execute(
            arguments: Data(#"{"script":"try { http.get('https://example.com/'); } catch (e) { console.log('blocked'); }"}"#.utf8),
            context: try context(policy: NetworkAccessPolicy(allowedHosts: ["other.example"]))
        )
        #expect(output.content.contains("blocked"))
    }
}
