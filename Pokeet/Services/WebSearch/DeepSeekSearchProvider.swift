import Foundation
import PokeetCore

/// DeepSeek Search adapter — `POST https://api.deepseek.com/v1/tools/search`.
///
/// DeepSeek runs its own index behind the same API key as its models. Each hit
/// carries a short `snippet` (100–200 characters, meant for display) and a long
/// `summary` (600–800 characters, explicitly written for a model to read), so
/// the summary is what goes into the transcript. `need_content` stays `false`:
/// page bodies are `http_request`'s job, and leaving them off keeps the request
/// cheap and the prompt small.
struct DeepSeekSearchProvider: WebSearchProviding {
    static let endpoint = URL(string: "https://api.deepseek.com/v1/tools/search")!
    static let maximumResults = 50

    let displayName = "DeepSeek"

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
                count: min(max(1, limit), Self.maximumResults)
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
                "The DeepSeek account has no balance left. Top up, then search again."
            )
        case 429:
            throw WebSearchError.rateLimited(retryAfter: WebSearchHTTP.retryAfterSeconds(http))
        case 408, 500, 504:
            throw WebSearchError.failed(
                "DeepSeek is temporarily unavailable (HTTP \(http.statusCode)). Try again in a moment."
            )
        default:
            throw WebSearchError.failed(
                WebSearchHTTP.providerMessage(data).map { "DeepSeek: \($0)" }
                    ?? "The search provider returned HTTP \(http.statusCode)."
            )
        }

        guard let decoded = try? JSONDecoder().decode(DeepSeekResponse.self, from: data) else {
            throw WebSearchError.malformedResponse
        }

        let results = (decoded.results ?? []).compactMap { item -> WebSearchResult? in
            guard let title = item.title, let rawURL = item.url,
                  let url = URL(string: rawURL), url.scheme?.hasPrefix("http") == true
            else {
                return nil
            }
            let summary = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let short = item.snippet?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return WebSearchResult(
                title: title,
                url: rawURL,
                snippet: summary.isEmpty ? short : summary,
                published: item.date.flatMap(WebSearchHTTP.parseDate)
            )
        }
        return Array(results.prefix(max(1, limit)))
    }

    private struct RequestBody: Encodable {
        let query: String
        let count: Int
        let needContent = false

        enum CodingKeys: String, CodingKey {
            case query
            case count
            case needContent = "need_content"
        }
    }
}

private struct DeepSeekResponse: Decodable {
    struct Item: Decodable {
        let title: String?
        let url: String?
        let snippet: String?
        let summary: String?
        let date: String?
    }

    let results: [Item]?
}
