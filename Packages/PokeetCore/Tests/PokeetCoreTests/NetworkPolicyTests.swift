import Foundation
import Testing
@testable import PokeetCore

struct NetworkPolicyTests {
    @Test func allowsPublicHTTPSURL() throws {
        let policy = NetworkPolicy()
        let url = try policy.validate(URL(string: "https://example.com/path#fragment")!)

        #expect(url.absoluteString == "https://example.com/path")
    }

    /// The policy no longer guesses about addresses. A phone behind a fake-IP proxy
    /// resolves every domain to 198.18.0.0/15, and a developer's own services live on
    /// 127.0.0.1 — blocking either broke real use.
    @Test func allowsPrivateAndLocalHosts() throws {
        let policy = NetworkPolicy()
        for url in [
            "https://127.0.0.1/", "https://10.0.0.1/", "https://192.168.1.1/",
            "https://169.254.169.254/", "https://[::1]/", "https://[fe80::1]/",
            "https://localhost/", "https://printer.local/", "https://router.home.arpa/"
        ] {
            #expect(throws: Never.self, "\(url) should be allowed") {
                _ = try policy.validate(URL(string: url)!)
            }
        }
    }

    /// The address that broke a phone behind Clash: fake-IP resolves every domain into
    /// 198.18.0.0/15, and the policy used to call that private.
    @Test func allowsFakeIPProxyAddresses() throws {
        for url in ["https://198.18.0.114/", "https://198.19.0.7/"] {
            #expect(throws: Never.self, "\(url) should be allowed") {
                _ = try NetworkPolicy().validate(URL(string: url)!)
            }
        }
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

struct NetworkAccessTests {
    private func expectAccessError(
        _ url: String,
        policy: NetworkAccessPolicy,
        containing text: String
    ) async {
        do {
            _ = try NetworkPolicy().validate(URL(string: url)!, access: policy)
            Issue.record("Expected a NetworkPolicyError")
        } catch let error as NetworkPolicyError {
            #expect(error.errorDescription?.contains(text) == true)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func disabledNetworkRejects() async {
        await expectAccessError(
            "https://example.com/",
            policy: NetworkAccessPolicy(isEnabled: false),
            containing: "disabled"
        )
    }

    @Test func allowlistMatchesHostAndSubdomains() async throws {
        let policy = NetworkAccessPolicy(allowedHosts: ["example.com"])
        let url = try NetworkPolicy().validate(
            URL(string: "https://api.example.com/")!,
            access: policy
        )
        #expect(url.host == "api.example.com")

        await expectAccessError(
            "https://other.example/",
            policy: policy,
            containing: "not in the allowed hosts list"
        )
    }

    @Test func allowlistStillAppliesToLocalHosts() async throws {
        let url = try NetworkPolicy().validate(
            URL(string: "https://127.0.0.1:8080/")!,
            access: NetworkAccessPolicy(allowedHosts: ["127.0.0.1"])
        )
        #expect(url.port == 8080)

        await expectAccessError(
            "https://192.168.1.1/",
            policy: NetworkAccessPolicy(allowedHosts: ["127.0.0.1"]),
            containing: "not in the allowed hosts list"
        )
    }
}
