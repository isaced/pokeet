import Foundation

/// One HTTP exchange, after redirects.
public struct NetworkResponse: Sendable {
    /// The URL that actually answered — not necessarily the one that was asked for.
    public var url: URL
    public var status: Int
    public var headers: [(String, String)]
    public var body: Data
    public var truncated: Bool
    /// Set when a redirect was refused by policy: the response is the 3xx itself.
    public var redirectNote: String?

    public init(
        url: URL,
        status: Int,
        headers: [(String, String)],
        body: Data,
        truncated: Bool,
        redirectNote: String? = nil
    ) {
        self.url = url
        self.status = status
        self.headers = headers
        self.body = body
        self.truncated = truncated
        self.redirectNote = redirectNote
    }

    public var text: String {
        String(decoding: body, as: UTF8.self)
    }
}

/// The one place the app is allowed to reach the network.
///
/// `http_request` and the script sandboxes both come through here, so policy,
/// redirect handling and byte caps cannot drift apart.
public struct NetworkClient: Sendable {
    public struct Limits: Sendable {
        public var maxBodyBytes: Int
        public var maxRequestBodyBytes: Int
        public var maxRedirects: Int
        public var maxHeaderCount: Int
        public var maxHeaderBytes: Int
        public var requestTimeout: TimeInterval
        public var resourceTimeout: TimeInterval

        public init(
            maxBodyBytes: Int = 20_480,
            maxRequestBodyBytes: Int = 65_536,
            maxRedirects: Int = 5,
            maxHeaderCount: Int = 16,
            maxHeaderBytes: Int = 8_192,
            requestTimeout: TimeInterval = 30,
            resourceTimeout: TimeInterval = 60
        ) {
            self.maxBodyBytes = max(1_024, maxBodyBytes)
            self.maxRequestBodyBytes = max(1_024, maxRequestBodyBytes)
            self.maxRedirects = max(0, maxRedirects)
            self.maxHeaderCount = max(1, maxHeaderCount)
            self.maxHeaderBytes = max(256, maxHeaderBytes)
            self.requestTimeout = max(1, requestTimeout)
            self.resourceTimeout = max(1, resourceTimeout)
        }
    }

    public static let allowedMethods: Set<String> = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"]

    private let session: URLSession
    private let resolver: any HostResolving
    public let limits: Limits
    private let policy = NetworkPolicy()

    public init(session: URLSession? = nil, limits: Limits = Limits()) {
        self.init(session: session, resolver: SystemHostResolver(), limits: limits)
    }

    public init(session: URLSession?, resolver: any HostResolving, limits: Limits) {
        self.session = session ?? Self.makeSession(limits: limits)
        self.resolver = resolver
        self.limits = limits
    }

    public static func makeSession(limits: Limits) -> URLSession {
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

    /// Validates, sends, and follows redirects, re-validating every hop.
    ///
    /// Throws `NetworkPolicyError` when a host is not allowed, and
    /// `NetworkClientError` for transport failures.
    public func fetch(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?,
        offset: Int = 0,
        maxBody: Int? = nil,
        access: NetworkAccessPolicy
    ) async throws -> NetworkResponse {
        let limit = min(max(maxBody ?? limits.maxBodyBytes, 1_024), limits.maxBodyBytes)
        let validatedHeaders = try NetworkPolicy.validateHeaders(
            headers,
            maxCount: limits.maxHeaderCount,
            maxBytes: limits.maxHeaderBytes
        )
        var current = try await policy.validate(url, resolver: resolver, access: access)
        var currentMethod = method
        var currentBody = body
        var currentOffset = offset
        var hops = 0

        while true {
            try Task.checkCancellation()

            let outcome: ResponseOutcome
            do {
                outcome = try await perform(
                    url: current,
                    method: currentMethod,
                    headers: validatedHeaders,
                    body: currentBody,
                    offset: currentOffset,
                    maxBody: limit
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch let error as NetworkClientError {
                throw error
            } catch {
                throw NetworkClientError.transport(error.localizedDescription)
            }

            guard let location = outcome.redirectLocation else {
                return NetworkResponse(
                    url: current,
                    status: outcome.status,
                    headers: outcome.headers,
                    body: outcome.body,
                    truncated: outcome.truncated
                )
            }

            do {
                let target = try NetworkPolicy.redirectTarget(
                    from: current,
                    location: location,
                    hops: hops,
                    maxHops: limits.maxRedirects
                )
                current = try await policy.validate(target, resolver: resolver, access: access)
            } catch {
                // Refusing a hop is not a transport failure: hand back the 3xx so the
                // caller can say why it stopped.
                return NetworkResponse(
                    url: current,
                    status: outcome.status,
                    headers: outcome.headers,
                    body: outcome.body,
                    truncated: outcome.truncated,
                    redirectNote: "Redirect not followed: "
                        + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                )
            }
            if outcome.status == 301 || outcome.status == 302 || outcome.status == 303,
               currentMethod != "GET", currentMethod != "HEAD" {
                currentMethod = "GET"
                currentBody = nil
                currentOffset = 0
            }
            hops += 1
        }
    }

    // MARK: - transport

    private struct ResponseOutcome: Sendable {
        var status: Int
        var headers: [(String, String)]
        var body: Data
        var truncated: Bool
        var redirectLocation: String?
    }

    private func perform(
        url: URL,
        method: String,
        headers: [String: String],
        body requestBody: Data?,
        offset: Int,
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
        if let requestBody, method != "GET", method != "HEAD" {
            request.httpBody = requestBody
        }
        if offset > 0, method == "GET" || method == "HEAD" {
            request.setValue("bytes=\(offset)-\(offset + maxBody - 1)", forHTTPHeaderField: "Range")
        }

        let suppressor = RedirectSuppressor()
        let (bytes, response) = try await session.bytes(for: request, delegate: suppressor)
        guard let http = response as? HTTPURLResponse else {
            throw NetworkClientError.transport("The server returned a non-HTTP response.")
        }

        var responseBody = Data()
        var truncated = false
        if method != "HEAD" {
            let skip = (offset > 0 && http.statusCode != 206) ? offset : 0
            var skipped = 0
            var readCount = 0
            for try await byte in bytes {
                if skipped < skip {
                    skipped += 1
                    continue
                }
                if responseBody.count >= maxBody {
                    truncated = true
                    bytes.task.cancel()
                    break
                }
                responseBody.append(byte)
                readCount += 1
                if readCount % 4_096 == 0 {
                    try Task.checkCancellation()
                }
            }
        }

        let redirectStatuses: Set<Int> = [301, 302, 303, 307, 308]
        let location = http.value(forHTTPHeaderField: "Location")
        return ResponseOutcome(
            status: http.statusCode,
            headers: Self.safeHeaders(from: http),
            body: responseBody,
            truncated: truncated,
            redirectLocation: redirectStatuses.contains(http.statusCode) ? location : nil
        )
    }

    /// Only headers a script has any business seeing: no `Set-Cookie`, no auth echoes.
    static func safeHeaders(from response: HTTPURLResponse) -> [(String, String)] {
        let names = [
            "content-type", "content-length", "location", "date", "last-modified",
            "etag", "cache-control", "www-authenticate", "retry-after", "link",
            "content-range", "accept-ranges"
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

    private static func sanitize(_ value: String) -> String {
        let cleaned = value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\0", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(256))
    }
}

public enum NetworkClientError: Error, Sendable, Equatable, LocalizedError {
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .transport(let message): message
        }
    }
}

/// Refuses every redirect at the URLSession level: the client follows them itself so
/// each hop goes back through `NetworkPolicy`.
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
