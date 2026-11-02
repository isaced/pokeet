import Foundation
import Testing
@testable import PokeetCore

@Suite(.serialized)
struct HTTPRequestToolTests {
    private struct StubResolver: HostResolving {
        var addresses: [String: [String]] = [:]
        var fallback: [String] = ["93.184.216.34"]

        func resolve(host: String) async throws -> [String] {
            if let resolved = addresses[host.lowercased()] {
                return resolved
            }
            return fallback
        }
    }

    private actor FlippingResolver: HostResolving {
        private var calls = 0

        func resolve(host: String) async throws -> [String] {
            calls += 1
            return calls == 1 ? ["93.184.216.34"] : ["10.0.0.1"]
        }
    }

    private func makeTool(
        resolver: any HostResolving = StubResolver(),
        limits: HTTPRequestTool.Limits = .init()
    ) -> HTTPRequestTool {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return HTTPRequestTool(
            session: URLSession(configuration: configuration),
            resolver: resolver,
            limits: limits
        )
    }

    private func execute(_ json: String, tool: HTTPRequestTool) async throws -> ToolOutput {
        try await tool.execute(
            arguments: Data(json.utf8),
            context: ToolContext(
                workspace: FileWorkspace(root: FileManager.default.temporaryDirectory)
            )
        )
    }

    private func respond(
        status: Int,
        headers: [String: String] = [:],
        body: String = ""
    ) -> StubURLProtocol.Handler {
        { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            return (response, Data(body.utf8))
        }
    }

    @Test func fetchesTextResponse() async throws {
        StubURLProtocol.setHandler(
            forHost: "example.com",
            respond(
                status: 200,
                headers: ["Content-Type": "text/plain; charset=utf-8"],
                body: "hello"
            )
        )
        defer { StubURLProtocol.setHandler(forHost: "example.com", nil) }

        let output = try await execute(
            #"{"url":"https://example.com/hello"}"#,
            tool: makeTool()
        )

        #expect(output.content.contains("HTTP 200 OK"))
        #expect(output.content.contains("GET https://example.com/hello"))
        #expect(output.content.contains("content-type: text/plain; charset=utf-8"))
        #expect(output.content.contains("hello"))
        #expect(output.proposals.isEmpty)
    }

    @Test func headOmitsBody() async throws {
        StubURLProtocol.setHandler(
            forHost: "example.com",
            respond(status: 200, headers: ["Content-Length": "5"], body: "hello")
        )
        defer { StubURLProtocol.setHandler(forHost: "example.com", nil) }

        let output = try await execute(
            #"{"url":"https://example.com/","method":"HEAD"}"#,
            tool: makeTool()
        )

        #expect(output.content.contains("HTTP 200 OK"))
        #expect(output.content.contains("(no body)"))
        #expect(!output.content.contains("\nhello"))
    }

    @Test func truncatesLargeBodies() async throws {
        StubURLProtocol.setHandler(
            forHost: "example.com",
            respond(
                status: 200,
                headers: ["Content-Type": "text/plain"],
                body: String(repeating: "a", count: 4_096)
            )
        )
        defer { StubURLProtocol.setHandler(forHost: "example.com", nil) }

        let output = try await execute(
            #"{"url":"https://example.com/","max_bytes":1024}"#,
            tool: makeTool()
        )

        #expect(output.content.contains("[body truncated"))
        #expect(!output.content.contains(String(repeating: "a", count: 2_000)))
    }

    @Test func omitsBinaryBodies() async throws {
        StubURLProtocol.setHandler(forHost: "example.com") { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "image/png"]
            )!
            return (response, Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]))
        }
        defer { StubURLProtocol.setHandler(forHost: "example.com", nil) }

        let output = try await execute(
            #"{"url":"https://example.com/image.png"}"#,
            tool: makeTool()
        )

        #expect(output.content.contains("Body omitted"))
        #expect(output.content.contains("image/png"))
    }

    @Test func returnsHTTPErrorStatusesAsContent() async throws {
        StubURLProtocol.setHandler(
            forHost: "example.com",
            respond(
                status: 404,
                headers: ["Content-Type": "application/json"],
                body: #"{"error":"missing"}"#
            )
        )
        defer { StubURLProtocol.setHandler(forHost: "example.com", nil) }

        let output = try await execute(
            #"{"url":"https://example.com/missing"}"#,
            tool: makeTool()
        )

        #expect(output.content.contains("HTTP 404"))
        #expect(output.content.contains("missing"))
    }

    @Test func forwardsCustomHeaders() async throws {
        let captured = LockedBox<[String: String?]>([:])
        StubURLProtocol.setHandler(forHost: "example.com") { request in
            captured.set([
                "authorization": request.value(forHTTPHeaderField: "Authorization"),
                "cookie": request.value(forHTTPHeaderField: "Cookie")
            ])
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [:]
            )!
            return (response, Data())
        }
        defer { StubURLProtocol.setHandler(forHost: "example.com", nil) }

        _ = try await execute(
            #"{"url":"https://example.com/","headers":{"Authorization":"Bearer test","Cookie":"a=1"}}"#,
            tool: makeTool()
        )

        #expect(captured.get()["authorization"] == "Bearer test")
        #expect(captured.get()["cookie"] == "a=1")
    }

    @Test func rejectsTransportAndInjectedHeaders() async {
        let tool = makeTool()

        await expectToolError(
            #"{"url":"https://example.com/","headers":{"Host":"example.com"}}"#,
            tool: tool,
            containing: "managed by the transport"
        )
        await expectToolError(
            #"{"url":"https://example.com/","headers":{"X-Test":"value\r\nInjected: 1"}}"#,
            tool: tool,
            containing: "invalid characters"
        )
        await expectToolError(
            #"{"url":"https://example.com/","headers":{"X-Test":"1","x-test":"2"}}"#,
            tool: tool,
            containing: "duplicate header"
        )
    }

    @Test func rejectsNonHTTPSURLs() async {
        await expectToolError(
            #"{"url":"http://example.com/"}"#,
            tool: makeTool(),
            containing: "https"
        )
    }

    @Test func rejectsPrivateLiteralHostsWithoutRequesting() async {
        let requests = LockedBox(0)
        StubURLProtocol.setHandler(forHost: "127.0.0.1") { request in
            requests.set(requests.get() + 1)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [:]
            )!
            return (response, Data())
        }
        defer { StubURLProtocol.setHandler(forHost: "127.0.0.1", nil) }

        await expectToolError(
            #"{"url":"https://127.0.0.1/"}"#,
            tool: makeTool(),
            containing: "blocked"
        )
        #expect(requests.get() == 0)
    }

    @Test func rejectsHostnamesThatResolveInternally() async {
        let requests = LockedBox(0)
        StubURLProtocol.setHandler(forHost: "example.com") { request in
            requests.set(requests.get() + 1)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [:]
            )!
            return (response, Data())
        }
        defer { StubURLProtocol.setHandler(forHost: "example.com", nil) }

        let tool = makeTool(
            resolver: StubResolver(addresses: ["example.com": ["10.0.0.1"]])
        )
        await expectToolError(
            #"{"url":"https://example.com/"}"#,
            tool: tool,
            containing: "blocked"
        )
        #expect(requests.get() == 0)
    }

    @Test func followsSameOriginRedirectsAndKeepsHeaders() async throws {
        let paths = LockedBox<[String]>([])
        let authorizations = LockedBox<[String?]>([])
        StubURLProtocol.setHandler(forHost: "example.com") { request in
            let url = request.url!
            paths.set(paths.get() + [url.path])
            authorizations.set(
                authorizations.get() + [request.value(forHTTPHeaderField: "Authorization")]
            )

            if url.path == "/start" {
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 302,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Location": "/next"]
                )!
                return (response, Data())
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/plain"]
            )!
            return (response, Data("done".utf8))
        }
        defer { StubURLProtocol.setHandler(forHost: "example.com", nil) }

        let output = try await execute(
            #"{"url":"https://example.com/start","headers":{"Authorization":"Bearer test"}}"#,
            tool: makeTool()
        )

        #expect(paths.get() == ["/start", "/next"])
        #expect(authorizations.get() == ["Bearer test", "Bearer test"])
        #expect(output.content.contains("done"))
    }

    @Test func refusesCrossOriginRedirects() async throws {
        let otherRequests = LockedBox(0)
        StubURLProtocol.setHandler(forHost: "example.com") { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": "https://other.example/secret"]
            )!
            return (response, Data())
        }
        StubURLProtocol.setHandler(forHost: "other.example") { request in
            otherRequests.set(otherRequests.get() + 1)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [:]
            )!
            return (response, Data())
        }
        defer {
            StubURLProtocol.setHandler(forHost: "example.com", nil)
            StubURLProtocol.setHandler(forHost: "other.example", nil)
        }

        let output = try await execute(
            #"{"url":"https://example.com/start","headers":{"Authorization":"Bearer test"}}"#,
            tool: makeTool()
        )

        #expect(output.content.contains("Redirect not followed"))
        #expect(otherRequests.get() == 0)
    }

    @Test func refusesRedirectsToInternalAddresses() async throws {
        let requests = LockedBox(0)
        StubURLProtocol.setHandler(forHost: "example.com") { request in
            requests.set(requests.get() + 1)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": "/next"]
            )!
            return (response, Data())
        }
        defer { StubURLProtocol.setHandler(forHost: "example.com", nil) }

        let output = try await execute(
            #"{"url":"https://example.com/start"}"#,
            tool: makeTool(resolver: FlippingResolver())
        )

        #expect(output.content.contains("Redirect not followed"))
        #expect(output.content.contains("blocked"))
        #expect(requests.get() == 1)
    }

    @Test func stopsAfterRedirectLimit() async throws {
        let requests = LockedBox(0)
        StubURLProtocol.setHandler(forHost: "example.com") { request in
            requests.set(requests.get() + 1)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": "/loop"]
            )!
            return (response, Data())
        }
        defer { StubURLProtocol.setHandler(forHost: "example.com", nil) }

        let output = try await execute(
            #"{"url":"https://example.com/start"}"#,
            tool: makeTool(limits: .init(maxRedirects: 2))
        )

        #expect(output.content.contains("redirect"))
        #expect(requests.get() == 3)
    }

    @Test func mapsTransportErrors() async {
        StubURLProtocol.setHandler(forHost: "example.com") { _ in
            throw URLError(.cannotConnectToHost)
        }
        defer { StubURLProtocol.setHandler(forHost: "example.com", nil) }

        do {
            _ = try await execute(
                #"{"url":"https://example.com/"}"#,
                tool: makeTool()
            )
            Issue.record("Expected a ToolError")
        } catch let error as ToolError {
            guard case .network = error else {
                Issue.record("Expected ToolError.network, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func expectToolError(
        _ json: String,
        tool: HTTPRequestTool,
        containing text: String
    ) async {
        do {
            _ = try await execute(json, tool: tool)
            Issue.record("Expected a ToolError")
        } catch let error as ToolError {
            #expect(error.errorDescription?.contains(text) == true)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
