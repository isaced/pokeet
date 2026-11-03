import Foundation
import PokeetCore

/// Brave Search API adapter. The key is read per request, so adding it in Settings
/// takes effect without reopening a session.
struct BraveSearchProvider: WebSearchProviding {
    static let endpoint = URL(string: "https://api.search.brave.com/res/v1/web/search")!
    static let maximumCount = 20

    let displayName = "Brave"

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

        var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: String(min(max(1, limit), Self.maximumCount))),
            URLQueryItem(name: "result_filter", value: "web"),
            URLQueryItem(name: "safesearch", value: "moderate")
        ]
        guard let url = components?.url else {
            throw WebSearchError.malformedResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(key, forHTTPHeaderField: "X-Subscription-Token")

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
        case 401, 403:
            throw WebSearchError.rejectedKey
        case 429:
            throw WebSearchError.rateLimited(retryAfter: WebSearchHTTP.retryAfterSeconds(http))
        default:
            throw WebSearchError.failed("The search provider returned HTTP \(http.statusCode).")
        }

        guard let decoded = try? JSONDecoder().decode(BraveResponse.self, from: data) else {
            throw WebSearchError.malformedResponse
        }

        let results = (decoded.web?.results ?? []).compactMap { item -> WebSearchResult? in
            guard let title = item.title, let rawURL = item.url,
                  let url = URL(string: rawURL), url.scheme?.hasPrefix("http") == true
            else {
                return nil
            }
            return WebSearchResult(
                title: title,
                url: rawURL,
                snippet: item.description ?? "",
                published: item.pageAge.flatMap(WebSearchHTTP.parseDate)
            )
        }
        return Array(results.prefix(max(1, limit)))
    }
}

private struct BraveResponse: Decodable {
    struct Web: Decodable {
        let results: [Item]?
    }

    struct Item: Decodable {
        let title: String?
        let url: String?
        let description: String?
        let pageAge: String?

        enum CodingKeys: String, CodingKey {
            case title
            case url
            case description
            case pageAge = "page_age"
        }
    }

    let web: Web?
}
