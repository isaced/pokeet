import Foundation
import Testing
@testable import PokeetCore

struct NetworkPolicyTests {
    private struct StubResolver: HostResolving {
        var addresses: [String: [String]] = [:]
        var fallback: [String] = ["93.184.216.34"]

        func resolve(host: String) async throws -> [String] {
            if let resolved = addresses[host.lowercased()] {
                return resolved
            }
            return fallback
        }
    }

    @Test func allowsPublicHTTPSURL() async throws {
        let policy = NetworkPolicy()
        let url = try await policy.validate(
            URL(string: "https://example.com/path#fragment")!,
            resolver: StubResolver()
        )

        #expect(url.absoluteString == "https://example.com/path")
    }

    @Test func rejectsNonHTTPSAndCredentials() {
        let policy = NetworkPolicy()

        #expect(throws: NetworkPolicyError.self) {
            _ = try policy.normalize(URL(string: "http://example.com")!)
        }
        #expect(throws: NetworkPolicyError.self) {
            _ = try policy.normalize(URL(string: "https://user:pass@example.com")!)
        }
    }

    @Test func rejectsLocalHostnames() {
        for host in [
            "localhost", "localhost.", "api.localhost", "printer.local",
            "service.internal", "router.home.arpa", "foo.lan",
            "metadata.google.internal", "instance-data"
        ] {
            #expect(NetworkPolicy.isDeniedHostname(host), "expected \(host) to be denied")
        }
        #expect(!NetworkPolicy.isDeniedHostname("example.com"))
        #expect(!NetworkPolicy.isDeniedHostname("api.github.com"))
    }

    @Test func classifiesPrivateIPv4() {
        for address in [
            "0.0.0.0", "10.1.2.3", "100.64.0.1", "127.0.0.1",
            "169.254.169.254", "172.16.0.1", "172.31.255.255", "192.168.1.1",
            "192.0.0.1", "192.0.2.1", "198.18.0.1", "198.51.100.1",
            "203.0.113.1", "224.0.0.1", "255.255.255.255"
        ] {
            #expect(NetworkPolicy.isPrivateAddress(address), "expected \(address) to be private")
        }

        for address in ["8.8.8.8", "1.1.1.1", "93.184.216.34", "172.32.0.1"] {
            #expect(!NetworkPolicy.isPrivateAddress(address), "expected \(address) to be public")
        }
    }

    @Test func classifiesPrivateIPv6() {
        for address in [
            "::", "::1", "fc00::1", "fd12:3456::1", "fe80::1", "ff02::1",
            "::ffff:127.0.0.1", "::ffff:10.0.0.1"
        ] {
            #expect(NetworkPolicy.isPrivateAddress(address), "expected \(address) to be private")
        }
        #expect(!NetworkPolicy.isPrivateAddress("2606:4700:4700::1111"))
    }

    @Test func rejectsPrivateLiteralHosts() async {
        let policy = NetworkPolicy()
        for url in [
            "https://127.0.0.1/", "https://10.0.0.1/", "https://169.254.169.254/",
            "https://[::1]/", "https://[fe80::1]/"
        ] {
            await expectPolicyError {
                _ = try await policy.validate(URL(string: url)!, resolver: StubResolver())
            }
        }
    }

    @Test func rejectsHostnamesResolvingToPrivateAddresses() async {
        let resolver = StubResolver(addresses: [
            "example.com": ["93.184.216.34", "10.0.0.1"]
        ])
        await expectPolicyError {
            _ = try await NetworkPolicy().validate(
                URL(string: "https://example.com/")!,
                resolver: resolver
            )
        }
    }

    @Test func rejectsObfuscatedNumericHostsThatResolveInternally() async {
        let resolver = StubResolver(addresses: [
            "0x7f000001": ["127.0.0.1"],
            "2130706433": ["127.0.0.1"]
        ])
        for host in ["0x7f000001", "2130706433"] {
            await expectPolicyError {
                _ = try await NetworkPolicy().validate(
                    URL(string: "https://\(host)/")!,
                    resolver: resolver
                )
            }
        }
    }

    @Test func redirectRules() throws {
        let current = URL(string: "https://example.com/start")!

        let relative = try NetworkPolicy.redirectTarget(
            from: current,
            location: "/next",
            hops: 0,
            maxHops: 5
        )
        #expect(relative.absoluteString == "https://example.com/next")

        let sameOrigin = try NetworkPolicy.redirectTarget(
            from: current,
            location: "https://example.com:443/other",
            hops: 0,
            maxHops: 5
        )
        #expect(sameOrigin.absoluteString == "https://example.com:443/other")

        #expect(throws: NetworkPolicyError.self) {
            _ = try NetworkPolicy.redirectTarget(
                from: current,
                location: "https://other.example/",
                hops: 0,
                maxHops: 5
            )
        }
        #expect(throws: NetworkPolicyError.self) {
            _ = try NetworkPolicy.redirectTarget(
                from: current,
                location: "http://example.com/",
                hops: 0,
                maxHops: 5
            )
        }
        #expect(throws: NetworkPolicyError.self) {
            _ = try NetworkPolicy.redirectTarget(
                from: current,
                location: "/next",
                hops: 5,
                maxHops: 5
            )
        }
    }

    @Test func headerValidation() throws {
        let headers = try NetworkPolicy.validateHeaders(
            ["Authorization": "Bearer test", "Cookie": "a=1", "Accept": "*/*"],
            maxCount: 16,
            maxBytes: 8_192
        )
        #expect(headers["Authorization"] == "Bearer test")
        #expect(headers["Cookie"] == "a=1")

        for denied in ["Host", "Content-Length", "Connection", "Proxy-Authorization"] {
            #expect(throws: NetworkPolicyError.self) {
                _ = try NetworkPolicy.validateHeaders(
                    [denied: "value"],
                    maxCount: 16,
                    maxBytes: 8_192
                )
            }
        }

        #expect(throws: NetworkPolicyError.self) {
            _ = try NetworkPolicy.validateHeaders(
                ["X-Test": "value\r\nInjected: 1"],
                maxCount: 16,
                maxBytes: 8_192
            )
        }
        #expect(throws: NetworkPolicyError.self) {
            _ = try NetworkPolicy.validateHeaders(
                ["X-Test": "1", "x-test": "2"],
                maxCount: 16,
                maxBytes: 8_192
            )
        }
        #expect(throws: NetworkPolicyError.self) {
            _ = try NetworkPolicy.validateHeaders(
                ["X-Test": String(repeating: "a", count: 9_000)],
                maxCount: 16,
                maxBytes: 8_192
            )
        }
        #expect(throws: NetworkPolicyError.self) {
            _ = try NetworkPolicy.validateHeaders(
                Dictionary(uniqueKeysWithValues: (0..<17).map { ("X-\($0)", "v") }),
                maxCount: 16,
                maxBytes: 8_192
            )
        }
    }

    private func expectPolicyError(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            Issue.record("Expected a NetworkPolicyError")
        } catch is NetworkPolicyError {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
