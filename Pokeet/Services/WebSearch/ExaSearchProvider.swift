import Foundation
import PokeetCore

/// Exa Search adapter — `POST https://api.exa.ai/search`.
///
/// Exa takes a natural-language query and returns ranked pages with excerpts
/// sized to each result's relevance. `contents.highlights` is requested instead
/// of full `text`: highlights are free, token-efficient and already the shape
/// the agent reads, while page bodies stay `http_request`'s job. `type: auto` is
/// the balanced default — `deep` buys better synthesis at 4–15 seconds, the
/// wrong trade inside a tool call.
struct ExaSearchProvider: WebSearchProviding {
    static let endpoint = URL(string: "https://api.exa.ai/search")!
    static let maximumResults = 100

    let displayName = "Exa"

    private let secrets: any SecretStore
    private let keyName: String
    private let session: URLSession

    init(
        secrets: any SecretStore,
        keyName: String,
        session: URLSession = .shared
    ) {
        self.secrets = secrets
        self.keyName = keyName
        self.session = session
    }

    func search(query: String, limit: Int) async throws -> [WebSearchResult] {
        let key = (secrets.string(for: keyName) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw WebSearchError.notConfigured
        }
        try NetworkEndpointGuard.validate(Self.endpoint)

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(
            RequestBody(
                query: query,
                numResults: min(max(1, limit), Self.maximumResults)
            )
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw WebSearchError.failed(
                "Could not reach the search provider: \(error.localizedDescription)"
            )
        }

        guard let http = response as? HTTPURLResponse else {
            throw WebSearchError.malformedResponse
        }
        switch http.statusCode {
        case 200...299:
            break
        case 401:
            throw WebSearchError.rejectedKey
        case 402:
            throw WebSearchError.failed(
                "Exa credits are exhausted. Top up, then search again."
            )
        case 429:
            throw WebSearchError.rateLimited(retryAfter: WebSearchHTTP.retryAfterSeconds(http))
        case 500, 503, 504:
            throw WebSearchError.failed(
                "Exa is temporarily unavailable (HTTP \(http.statusCode)). Try again in a moment."
            )
        default:
            throw WebSearchError.failed(
                WebSearchHTTP.providerMessage(data).map { "Exa: \($0)" }
                    ?? "The search provider returned HTTP \(http.statusCode)."
            )
        }

        guard let decoded = try? JSONDecoder().decode(ExaResponse.self, from: data) else {
            throw WebSearchError.malformedResponse
        }

        let results = (decoded.results ?? []).compactMap { item -> WebSearchResult? in
            guard let title = item.title, let rawURL = item.url,
                  let url = URL(string: rawURL), url.scheme?.hasPrefix("http") == true
            else {
                return nil
            }
            let excerpt = (item.highlights ?? [])
                .prefix(3)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " … ")
            let snippet = excerpt.isEmpty
                ? (item.summary ?? item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                : excerpt
            return WebSearchResult(
                title: title,
                url: rawURL,
                snippet: snippet,
                published: item.publishedDate.flatMap(WebSearchHTTP.parseDate)
            )
        }
        return Array(results.prefix(max(1, limit)))
    }

    private struct RequestBody: Encodable {
        struct Contents: Encodable {
            let highlights: Bool
        }

        let query: String
        let type = "auto"
        let numResults: Int
        let contents: Contents

        init(query: String, numResults: Int) {
            self.query = query
            self.numResults = numResults
            self.contents = Contents(highlights: true)
        }
    }
}

private struct ExaResponse: Decodable {
    struct Item: Decodable {
        let title: String?
        let url: String?
        let publishedDate: String?
        let highlights: [String]?
        let summary: String?
        let text: String?
    }

    let results: [Item]?
}
