import Darwin
import Foundation

public protocol HostResolving: Sendable {
    /// Returns numeric IPv4/IPv6 addresses for `host`.
    func resolve(host: String) async throws -> [String]
}

public struct SystemHostResolver: HostResolving {
    public init() {}

    public func resolve(host: String) async throws -> [String] {
        try await Task.detached(priority: .utility) {
            try Self.lookup(host)
        }.value
    }

    private static func lookup(_ host: String) throws -> [String] {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let first = result else {
            throw NetworkPolicyError.resolutionFailed(
                host: host,
                message: String(cString: gai_strerror(status))
            )
        }
        defer { freeaddrinfo(first) }

        var addresses: [String] = []
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let current = node {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let nameStatus = getnameinfo(
                current.pointee.ai_addr,
                current.pointee.ai_addrlen,
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if nameStatus == 0 {
                let length = buffer.firstIndex(of: 0) ?? buffer.count
                let address = String(
                    decoding: buffer[..<length].map { UInt8(bitPattern: $0) },
                    as: UTF8.self
                )
                addresses.append(address)
            }
            node = current.pointee.ai_next
        }
        return addresses
    }
}

enum NetworkPolicyError: Error, Sendable, Equatable, LocalizedError {
    case unsupportedScheme(String)
    case invalidHost
    case credentialsInURL
    case deniedHost(String)
    case privateAddress(String)
    case resolutionFailed(host: String, message: String)
    case invalidHeader(String)
    case tooManyRedirects
    case crossOriginRedirect(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedScheme(let scheme):
            "http_request only supports https URLs (got \(scheme))."
        case .invalidHost:
            "The URL must include a valid host."
        case .credentialsInURL:
            "Remove the username or password from the URL and pass credentials as headers instead."
        case .deniedHost(let host):
            "Network access to \(host) is blocked."
        case .privateAddress(let address):
            "Network access to private or local address \(address) is blocked."
        case .resolutionFailed(let host, let message):
            "Could not resolve \(host): \(message)"
        case .invalidHeader(let message):
            "Invalid header: \(message)"
        case .tooManyRedirects:
            "The request exceeded the redirect limit."
        case .crossOriginRedirect(let target):
            "Redirect to a different origin is blocked: \(target)"
        }
    }
}

struct NetworkPolicy: Sendable {
    func normalize(_ url: URL) throws -> URL {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else {
            throw NetworkPolicyError.unsupportedScheme("missing")
        }
        guard scheme == "https" else {
            throw NetworkPolicyError.unsupportedScheme(scheme)
        }
        guard url.user == nil, url.password == nil else {
            throw NetworkPolicyError.credentialsInURL
        }
        guard let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty
        else {
            throw NetworkPolicyError.invalidHost
        }
        guard !Self.isDeniedHostname(host) else {
            throw NetworkPolicyError.deniedHost(host)
        }
        if let literal = Self.addressLiteral(host), Self.isPrivateAddress(literal) {
            throw NetworkPolicyError.privateAddress(literal)
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        guard let normalized = components?.url else {
            throw NetworkPolicyError.invalidHost
        }
        return normalized
    }

    func validate(_ url: URL, resolver: any HostResolving) async throws -> URL {
        let normalized = try normalize(url)
        guard let host = normalized.host else {
            throw NetworkPolicyError.invalidHost
        }

        let addresses: [String]
        do {
            addresses = try await resolver.resolve(host: host)
        } catch let error as NetworkPolicyError {
            throw error
        } catch {
            throw NetworkPolicyError.resolutionFailed(
                host: host,
                message: error.localizedDescription
            )
        }

        guard !addresses.isEmpty else {
            throw NetworkPolicyError.resolutionFailed(host: host, message: "No addresses returned.")
        }
        for address in addresses where Self.isPrivateAddress(address) {
            throw NetworkPolicyError.privateAddress(address)
        }
        return normalized
    }

    static func isDeniedHostname(_ host: String) -> Bool {
        var name = host.lowercased()
        while name.hasSuffix(".") {
            name.removeLast()
        }
        guard !name.isEmpty else { return true }

        if name == "localhost" || name.hasSuffix(".localhost") {
            return true
        }
        let deniedSuffixes = [".local", ".internal", ".home.arpa", ".lan", ".localdomain", ".intranet"]
        if deniedSuffixes.contains(where: { name.hasSuffix($0) }) {
            return true
        }
        return ["metadata.google.internal", "instance-data", "metadata"].contains(name)
    }

    static func isPrivateAddress(_ address: String) -> Bool {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("[") && text.hasSuffix("]") {
            text = String(text.dropFirst().dropLast())
        }
        if let zone = text.firstIndex(of: "%") {
            text = String(text[..<zone])
        }

        if let octets = ipv4Octets(text) {
            return isPrivateIPv4(octets)
        }
        if let bytes = ipv6Bytes(text) {
            return isPrivateIPv6(bytes)
        }
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
        guard target.scheme?.lowercased() == current.scheme?.lowercased(),
              target.host?.lowercased() == current.host?.lowercased(),
              effectivePort(target) == effectivePort(current)
        else {
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

    private static func addressLiteral(_ host: String) -> String? {
        var text = host
        if text.hasPrefix("[") && text.hasSuffix("]") {
            text = String(text.dropFirst().dropLast())
        }
        if ipv4Octets(text) != nil || ipv6Bytes(text) != nil {
            return text
        }
        return nil
    }

    private static func ipv4Octets(_ address: String) -> [UInt8]? {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }

        var octets: [UInt8] = []
        for part in parts {
            guard !part.isEmpty,
                  part.count <= 3,
                  part.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  let value = Int(part),
                  (0...255).contains(value)
            else {
                return nil
            }
            octets.append(UInt8(value))
        }
        return octets
    }

    private static func ipv6Bytes(_ address: String) -> [UInt8]? {
        var raw = in6_addr()
        guard !address.isEmpty, inet_pton(AF_INET6, address, &raw) == 1 else {
            return nil
        }
        return withUnsafeBytes(of: &raw) { Array($0) }
    }

    private static func isPrivateIPv4(_ octets: [UInt8]) -> Bool {
        let a = octets[0]
        let b = octets[1]
        let c = octets[2]

        if a == 0 || a == 10 || a == 127 { return true }
        if a == 100 && (64...127).contains(b) { return true }
        if a == 169 && b == 254 { return true }
        if a == 172 && (16...31).contains(b) { return true }
        if a == 192 && b == 168 { return true }
        if a == 192 && b == 0 && (c == 0 || c == 2) { return true }
        if a == 198 && (b == 18 || b == 19) { return true }
        if a == 198 && b == 51 && c == 100 { return true }
        if a == 203 && b == 0 && c == 113 { return true }
        if a >= 224 { return true }
        return false
    }

    private static func isPrivateIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }

        if bytes.allSatisfy({ $0 == 0 }) { return true }
        if bytes.prefix(15).allSatisfy({ $0 == 0 }), bytes[15] == 1 { return true }
        if bytes[0] & 0xFE == 0xFC { return true }
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return true }
        if bytes[0] == 0xFF { return true }

        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            return isPrivateIPv4(Array(bytes[12..<16]))
        }
        if bytes[0..<12].allSatisfy({ $0 == 0 }), !bytes[12..<16].allSatisfy({ $0 == 0 }) {
            return isPrivateIPv4(Array(bytes[12..<16]))
        }
        return false
    }
}
