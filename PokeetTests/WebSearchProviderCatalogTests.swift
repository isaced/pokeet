import PokeetCore
import UIKit
import XCTest
@testable import Pokeet

/// The catalog is the contract the Settings screen renders from, so a half
/// declared provider should fail here instead of looking broken on device.
final class WebSearchProviderCatalogTests: XCTestCase {
    func testDeclaredBrandAssetsExist() {
        for kind in WebSearchProviderKind.allCases {
            guard let asset = kind.brandAssetName else { continue }
            XCTAssertNotNil(
                UIImage(named: asset),
                "\(kind.rawValue) points at a missing asset: \(asset)"
            )
        }
    }
    func testEveryProviderIsFullyDescribed() {
        for kind in WebSearchProviderKind.allCases {
            XCTAssertFalse(kind.displayName.isEmpty, "\(kind.rawValue)")
            XCTAssertFalse(kind.iconName.isEmpty, "\(kind.rawValue)")
            XCTAssertFalse(kind.summary.isEmpty, "\(kind.rawValue)")
            XCTAssertFalse(kind.credentialLabel.isEmpty, "\(kind.rawValue)")
            XCTAssertFalse(kind.credentialFooter.isEmpty, "\(kind.rawValue)")
            XCTAssertNotNil(kind.makeProvider(secrets: StubSecretStore()).displayName)
        }
    }

    func testCredentialKeysAreDistinctAndNamespaced() {
        let keys = WebSearchProviderKind.allCases.map(\.credentialKeyName)
        XCTAssertEqual(Set(keys).count, keys.count, "two providers would share a Keychain slot")
        for (kind, key) in zip(WebSearchProviderKind.allCases, keys) {
            XCTAssertEqual(key, "secret.websearch.\(kind.rawValue).apiKey")
        }
    }

    func testFactoryBuildsTheMatchingAdapter() {
        let secrets = StubSecretStore()

        XCTAssertTrue(WebSearchProviderKind.brave.makeProvider(secrets: secrets) is BraveSearchProvider)
        XCTAssertTrue(WebSearchProviderKind.tavily.makeProvider(secrets: secrets) is TavilySearchProvider)
        XCTAssertTrue(WebSearchProviderKind.deepseek.makeProvider(secrets: secrets) is DeepSeekSearchProvider)
        XCTAssertTrue(WebSearchProviderKind.exa.makeProvider(secrets: secrets) is ExaSearchProvider)
    }

    func testProviderIDsRoundTripThroughStorage() {
        for kind in WebSearchProviderKind.allCases {
            XCTAssertEqual(WebSearchProviderKind(rawValue: kind.rawValue), kind)
            XCTAssertEqual(WebSearchProviderKind.resolve(kind.rawValue), kind)
        }
        XCTAssertEqual(WebSearchProviderKind.resolve(nil), .fallback)
        XCTAssertEqual(WebSearchProviderKind.resolve("retired"), .fallback)
    }
}
