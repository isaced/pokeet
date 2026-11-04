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

    @Test("the idiomatic Request + urlopen form works")
    func requestObject() async throws {
        NetworkTestSupport.respond(body: #"{"name":"pokeet"}"#)
        defer { StubURLProtocol.handler = nil }

        let result = try await run("""
        import json, urllib.request

        req = urllib.request.Request(
            'https://api.github.com/repos/isaced/pokeet',
            headers={'Accept': 'application/vnd.github+json', 'User-Agent': 'pokeet/1.0'},
        )
        with urllib.request.urlopen(req, timeout=15) as response:
            payload = json.load(response)
        print(response.status, payload['name'])
        """)

        #expect(result.termination == .exited, "stderr: \(result.stderr)")
        #expect(result.stdout.contains("200 pokeet"))
    }

    @Test("a local host is reachable, since the policy no longer refuses one")
    func localHostIsAllowed() async throws {
        NetworkTestSupport.respond(body: "local")
        defer { StubURLProtocol.handler = nil }

        let result = try await run("""
        from urllib.request import urlopen
        print(urlopen('https://localhost/admin').read().decode())
        """)

        #expect(result.termination == .exited, "\(result.stderr)")
        #expect(result.stdout.contains("local"))
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

    @Test("every way of importing urlopen resolves to the shim")
    func importForms() async throws {
        let result = try await run("""
        import urllib.request
        from urllib.request import urlopen
        from urllib import request
        import urllib.parse
        print(urlopen is urllib.request.urlopen, request.urlopen is urlopen)
        print(urllib.parse.quote('a b'))
        """)
        #expect(result.termination == .exited, "stderr: \(result.stderr)")
        #expect(result.stdout.contains("True True"))
        #expect(result.stdout.contains("a%20b"))
    }

    @Test("urllib.error classes are real and raise_for_status opts in")
    func urllibError() async throws {
        NetworkTestSupport.respond(status: 404, body: "nope")
        defer { StubURLProtocol.handler = nil }

        let result = try await run("""
        import urllib.error
        from urllib.request import urlopen

        response = urlopen('https://api.github.com/missing')
        print('status', response.status)
        try:
            response.raise_for_status()
        except urllib.error.HTTPError as error:
            print('http error', error.code)
        """)

        #expect(result.termination == .exited, "stderr: \(result.stderr)")
        #expect(result.stdout.contains("status 404"))
        #expect(result.stdout.contains("http error 404"))
    }

    @Test("the app's environment is not visible to a script")
    func environmentIsEmpty() async throws {
        let result = try await run("""
        import os
        print('GITHUB_TOKEN' in os.environ, len(os.environ))
        """)
        #expect(result.termination == .exited, "stderr: \(result.stderr)")
        #expect(result.stdout.hasPrefix("False"))
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
