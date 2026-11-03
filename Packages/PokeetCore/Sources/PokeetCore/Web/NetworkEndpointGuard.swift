import Foundation

public enum NetworkEndpointError: Error, Sendable, Equatable, LocalizedError {
    case insecureEndpoint(String)
    case invalidHost
    case privateAddress(String)
    case deniedHost(String)

    public var errorDescription: String? {
        switch self {
        case .insecureEndpoint(let scheme):
            "Endpoint must use https (got \(scheme))."
        case .invalidHost:
            "Endpoint must include a valid host."
        case .privateAddress(let address):
            "Endpoint resolves to a private or local address (\(address))."
        case .deniedHost(let host):
            "Endpoint host \(host) is blocked."
        }
    }
}

/// Checks an endpoint the app is configured to call (a user-supplied search or API base URL).
///
/// The model never picks these URLs, so this is a configuration guard rather than an
/// SSRF boundary: literal private addresses and local hostnames are refused, DNS is left
/// to the caller. Model-driven fetches go through `http_request`, which resolves hosts.
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
        guard !NetworkPolicy.isDeniedHostname(host) else {
            throw NetworkEndpointError.deniedHost(host)
        }
        if let literal = NetworkPolicy.addressLiteral(host), NetworkPolicy.isPrivateAddress(literal) {
            throw NetworkEndpointError.privateAddress(literal)
        }
    }
}
