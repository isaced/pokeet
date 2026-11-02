import Foundation

public struct HTTPRequestTool: AgentTool {
    public static let toolName = "http_request"

    public struct Limits: Sendable {
        public var maxBodyBytes: Int
        public var maxRedirects: Int
        public var maxHeaderCount: Int
        public var maxHeaderBytes: Int
        public var requestTimeout: TimeInterval
        public var resourceTimeout: TimeInterval

        public init(
            maxBodyBytes: Int = 20_480,
            maxRedirects: Int = 5,
            maxHeaderCount: Int = 16,
            maxHeaderBytes: Int = 8_192,
            requestTimeout: TimeInterval = 30,
            resourceTimeout: TimeInterval = 60
        ) {
            self.maxBodyBytes = max(1_024, maxBodyBytes)
            self.maxRedirects = max(0, maxRedirects)
            self.maxHeaderCount = max(1, maxHeaderCount)
            self.maxHeaderBytes = max(256, maxHeaderBytes)
            self.requestTimeout = max(1, requestTimeout)
            self.resourceTimeout = max(1, resourceTimeout)
        }
    }

    private let session: URLSession
    private let resolver: any HostResolving
    private let limits: Limits
    private let policy = NetworkPolicy()

    public init(session: URLSession? = nil, limits: Limits = Limits()) {
        self.init(session: session, resolver: SystemHostResolver(), limits: limits)
    }

    init(session: URLSession?, resolver: any HostResolving, limits: Limits) {
        self.session = session ?? Self.makeSession(limits: limits)
        self.resolver = resolver
        self.limits = limits
    }

    public var capabilities: Set<ToolCapability> { [.network] }

    public var schema: ToolSchema {
        ToolSchema(
            name: Self.toolName,
            description: """
            Fetch an HTTPS URL with GET or HEAD. Returns the status, selected headers, \
            and a text body preview. Read-only: localhost, private, and link-local addresses are blocked.
            """,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "url": .object([
                        "type": .string("string"),
                        "description": .string("Absolute HTTPS URL to fetch.")
                    ]),
                    "method": .object([
                        "type": .string("string"),
                        "enum": .array([.string("GET"), .string("HEAD")]),
                        "description": .string("HTTP method. Defaults to GET.")
                    ]),
                    "headers": .object([
                        "type": .string("object"),
                        "additionalProperties": .object([
                            "type": .string("string")
                        ]),
                        "description": .string(
                            "Optional request headers. Transport headers such as Host and Content-Length are rejected."
                        )
                    ]),
                    "max_bytes": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum response body bytes to return (1024-20480).")
                    ])
                ]),
                "required": .array([.string("url")]),
                "additionalProperties": .bool(false)
            ])
        )
    }

    public func execute(arguments: Data, context: ToolContext) async throws -> ToolOutput {
        struct Arguments: Decodable {
            var url: String
            var method: String?
            var headers: [String: String]?
            var maxBytes: Int?

            enum CodingKeys: String, CodingKey {
                case url
                case method
                case headers
                case maxBytes = "max_bytes"
            }
        }

        let arguments = try decodeToolArguments(arguments, as: Arguments.self)
        let rawURL = arguments.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: rawURL) else {
            throw ToolError.invalidArguments("Invalid URL: \(rawURL)")
        }

        let method = (arguments.method ?? "GET").uppercased()
        guard method == "GET" || method == "HEAD" else {
            throw ToolError.invalidInput("http_request only supports GET and HEAD.")
        }

        let maxBody = min(
            max(arguments.maxBytes ?? limits.maxBodyBytes, 1_024),
            limits.maxBodyBytes
        )

        let headers: [String: String]
        do {
            headers = try NetworkPolicy.validateHeaders(
                arguments.headers ?? [:],
                maxCount: limits.maxHeaderCount,
                maxBytes: limits.maxHeaderBytes
            )
        } catch {
            throw ToolError.invalidInput(error.localizedDescription)
        }

        var current: URL
        do {
            current = try await policy.validate(url, resolver: resolver)
        } catch {
            throw ToolError.invalidInput(error.localizedDescription)
        }

        var hops = 0
        while true {
            try Task.checkCancellation()

            let outcome: ResponseOutcome
            do {
                outcome = try await performRequest(
                    url: current,
                    method: method,
                    headers: headers,
                    maxBody: maxBody
                )
            } catch let error as ToolError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                throw ToolError.network(error.localizedDescription)
            }

            guard let location = outcome.redirectLocation else {
                return ToolOutput(content: format(outcome, maxBody: maxBody))
            }

            do {
                let target = try NetworkPolicy.redirectTarget(
                    from: current,
                    location: location,
                    hops: hops,
                    maxHops: limits.maxRedirects
                )
                current = try await policy.validate(target, resolver: resolver)
                hops += 1
            } catch {
                return ToolOutput(
                    content: format(
                        outcome,
                        maxBody: maxBody,
                        note: "Redirect not followed: \(error.localizedDescription)"
                    )
                )
            }
        }
    }

    static func makeSession(limits: Limits) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = limits.requestTimeout
        configuration.timeoutIntervalForResource = limits.resourceTimeout
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    private func performRequest(
        url: URL,
        method: String,
        headers: [String: String],
        maxBody: Int
    ) async throws -> ResponseOutcome {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = limits.requestTimeout
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if !headers.keys.contains(where: { $0.caseInsensitiveCompare("User-Agent") == .orderedSame }) {
            request.setValue("Pokeet/http_request", forHTTPHeaderField: "User-Agent")
        }
        if !headers.keys.contains(where: { $0.caseInsensitiveCompare("Accept") == .orderedSame }) {
            request.setValue("*/*", forHTTPHeaderField: "Accept")
        }

        let suppressor = RedirectSuppressor()
        let (bytes, response) = try await session.bytes(for: request, delegate: suppressor)
        guard let http = response as? HTTPURLResponse else {
            throw ToolError.network("The server returned a non-HTTP response.")
        }

        var body = Data()
        var truncated = false
        if method != "HEAD" {
            var readCount = 0
            for try await byte in bytes {
                if body.count >= maxBody {
                    truncated = true
                    bytes.task.cancel()
                    break
                }
                body.append(byte)
                readCount += 1
                if readCount % 4_096 == 0 {
                    try Task.checkCancellation()
                }
            }
        }

        let redirectStatuses: Set<Int> = [301, 302, 303, 307, 308]
        let location = http.value(forHTTPHeaderField: "Location")
        return ResponseOutcome(
            url: url,
            method: method,
            status: http.statusCode,
            headers: safeHeaders(from: http),
            body: body,
            truncated: truncated,
            redirectLocation: redirectStatuses.contains(http.statusCode) ? location : nil
        )
    }

    private func safeHeaders(from response: HTTPURLResponse) -> [(String, String)] {
        let names = [
            "content-type", "content-length", "location", "date", "last-modified",
            "etag", "cache-control", "www-authenticate", "retry-after", "link"
        ]
        var result: [(String, String)] = []
        for name in names {
            if let value = response.value(forHTTPHeaderField: name) {
                result.append((name, sanitize(value)))
            }
        }
        for (key, value) in response.allHeaderFields {
            let name = String(describing: key).lowercased()
            guard name.hasPrefix("x-ratelimit-") else { continue }
            result.append((name, sanitize(String(describing: value))))
        }
        return result
    }

    private func sanitize(_ value: String) -> String {
        let cleaned = value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\0", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(256))
    }

    private func format(_ outcome: ResponseOutcome, maxBody: Int, note: String? = nil) -> String {
        var lines = [
            "HTTP \(outcome.status) \(statusText(outcome.status)) · \(outcome.method) "
                + "\(outcome.url.absoluteString) · \(outcome.body.count) B"
        ]
        for (name, value) in outcome.headers {
            lines.append("\(name): \(value)")
        }
        lines.append("---")

        if let note {
            lines.append(note)
            return lines.joined(separator: "\n")
        }

        if outcome.method == "HEAD" {
            lines.append("(no body)")
        } else if outcome.body.isEmpty {
            lines.append("(empty body)")
        } else if let text = decodeText(outcome) {
            lines.append(text)
            if outcome.truncated {
                lines.append("[body truncated: showing first \(maxBody) bytes]")
            }
        } else {
            lines.append("Body omitted: binary or non-text content (\(outcome.body.count) bytes).")
        }
        return lines.joined(separator: "\n")
    }

    private func statusText(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 206: return "Partial Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 303: return "See Other"
        case 304: return "Not Modified"
        case 307: return "Temporary Redirect"
        case 308: return "Permanent Redirect"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 410: return "Gone"
        case 422: return "Unprocessable Content"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        default: return HTTPURLResponse.localizedString(forStatusCode: status)
        }
    }

    private func decodeText(_ outcome: ResponseOutcome) -> String? {
        let contentType = outcome.headers
            .first(where: { $0.0 == "content-type" })?
            .1
            .lowercased() ?? ""

        let isText = contentType.isEmpty
            || contentType.hasPrefix("text/")
            || contentType.contains("json")
            || contentType.contains("xml")
            || contentType.contains("javascript")
            || contentType.contains("x-www-form-urlencoded")
        guard isText, !outcome.body.contains(0) else {
            return nil
        }

        if let text = String(data: outcome.body, encoding: .utf8) {
            return text
        }
        if contentType.hasPrefix("text/"),
           let text = String(data: outcome.body, encoding: .isoLatin1) {
            return text
        }
        return nil
    }
}

private struct ResponseOutcome {
    let url: URL
    let method: String
    let status: Int
    let headers: [(String, String)]
    let body: Data
    let truncated: Bool
    let redirectLocation: String?
}

private final class RedirectSuppressor: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
