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

    @Test("a failure names its reason on the first line")
    func failureHeadline() async throws {
        let output = try await RunScriptTool().execute(
            arguments: Data(#"{"script":"throw new Error('boom')"}"#.utf8),
            context: try context()
        )
        // The collapsed trace row shows only this line, so the reason has to be on it.
        let headline = output.content.split(separator: "\n").first.map(String.init) ?? ""
        #expect(headline.hasPrefix("JavaScript · uncaught error · Error: boom · "))
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

@Suite("JavaScript fs surface", .serialized)
struct JavaScriptFileSystemTests {
    private func run(_ source: String, seed: [String: String] = [:]) async throws -> ScriptResult {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pokeet-jsfs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, content) in seed {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        return try await QuickJSRuntime().run(
            ScriptRequest(source: source, filename: "script.js"),
            files: OverlayScriptFileSystem(workspace: FileWorkspace(root: root))
        )
    }

    @Test("Node-shaped fs calls work through require('fs')")
    func nodeShapedFS() async throws {
        let result = try await run("""
        const fs = require('fs');
        fs.writeFileSync('notes.md', '# hi\\n');
        fs.appendFileSync('notes.md', 'more\\n');
        console.log(fs.readFileSync('notes.md').trim());
        console.log(fs.readdirSync('.').includes('notes.md'));
        console.log(fs.statSync('notes.md').isFile(), fs.existsSync('nope.md'));
        """)
        #expect(result.termination == .exited, "\(result.stderr)")
        #expect(result.stdout.contains("# hi\nmore"))
        #expect(result.stdout.contains("true"))
        #expect(result.stdout.contains("true false"))
    }

    @Test("require('path') is the same helper as before")
    func requirePath() async throws {
        let result = try await run("""
        const path = require('path');
        console.log(path.join('src', 'a.js'), path.basename('src/a.js'));
        """)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "src/a.js a.js")
    }

    @Test("statSync reports ENOENT like Node")
    func missingFile() async throws {
        let result = try await run("""
        const fs = require('fs');
        try { fs.statSync('nope.txt'); } catch (error) { console.log(error.code); }
        """)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "ENOENT")
    }

    @Test("operations the sandbox cannot honour refuse by name")
    func unsupportedOps() async throws {
        let result = try await run("""
        const fs = require('fs');
        for (const name of ['unlinkSync', 'renameSync', 'mkdirSync']) {
          try { fs[name]('x'); } catch (error) { console.log(name, error.code); }
        }
        """)
        #expect(result.termination == .exited, "\(result.stderr)")
        #expect(result.stdout.contains("unlinkSync ENOSYS"))
        #expect(result.stdout.contains("mkdirSync ENOSYS"))
    }
}

@Suite("JavaScript globals", .serialized)
struct JavaScriptGlobalsTests {
    private func run(_ source: String) async throws -> ScriptResult {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pokeet-jsg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try await QuickJSRuntime().run(
            ScriptRequest(source: source, filename: "script.js"),
            files: OverlayScriptFileSystem(workspace: FileWorkspace(root: root))
        )
    }

    @Test("URL and URLSearchParams behave")
    func urlGlobals() async throws {
        let result = try await run("""
        const url = new URL('https://api.example.com/items?page=2&q=a%20b');
        console.log(url.hostname, url.pathname, url.searchParams.get('q'));
        url.searchParams.set('page', '3');
        url.searchParams.append('tag', 'x y');
        console.log(url.toString());
        console.log(new URLSearchParams({ a: 1, b: 'x y' }).toString());
        """)
        #expect(result.termination == .exited, "\(result.stderr)")
        #expect(result.stdout.contains("api.example.com /items a b"))
        #expect(result.stdout.contains("https://api.example.com/items?page=3&q=a%20b&tag=x%20y"))
        #expect(result.stdout.contains("a=1&b=x%20y"))
    }

    @Test("base64 and text codecs round-trip")
    func codecs() async throws {
        let result = try await run("""
        console.log(btoa('hello'), atob(btoa('hello')));
        const bytes = new TextEncoder().encode('héllo');
        console.log(bytes.length, new TextDecoder().decode(bytes));
        """)
        #expect(result.termination == .exited, "\(result.stderr)")
        #expect(result.stdout.contains("aGVsbG8= hello"))
        #expect(result.stdout.contains("6 héllo"))
    }

    @Test("setTimeout fires without an event loop, setInterval refuses")
    func timers() async throws {
        let result = try await run("""
        await new Promise((resolve) => setTimeout(resolve, 10));
        console.log('after timeout');
        try { setInterval(function () {}, 10); } catch (error) { console.log('no interval'); }
        """)
        #expect(result.termination == .exited, "\(result.stderr)")
        #expect(result.stdout.contains("after timeout"))
        #expect(result.stdout.contains("no interval"))
    }

    @Test("cwd, statusText and redirected describe what happened")
    func responseShape() async throws {
        GlobalsStubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (response, Data("missing".utf8))
        }
        defer { GlobalsStubURLProtocol.handler = nil }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pokeet-jsg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let result = try await QuickJSRuntime().run(
            ScriptRequest(
                source: """
                console.log(process.cwd());
                const res = http.get('https://example.com/gone');
                console.log(res.status, res.statusText, res.ok, res.redirected);
                """,
                filename: "script.js",
                network: NetworkTestSupport.accessForGlobals()
            ),
            files: OverlayScriptFileSystem(workspace: FileWorkspace(root: root))
        )
        #expect(result.termination == .exited, "\(result.stderr)")
        #expect(result.stdout.contains("/\n"))
        #expect(result.stdout.contains("404 Not Found false false"))
    }
}
