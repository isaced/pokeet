import Darwin
import Foundation

public struct NetworkAccessPolicy: Sendable, Equatable {
    public var isEnabled: Bool
    public var allowedHosts: Set<String>

    public init(isEnabled: Bool = true, allowedHosts: Set<String> = []) {
        self.isEnabled = isEnabled
        self.allowedHosts = allowedHosts
    }
}

enum NetworkPolicyError: Error, Sendable, Equatable, LocalizedError {
    case unsupportedScheme(String)
    case invalidHost
    case credentialsInURL
    case invalidHeader(String)
    case tooManyRedirects
    case crossOriginRedirect(String)
    case networkDisabled
    case hostNotAllowed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedScheme(let scheme):
            "http_request only supports https URLs (got \(scheme))."
        case .invalidHost:
            "The URL must include a valid host."
        case .credentialsInURL:
            "Remove the username or password from the URL and pass credentials as headers instead."
        case .invalidHeader(let message):
            "Invalid header: \(message)"
        case .tooManyRedirects:
            "The request exceeded the redirect limit."
        case .crossOriginRedirect(let target):
            "Redirect to a different origin is blocked: \(target)"
        case .networkDisabled:
            "Network access is disabled in settings."
        case .hostNotAllowed(let host):
            "Network access to \(host) is not in the allowed hosts list."
        }
    }
}

struct NetworkPolicy: Sendable {
    func normalize(_ url: URL) throws -> URL {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else {
            throw NetworkPolicyError.unsupportedScheme("missing")
        }
        guard url.user == nil, url.password == nil else {
            throw NetworkPolicyError.credentialsInURL
        }
        guard let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty
        else {
            throw NetworkPolicyError.invalidHost
        }
        // Plain HTTP is allowed only to somewhere on this network: a dev server, a NAS,
        // a router. Anywhere else the request would put the token and the body in the
        // clear across a network nobody controls.
        switch scheme {
        case "https":
            break
        case "http" where Self.isLocalTarget(host):
            break
        default:
            throw NetworkPolicyError.unsupportedScheme(scheme)
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        guard let normalized = components?.url else {
            throw NetworkPolicyError.invalidHost
        }
        return normalized
    }

    func validate(_ url: URL, access: NetworkAccessPolicy = .init()) throws -> URL {
        guard access.isEnabled else {
            throw NetworkPolicyError.networkDisabled
        }
        let normalized = try normalize(url)
        guard let host = normalized.host else {
            throw NetworkPolicyError.invalidHost
        }

        if !access.allowedHosts.isEmpty {
            var allowed = false
            var candidate = host.lowercased()
            while candidate.hasSuffix(".") {
                candidate.removeLast()
            }
            for entry in access.allowedHosts {
                var hostEntry = entry.lowercased()
                while hostEntry.hasSuffix(".") {
                    hostEntry.removeLast()
                }
                guard !hostEntry.isEmpty else { continue }
                if candidate == hostEntry || candidate.hasSuffix("." + hostEntry) {
                    allowed = true
                    break
                }
            }
            guard allowed else {
                throw NetworkPolicyError.hostNotAllowed(host)
            }
        }

        return normalized
    }

    /// True when `host` is a literal name or address on the local network.
    ///
    /// Deliberately does not resolve: a resolved answer is whatever the network says
    /// today — behind a fake-IP proxy every name lands in 198.18.0.0/15 — so the decision
    /// has to come from what the URL literally says.
    static func isLocalTarget(_ host: String) -> Bool {
        var name = host.lowercased()
        while name.hasSuffix(".") {
            name.removeLast()
        }
        guard !name.isEmpty else { return false }

        if name == "localhost" || name.hasSuffix(".localhost") { return true }
        if name.hasSuffix(".local") || name.hasSuffix(".lan") { return true }

        if let octets = ipv4Octets(name) {
            if octets[0] == 10 || octets[0] == 127 { return true }
            if octets[0] == 172, (16...31).contains(octets[1]) { return true }
            if octets[0] == 192, octets[1] == 168 { return true }
            if octets[0] == 169, octets[1] == 254 { return true }
            return false
        }
        if name.contains(":") {
            return isLocalIPv6(name)
        }
        // An unqualified name — `nas`, `router` — only resolves inside the LAN.
        return !name.contains(".")
    }

    private static func ipv4Octets(_ address: String) -> [UInt8]? {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 3,
                  part.allSatisfy(\.isNumber), let value = UInt8(part)
            else { return nil }
            octets.append(value)
        }
        return octets
    }

    private static func isLocalIPv6(_ address: String) -> Bool {
        var raw = in6_addr()
        guard inet_pton(AF_INET6, address, &raw) == 1 else { return false }
        let bytes = withUnsafeBytes(of: &raw) { Array($0) }
        if bytes.allSatisfy({ $0 == 0 }) { return true }                 // ::
        if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes[15] == 1 { return true }  // ::1
        if bytes[0] & 0xFE == 0xFC { return true }                        // fc00::/7
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return true }      // fe80::/10
        return false
    }

    static func redirectTarget(
        from current: URL,
        location: String,
        hops: Int,
        maxHops: Int
    ) throws -> URL {
        guard hops < maxHops else {
            throw NetworkPolicyError.tooManyRedirects
        }
        let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let target = URL(string: trimmed, relativeTo: current)?.absoluteURL
        else {
            throw NetworkPolicyError.invalidHost
        }
        let fromScheme = current.scheme?.lowercased()
        let toScheme = target.scheme?.lowercased()
        let sameHost = target.host?.lowercased() == current.host?.lowercased()
        let upgrade = fromScheme == "http" && toScheme == "https"
        let samePort = effectivePort(target) == effectivePort(current)
            // An upgrade moves 80 -> 443 by definition; that is not a different origin.
            || (upgrade && current.port == nil && target.port == nil)
        guard sameHost, samePort, upgrade || fromScheme == toScheme else {
            throw NetworkPolicyError.crossOriginRedirect(target.absoluteString)
        }
        return target
    }

    static func validateHeaders(
        _ headers: [String: String],
        maxCount: Int,
        maxBytes: Int
    ) throws -> [String: String] {
        guard headers.count <= maxCount else {
            throw NetworkPolicyError.invalidHeader("At most \(maxCount) headers are allowed.")
        }

        let deniedHeaders: Set<String> = [
            "host", "content-length", "transfer-encoding", "connection",
            "upgrade", "accept-encoding", "expect", "te", "trailer", "keep-alive"
        ]
        let tokenCharacters = CharacterSet(
            charactersIn: "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
        )

        var result: [String: String] = [:]
        var seen = Set<String>()
        var totalBytes = 0

        for (rawName, rawValue) in headers {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !name.isEmpty,
                  name.unicodeScalars.allSatisfy(tokenCharacters.contains)
            else {
                throw NetworkPolicyError.invalidHeader("invalid name \"\(rawName)\".")
            }

            let lowercasedName = name.lowercased()
            guard !deniedHeaders.contains(lowercasedName),
                  !lowercasedName.hasPrefix("proxy-")
            else {
                throw NetworkPolicyError.invalidHeader("\(name) is managed by the transport.")
            }
            guard seen.insert(lowercasedName).inserted else {
                throw NetworkPolicyError.invalidHeader("duplicate header \(name).")
            }
            guard value.unicodeScalars.allSatisfy({
                $0.isASCII && $0.value != 0x0D && $0.value != 0x0A && $0.value != 0x00
            }) else {
                throw NetworkPolicyError.invalidHeader("\(name) contains invalid characters.")
            }

            totalBytes += name.utf8.count + value.utf8.count + 4
            guard totalBytes <= maxBytes else {
                throw NetworkPolicyError.invalidHeader("headers exceed \(maxBytes) bytes.")
            }
            result[name] = value
        }
        return result
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port {
            return port
        }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

}
