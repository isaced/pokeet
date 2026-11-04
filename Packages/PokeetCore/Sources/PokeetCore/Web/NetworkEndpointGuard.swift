import Foundation

public enum NetworkEndpointError: Error, Sendable, Equatable, LocalizedError {
    case insecureEndpoint(String)
    case invalidHost

    public var errorDescription: String? {
        switch self {
        case .insecureEndpoint(let scheme):
            "Endpoint must use https (got \(scheme))."
        case .invalidHost:
            "Endpoint must include a valid host."
        }
    }
}

/// Checks an endpoint the app is configured to call (a user-supplied search or API base URL).
///
/// The model never picks these URLs, and the user may well be pointing at a local
/// proxy, so the only rule left is https.
public enum NetworkEndpointGuard {
    public static func validate(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else {
            throw NetworkEndpointError.insecureEndpoint("missing")
        }
        guard scheme == "https" else {
            throw NetworkEndpointError.insecureEndpoint(scheme)
        }
        guard let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else {
            throw NetworkEndpointError.invalidHost
        }
        _ = host
    }
}
