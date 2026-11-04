import Foundation
import PokeetCore
import Testing

@testable import PokeetPython

@Suite("Python network", .serialized)
struct PythonNetworkTests {
    private func run(_ source: String, access: ScriptNetworkAccess? = nil) async throws -> ScriptResult {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pokeet-pynet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try await PythonRuntime().run(
            ScriptRequest(
                source: source,
                filename: "script.py",
                network: access ?? NetworkTestSupport.access()
            ),
            files: OverlayScriptFileSystem(workspace: FileWorkspace(root: directory))
        )
    }

    @Test("urlopen returns a response the stdlib can consume")
    func urlopen() async throws {
        NetworkTestSupport.respond(body: #"{"items":[1,2,3]}"#)
        defer { StubURLProtocol.handler = nil }

        let result = try await run("""
        import json
        from urllib.request import urlopen

        with urlopen('https://example.com/data') as response:
            print(response.status, response.headers.get('content-type'))
            print(len(json.load(response)['items']))
        """)

        #expect(result.termination == .exited, "\(result.stderr)")
        #expect(result.stdout.contains("200 application/json"))
        #expect(result.stdout.contains("3"))
    }

    @Test("urlopen sends a POST body")
    func post() async throws {
        StubURLProtocol.handler = { request in
            let body = NetworkTestSupport.bodyText(of: request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 201, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (response, Data(body.utf8))
        }
        defer { StubURLProtocol.handler = nil }

        let result = try await run("""
        from urllib.request import urlopen
        response = urlopen('https://example.com/items', data=b'hello')
        print(response.status, response.read().decode())
        """)

        #expect(result.termination == .exited, "\(result.stderr)")
        #expect(result.stdout.contains("201 hello"))
    }

    @Test("a blocked host raises instead of reaching it")
    func blockedHost() async throws {
        NetworkTestSupport.respond(body: "leak")
        defer { StubURLProtocol.handler = nil }

        let result = try await run("""
        from urllib.request import urlopen
        try:
            urlopen('https://localhost/admin')
        except OSError:
            print('blocked')
        """)

        #expect(result.termination == .exited, "\(result.stderr)")
        #expect(result.stdout.contains("blocked"))
    }

    @Test("a run without network access cannot reach out")
    func noNetwork() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pokeet-pynet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let result = try await PythonRuntime().run(
            ScriptRequest(source: """
            from urllib.request import urlopen
            try:
                urlopen('https://example.com/')
            except Exception as error:
                print('off')
            """),
            files: OverlayScriptFileSystem(workspace: FileWorkspace(root: directory))
        )
        #expect(result.stdout.contains("off"))
    }

    @Test("urllib.parse still works, it never needed a socket")
    func parseStillWorks() async throws {
        let result = try await run("""
        from urllib.parse import urlencode, quote
        print(urlencode({'a': 1, 'b': 'x y'}))
        print(quote('a b'))
        """)
        #expect(result.termination == .exited, "\(result.stderr)")
        #expect(result.stdout.contains("a=1&b=x+y"))
    }
}
