import Foundation
import Testing
@testable import PokeetCore

@Suite(.serialized)
struct ModelListClientTests {
    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func provider(
        _ protocol: WireProtocol,
        baseURL: String
    ) -> ProviderConfiguration {
        ProviderConfiguration(
            name: "Test",
            wireProtocol: `protocol`,
            baseURL: baseURL
        )
    }

    @Test func fetchesOpenAIModels() async throws {
        let session = makeSession()
        let captured = LockedBox<URLRequest?>(nil)
        StubURLProtocol.setHandler(forHost: "openai.test") { request in
            captured.set(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = #"{"data":[{"id":"beta"},{"id":"alpha"},{"id":"beta"}]}"#
            return (response, Data(body.utf8))
        }
        defer { StubURLProtocol.setHandler(forHost: "openai.test", nil) }

        let models = try await ModelListClient.fetchModels(
            provider: provider(.openAIResponses, baseURL: "https://openai.test/v1"),
            apiKey: "secret",
            session: session
        )

        #expect(models.map(\.id) == ["alpha", "beta"])
        #expect(captured.get()?.url?.absoluteString == "https://openai.test/v1/models")
        #expect(captured.get()?.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    }

    @Test func acceptsStringModelLists() async throws {
        let session = makeSession()
        StubURLProtocol.setHandler(forHost: "compatible.test") { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"models":["custom-b","custom-a"]}"#.utf8))
        }
        defer { StubURLProtocol.setHandler(forHost: "compatible.test", nil) }

        let models = try await ModelListClient.fetchModels(
            provider: provider(.openAIChatCompletions, baseURL: "https://compatible.test/v1"),
            apiKey: "secret",
            session: session
        )

        #expect(models.map(\.id) == ["custom-a", "custom-b"])
    }

    @Test func followsAnthropicPagination() async throws {
        let session = makeSession()
        let requestedURLs = LockedBox<[String]>([])
        StubURLProtocol.setHandler(forHost: "anthropic.test") { request in
            var urls = requestedURLs.get()
            urls.append(request.url?.absoluteString ?? "")
            requestedURLs.set(urls)

            let hasAfter = request.url?.query?.contains("after_id=") == true
            let body: String = hasAfter
                ? #"{"data":[{"id":"m3","display_name":"Third"}],"has_more":false}"#
                : #"{"data":[{"id":"m1","display_name":"First"},{"id":"m2"}],"has_more":true,"last_id":"m2"}"#
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(body.utf8))
        }
        defer { StubURLProtocol.setHandler(forHost: "anthropic.test", nil) }

        let models = try await ModelListClient.fetchModels(
            provider: provider(.anthropicMessages, baseURL: "https://anthropic.test/v1"),
            apiKey: "secret",
            session: session
        )

        #expect(models.map(\.id) == ["m1", "m2", "m3"])
        #expect(requestedURLs.get().count == 2)
        #expect(requestedURLs.get()[1].contains("after_id=m2"))
        #expect(requestedURLs.get().allSatisfy { $0.contains("limit=1000") })
    }

    @Test func fetchesGeminiModelsAndStripsPrefix() async throws {
        let session = makeSession()
        StubURLProtocol.setHandler(forHost: "gemini.test") { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let body = """
            {"models":[
              {"name":"models/gemini-2.5-flash","displayName":"Gemini 2.5 Flash","inputTokenLimit":1048576},
              {"name":"models/gemini-2.5-pro","inputTokenLimit":2097152}
            ]}
            """
            return (response, Data(body.utf8))
        }
        defer { StubURLProtocol.setHandler(forHost: "gemini.test", nil) }

        let models = try await ModelListClient.fetchModels(
            provider: provider(
                .geminiGenerateContent,
                baseURL: "https://gemini.test/v1beta"
            ),
            apiKey: "secret",
            session: session
        )

        #expect(models.map(\.id) == ["gemini-2.5-flash", "gemini-2.5-pro"])
        #expect(models.first?.displayName == "Gemini 2.5 Flash")
        #expect(models.first?.contextWindow == 1_048_576)
    }

    @Test func mapsHTTPErrors() async throws {
        let session = makeSession()
        StubURLProtocol.setHandler(forHost: "error.test") { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"error":{"message":"bad key"}}"#.utf8))
        }
        defer { StubURLProtocol.setHandler(forHost: "error.test", nil) }

        do {
            _ = try await ModelListClient.fetchModels(
                provider: provider(.openAIResponses, baseURL: "https://error.test/v1"),
                apiKey: "secret",
                session: session
            )
            Issue.record("Expected an HTTP error")
        } catch let error as ModelError {
            #expect(error == .http(status: 401, message: "bad key"))
        }
    }

    @Test func requiresAPIKey() async {
        do {
            _ = try await ModelListClient.fetchModels(
                provider: provider(.openAIChatCompletions, baseURL: "https://api.example.com/v1"),
                apiKey: " ",
                session: makeSession()
            )
            Issue.record("Expected notConfigured")
        } catch let error as ModelError {
            #expect(error == .notConfigured)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
