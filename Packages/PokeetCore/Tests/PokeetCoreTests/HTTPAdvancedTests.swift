import Foundation
import Testing
@testable import PokeetCore

@Suite(.serialized)
struct HTTPAdvancedTests {
    private func makeTool() -> HTTPRequestTool {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return HTTPRequestTool(
            session: URLSession(configuration: configuration),
            limits: .init()
        )
    }

    private func context(policy: NetworkAccessPolicy = .init()) -> ToolContext {
        ToolContext(
            workspace: FileWorkspace(root: FileManager.default.temporaryDirectory),
            networkPolicy: policy
        )
    }

    private func execute(
        _ json: String,
        policy: NetworkAccessPolicy = .init()
    ) async throws -> ToolOutput {
        try await makeTool().execute(
            arguments: Data(json.utf8),
            context: context(policy: policy)
        )
    }

    private func respond(
        status: Int,
        headers: [String: String] = [:],
        body: String
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

    private func expectToolError(
        _ json: String,
        policy: NetworkAccessPolicy = .init(),
        containing text: String
    ) async {
        do {
            _ = try await execute(json, policy: policy)
            Issue.record("Expected a ToolError")
        } catch let error as ToolError {
            #expect(error.errorDescription?.contains(text) == true, "\(error.errorDescription ?? "nil")")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func reviewsWriteMethodsOnly() async throws {
        let tool = makeTool()
        let post = try await tool.review(
            arguments: Data(#"{"url":"https://example.com/","method":"POST","body":"hello"}"#.utf8),
            context: context()
        )
        #expect(post?.method == "POST")
        #expect(post?.bodyPreview == "hello")
        #expect(post?.headers.isEmpty == true)

        let get = try await tool.review(
            arguments: Data(#"{"url":"https://example.com/"}"#.utf8),
            context: context()
        )
        #expect(get == nil)
    }

    @Test func postsRequestBody() async throws {
        let captured = LockedBox<Data?>(nil)
        StubURLProtocol.setHandler(forHost: "post.example") { request in
            captured.set(requestBody(from: request))
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/plain"]
            )!
            return (response, Data("ok".utf8))
        }
        defer { StubURLProtocol.setHandler(forHost: "post.example", nil) }

        let output = try await execute(
            #"{"url":"https://post.example/","method":"POST","headers":{"Content-Type":"text/plain"},"body":"hello"}"#
        )

        #expect(captured.get() == Data("hello".utf8))
        #expect(output.content.contains("ok"))
    }

    @Test func rejectsBodyOnGet() async {
        await expectToolError(
            #"{"url":"https://example.com/","body":"hello"}"#,
            containing: "do not support a body"
        )
    }

    @Test func extractsHTMLForMarkdownFormat() async throws {
        let html = """
        <html><head><script>alert(1)</script><style>.x{}</style></head>
        <body><h1>Title</h1><p>Hello &amp; welcome.</p>
        <ul><li>One</li><li>Two</li></ul>
        <a href="https://example.com">Link</a></body></html>
        """
        StubURLProtocol.setHandler(
            forHost: "html.example",
            respond(
                status: 200,
                headers: ["Content-Type": "text/html; charset=utf-8"],
                body: html
            )
        )
        defer { StubURLProtocol.setHandler(forHost: "html.example", nil) }

        let output = try await execute(
            #"{"url":"https://html.example/page","format":"markdown"}"#
        )

        #expect(output.content.contains("# Title"))
        #expect(output.content.contains("- One"))
        #expect(output.content.contains("[Link](https://example.com)"))
        #expect(!output.content.contains("alert(1)"))
    }

    @Test func rangeRequestReportsNextOffset() async throws {
        let range = LockedBox<String?>(nil)
        StubURLProtocol.setHandler(forHost: "range.example") { request in
            range.set(request.value(forHTTPHeaderField: "Range"))
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "text/plain",
                    "Content-Range": "bytes 10-19/100",
                    "Accept-Ranges": "bytes"
                ]
            )!
            return (response, Data("abcdefghij".utf8))
        }
        defer { StubURLProtocol.setHandler(forHost: "range.example", nil) }

        let output = try await execute(
            #"{"url":"https://range.example/","offset":10,"max_bytes":1024}"#
        )

        #expect(range.get() == "bytes=10-1033")
        #expect(output.content.contains("content-range: bytes 10-19/100"))
        #expect(output.content.contains("next-offset: 20"))
        #expect(output.content.contains("abcdefghij"))
    }

    @Test func offsetFallsBackWhenServerIgnoresRange() async throws {
        StubURLProtocol.setHandler(
            forHost: "offset.example",
            respond(
                status: 200,
                headers: ["Content-Type": "text/plain"],
                body: "0123456789abc"
            )
        )
        defer { StubURLProtocol.setHandler(forHost: "offset.example", nil) }

        let output = try await execute(
            #"{"url":"https://offset.example/","offset":5,"max_bytes":1024}"#
        )

        #expect(output.content.contains("56789abc"))
        #expect(!output.content.contains("01234"))
    }

    @Test func disabledNetworkBlocksRequests() async {
        await expectToolError(
            #"{"url":"https://example.com/"}"#,
            policy: NetworkAccessPolicy(isEnabled: false),
            containing: "disabled"
        )
    }

    @Test func allowlistBlocksOtherHosts() async throws {
        StubURLProtocol.setHandler(
            forHost: "allow.example",
            respond(status: 200, headers: [:], body: "ok")
        )
        defer { StubURLProtocol.setHandler(forHost: "allow.example", nil) }

        let policy = NetworkAccessPolicy(allowedHosts: ["allow.example"])
        let output = try await execute(#"{"url":"https://allow.example/"}"#, policy: policy)
        #expect(output.content.contains("200 OK"))

        await expectToolError(
            #"{"url":"https://other.example/"}"#,
            policy: policy,
            containing: "not in the allowed hosts list"
        )
    }
}

struct HTMLTextExtractorTests {
    @Test func extractsReadableTextAndMarkdown() {
        let html = """
        <html><body>
        <h2>Heading</h2>
        <p>Hello&nbsp;&amp;&nbsp;welcome &#33;</p>
        <ul><li><a href="https://example.com">Link</a></li></ul>
        <pre>code()</pre>
        </body></html>
        """

        let text = HTMLTextExtractor.extract(html, markdown: false)
        #expect(text.contains("Heading"))
        #expect(text.contains("Hello & welcome !"))
        #expect(text.contains("Link"))
        #expect(text.contains("code()"))

        let markdown = HTMLTextExtractor.extract(html, markdown: true)
        #expect(markdown.contains("## Heading"))
        #expect(markdown.contains("- [Link](https://example.com)"))
    }
}
