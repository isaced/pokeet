import Foundation

public enum ModelListClient {
    public static func fetchModels(
        provider: ProviderConfiguration,
        apiKey: String,
        session: URLSession = .shared
    ) async throws -> [ProviderModel] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw ModelError.notConfigured
        }

        switch provider.wireProtocol {
        case .openAIChatCompletions, .openAIResponses:
            return try await fetchOpenAICompatible(
                provider: provider,
                apiKey: key,
                session: session
            )
        case .anthropicMessages:
            return try await fetchAnthropic(
                provider: provider,
                apiKey: key,
                session: session
            )
        case .geminiGenerateContent:
            return try await fetchGemini(
                provider: provider,
                apiKey: key,
                session: session
            )
        }
    }

    private static func fetchOpenAICompatible(
        provider: ProviderConfiguration,
        apiKey: String,
        session: URLSession
    ) async throws -> [ProviderModel] {
        guard let url = ModelHTTP.validated(
            ModelHTTP.normalizedURL(baseURL: provider.baseURL, appending: "models")
        ) else {
            throw ModelError.notConfigured
        }

        let request = ModelHTTP.request(
            url: url,
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "Accept": "application/json"
            ],
            method: "GET"
        )
        let data = try await send(request, session: session)

        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            throw ModelError.decoding("Model list is not valid JSON.")
        }

        var models: [ProviderModel] = []
        if let array = root as? [Any] {
            models = parseModelArray(array)
        } else if let object = root as? [String: Any] {
            if let array = object["data"] as? [Any] {
                models = parseModelArray(array)
            } else if let array = object["models"] as? [Any] {
                models = parseModelArray(array)
            }
        }

        return deduplicated(models)
    }

    private static func fetchAnthropic(
        provider: ProviderConfiguration,
        apiKey: String,
        session: URLSession
    ) async throws -> [ProviderModel] {
        guard let modelsURL = ModelHTTP.validated(
            ModelHTTP.normalizedURL(baseURL: provider.baseURL, appending: "models")
        ),
        var components = URLComponents(
            url: modelsURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw ModelError.notConfigured
        }

        var models: [ProviderModel] = []
        var afterID: String?
        let pageLimit = 3

        for _ in 0..<pageLimit {
            var queryItems = [URLQueryItem(name: "limit", value: "1000")]
            if let afterID {
                queryItems.append(URLQueryItem(name: "after_id", value: afterID))
            }
            components.queryItems = queryItems
            guard let url = components.url else { throw ModelError.notConfigured }

            let request = ModelHTTP.request(
                url: url,
                headers: [
                    "x-api-key": apiKey,
                    "anthropic-version": "2023-06-01",
                    "Accept": "application/json"
                ],
                method: "GET"
            )
            let data = try await send(request, session: session)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let array = object["data"] as? [Any]
            else {
                throw ModelError.decoding("Anthropic model list is not valid JSON.")
            }

            models.append(contentsOf: parseModelArray(array))
            guard object["has_more"] as? Bool == true,
                  let lastID = object["last_id"] as? String,
                  !lastID.isEmpty,
                  lastID != afterID
            else { break }
            afterID = lastID
        }

        return deduplicated(models)
    }

    private static func fetchGemini(
        provider: ProviderConfiguration,
        apiKey: String,
        session: URLSession
    ) async throws -> [ProviderModel] {
        guard let url = ModelHTTP.validated(
            ModelHTTP.normalizedURL(baseURL: provider.baseURL, appending: "models")
        ) else {
            throw ModelError.notConfigured
        }

        let request = ModelHTTP.request(
            url: url,
            headers: [
                "x-goog-api-key": apiKey,
                "Accept": "application/json"
            ],
            method: "GET"
        )
        let data = try await send(request, session: session)

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let array = object["models"] as? [Any]
        else {
            throw ModelError.decoding("Gemini model list is not valid JSON.")
        }

        let models = array.compactMap { item -> ProviderModel? in
            guard let dictionary = item as? [String: Any],
                  let rawName = dictionary["name"] as? String,
                  !rawName.isEmpty
            else { return nil }

            let id = rawName.hasPrefix("models/")
                ? String(rawName.dropFirst("models/".count))
                : rawName
            return ProviderModel(
                id: id,
                displayName: dictionary["displayName"] as? String,
                contextWindow: dictionary["inputTokenLimit"] as? Int
            )
        }

        return deduplicated(models)
    }

    private static func send(_ request: URLRequest, session: URLSession) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ModelError.invalidResponse("Missing HTTP response")
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw ModelError.http(
                    status: httpResponse.statusCode,
                    message: ModelHTTP.errorMessage(from: data)
                )
            }
            return data
        } catch {
            throw ModelHTTP.mapTransportError(error)
        }
    }

    private static func parseModelArray(_ array: [Any]) -> [ProviderModel] {
        array.compactMap { item in
            if let id = item as? String, !id.isEmpty {
                return ProviderModel(id: id)
            }
            guard let dictionary = item as? [String: Any],
                  let id = dictionary["id"] as? String,
                  !id.isEmpty
            else { return nil }

            let displayName = dictionary["display_name"] as? String
                ?? dictionary["displayName"] as? String
                ?? dictionary["name"] as? String
            let contextWindow = dictionary["context_length"] as? Int
                ?? dictionary["context_window"] as? Int
                ?? dictionary["inputTokenLimit"] as? Int

            return ProviderModel(
                id: id,
                displayName: displayName,
                contextWindow: contextWindow
            )
        }
    }

    private static func deduplicated(_ models: [ProviderModel]) -> [ProviderModel] {
        var seen = Set<String>()
        return models
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }
}
