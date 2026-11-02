import Foundation

enum ModelHTTP {
    static func normalizedURL(baseURL: String, appending path: String) -> URL? {
        var text = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") {
            text.removeLast()
        }
        guard !text.isEmpty else { return nil }

        let full = text.hasSuffix("/" + path) ? text : text + "/" + path
        return loopbackNormalized(URL(string: full))
    }

    static func geminiURL(
        baseURL: String,
        model: String,
        action: String,
        query: String? = nil
    ) -> URL? {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") {
            base.removeLast()
        }
        guard !base.isEmpty, !model.isEmpty else { return nil }

        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: ":")
        let encodedModel = model.addingPercentEncoding(withAllowedCharacters: allowed) ?? model

        var text = base + "/models/" + encodedModel + ":" + action
        if let query, !query.isEmpty {
            text += "?" + query
        }
        return loopbackNormalized(URL(string: text))
    }

    static func validated(_ url: URL?) -> URL? {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host != nil
        else { return nil }
        return url
    }

    static func loopbackNormalized(_ url: URL?) -> URL? {
        guard let url,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }

        if let host = components.host, host == "127.0.0.1" || host == "::1" || host == "[::1]" {
            components.host = "localhost"
        }
        return components.url ?? url
    }

    static func request(
        url: URL,
        headers: [String: String],
        body: Data? = nil,
        method: String = "POST"
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 120
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = body
        return request
    }

    static func encodeJSON(_ value: JSONValue) throws -> Data {
        let encoder = JSONEncoder()
        // Stable key order keeps upstream prompt caches warm.
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(value)
        } catch {
            throw ModelError.decoding(error.localizedDescription)
        }
    }

    static func errorMessage(from data: Data, fallback: String = "Unknown error") -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any] {
                if let message = error["message"] as? String, !message.isEmpty {
                    return message
                }
                if let type = error["type"] as? String, !type.isEmpty {
                    return type
                }
            }
            if let error = object["error"] as? String, !error.isEmpty {
                return error
            }
            if let message = object["message"] as? String, !message.isEmpty {
                return message
            }
        }

        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            return String(text.prefix(500))
        }
        return fallback
    }

    static func mapTransportError(_ error: Error) -> ModelError {
        if let error = error as? ModelError {
            return error
        }
        if let error = error as? URLError, error.code == .cancelled {
            return .cancelled
        }
        if error is CancellationError {
            return .cancelled
        }
        return .network(error.localizedDescription)
    }

    static func readErrorBody(
        _ bytes: URLSession.AsyncBytes,
        limit: Int = 8_192
    ) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= limit {
                break
            }
        }
        return data
    }
}

enum OpenCodeSession {
    static let headerName = "x-opencode-session"

    static func headers(baseURL: String, sessionID: String?) -> [String: String] {
        guard let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty,
              !sessionID.unicodeScalars.contains(where: {
                  $0.value < 0x20 || $0.value == 0x7F
              }),
              isOpenCodeEndpoint(baseURL)
        else {
            return [:]
        }
        return [headerName: sessionID]
    }

    static func isOpenCodeEndpoint(_ baseURL: String) -> Bool {
        guard let host = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?
            .host?
            .lowercased()
        else {
            return false
        }
        return host == "opencode.ai" || host.hasSuffix(".opencode.ai")
    }
}

enum SSELines {
    static func isDone(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed == "data: [DONE]" || trimmed == "data:[DONE]"
    }

    static func payload(from line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line
            .dropFirst(5)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty, payload != "[DONE]" else { return nil }
        return payload
    }
}
