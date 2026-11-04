import Foundation

/// What a script run is allowed to do on the network.
///
/// Scripts reach the network through the host, never through sockets, so this is the
/// only handle the sandbox has on egress. Nil means the run has no network at all.
public struct ScriptNetworkAccess: Sendable {
    public var client: NetworkClient
    public var policy: NetworkAccessPolicy

    public init(client: NetworkClient, policy: NetworkAccessPolicy) {
        self.client = client
        self.policy = policy
    }
}

/// Serves `net.request` to both interpreters.
///
/// One implementation for both so the two sandboxes cannot drift: same policy, same
/// redirect re-validation, same byte cap. The response is JSON because that is the
/// only shape both a QuickJS host call and a CPython module can hand back cheaply.
public struct ScriptNetworkBridge: Sendable {
    private let access: ScriptNetworkAccess

    public init(access: ScriptNetworkAccess) {
        self.access = access
    }

    public func handle(_ argumentsJSON: String) throws -> String {
        struct Arguments: Decodable {
            var url: String
            var method: String?
            var headers: [String: String]?
            var body: String?
        }

        guard let data = argumentsJSON.data(using: .utf8) else {
            throw ScriptRuntimeError.startup("network arguments are not valid UTF-8")
        }
        let arguments: Arguments
        do {
            arguments = try JSONDecoder().decode(Arguments.self, from: data)
        } catch {
            throw ScriptRuntimeError.startup("network arguments are malformed: \(error.localizedDescription)")
        }

        let rawURL = arguments.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: rawURL) else {
            throw ScriptRuntimeError.startup("invalid URL: \(rawURL)")
        }

        let method = (arguments.method ?? "GET").uppercased()
        guard NetworkClient.allowedMethods.contains(method) else {
            throw ScriptRuntimeError.startup("unsupported HTTP method: \(method)")
        }

        var body: Data?
        if let text = arguments.body, !text.isEmpty {
            guard method != "GET", method != "HEAD" else {
                throw ScriptRuntimeError.startup("\(method) requests do not take a body")
            }
            let payload = Data(text.utf8)
            guard payload.count <= access.client.limits.maxRequestBodyBytes else {
                throw ScriptRuntimeError.startup(
                    "request body is \(payload.count) bytes, limit is "
                        + "\(access.client.limits.maxRequestBodyBytes)"
                )
            }
            body = payload
        }

        let response: NetworkResponse
        do {
            response = try access.client.fetchSync(
                url: url,
                method: method,
                headers: arguments.headers ?? [:],
                body: body,
                access: access.policy
            )
        } catch let error as NetworkPolicyError {
            throw ScriptRuntimeError.startup(error.localizedDescription)
        } catch let error as NetworkClientError {
            throw ScriptRuntimeError.startup(error.localizedDescription)
        }

        let payload: [String: Any] = [
            "status": response.status,
            "url": response.url.absoluteString,
            "headers": response.headers.map { [$0.0, $0.1] },
            "body": response.text,
            "truncated": response.truncated,
            "redirectNote": response.redirectNote ?? ""
        ]
        let encoded = try JSONSerialization.data(withJSONObject: payload)
        guard let json = String(data: encoded, encoding: .utf8) else {
            throw ScriptRuntimeError.startup("could not encode the network response")
        }
        return json
    }
}

extension NetworkClient {
    /// Blocking wrapper for the interpreter bridges, which are synchronous by nature.
    func fetchSync(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?,
        access: NetworkAccessPolicy
    ) throws -> NetworkResponse {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        Task.detached {
            do {
                let response = try await fetch(
                    url: url,
                    method: method,
                    headers: headers,
                    body: body,
                    access: access
                )
                box.set(.success(response))
            } catch {
                box.set(.failure(error))
            }
            semaphore.signal()
        }
        // Bounded: the script's own deadline is enforced elsewhere, but a hung request
        // must not hold the interpreter thread forever.
        if semaphore.wait(timeout: .now() + limits.resourceTimeout + 5) == .timedOut {
            throw NetworkClientError.transport("request timed out")
        }
        switch box.value {
        case .success(let response): return response
        case .failure(let error): throw error
        case .none: throw NetworkClientError.transport("request produced no response")
        }
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<NetworkResponse, Error>?

    func set(_ value: Result<NetworkResponse, Error>) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    var value: Result<NetworkResponse, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
