import Foundation
import PokeetCore

/// Tavily Search adapter — `POST https://api.tavily.com/search`.
///
/// Tavily is built for agents: it returns cleaned snippets per URL, so the agent
/// usually needs fewer follow-up fetches. `include_answer` stays off (the agent
/// writes its own answer from the results) and `auto_parameters` stays off too,
/// because it can silently upgrade the request to a 2-credit search.
struct TavilySearchProvider: WebSearchProviding {
    static let endpoint = URL(string: "https://api.tavily.com/search")!
    static let maximumResults = 20

    let displayName = "Tavily"

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
                maxResults: min(max(1, limit), Self.maximumResults)
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
        case 429:
            throw WebSearchError.rateLimited(retryAfter: WebSearchHTTP.retryAfterSeconds(http))
        case 432, 433, 434:
            throw WebSearchError.failed(
                WebSearchHTTP.providerMessage(data).map { "Tavily: \($0)" }
                    ?? "This Tavily plan or key has reached its usage limit."
            )
        default:
            throw WebSearchError.failed(
                WebSearchHTTP.providerMessage(data).map { "Tavily: \($0)" }
                    ?? "The search provider returned HTTP \(http.statusCode)."
            )
        }

        guard let decoded = try? JSONDecoder().decode(TavilyResponse.self, from: data) else {
            throw WebSearchError.malformedResponse
        }

        let results = (decoded.results ?? []).compactMap { item -> WebSearchResult? in
            guard let title = item.title, let rawURL = item.url,
                  let url = URL(string: rawURL), url.scheme?.hasPrefix("http") == true
            else {
                return nil
            }
            return WebSearchResult(
                title: title,
                url: rawURL,
                snippet: item.content ?? "",
                published: item.publishedDate.flatMap(WebSearchHTTP.parseDate)
            )
        }
        return Array(results.prefix(max(1, limit)))
    }

    private struct RequestBody: Encodable {
        let query: String
        let maxResults: Int
        let searchDepth = "basic"
        let includeAnswer = false
        let includeRawContent = false
        let includePublishedDate = true

        enum CodingKeys: String, CodingKey {
            case query
            case maxResults = "max_results"
            case searchDepth = "search_depth"
            case includeAnswer = "include_answer"
            case includeRawContent = "include_raw_content"
            case includePublishedDate = "include_published_date"
        }
    }
}

private struct TavilyResponse: Decodable {
    struct Item: Decodable {
        let title: String?
        let url: String?
        let content: String?
        let publishedDate: String?

        enum CodingKeys: String, CodingKey {
            case title
            case url
            case content
            case publishedDate = "published_date"
        }
    }

    let results: [Item]?
}
