import PokeetCore
import XCTest
@testable import Pokeet

private final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func string(for key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func set(_ value: String, for key: String) {
        lock.lock()
        values[key] = value
        lock.unlock()
    }

    func delete(_ key: String) {
        lock.lock()
        values.removeValue(forKey: key)
        lock.unlock()
    }
}

@MainActor
final class AppSettingsTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "pokeet-settings-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    @discardableResult
    private func addProvider(
        _ settings: AppSettings,
        template: ProviderTemplate = ProviderTemplates.all[0],
        apiKey: String = ""
    ) -> ProviderConfiguration {
        let provider = ProviderTemplates.configuration(from: template)
        settings.saveProvider(provider, apiKey: apiKey)
        return provider
    }

    func testNetworkPolicyMirrorsTheSettings() {
        let settings = AppSettings(defaults: defaults, secrets: MemorySecretStore())

        settings.networkEnabled = false
        XCTAssertFalse(settings.networkAccessPolicy.isEnabled)

        settings.networkEnabled = true
        settings.networkAllowedHosts = " GitHub.com, api.example.com\n\n  gitlab.com "
        XCTAssertEqual(
            settings.networkAccessPolicy.allowedHosts,
            ["github.com", "api.example.com", "gitlab.com"]
        )
    }

    func testStartsEmptyAndPersistsEmptyList() {
        let secrets = MemorySecretStore()
        let settings = AppSettings(defaults: defaults, secrets: secrets)

        XCTAssertTrue(settings.providers.isEmpty)
        XCTAssertNil(settings.activeProvider)
        XCTAssertNil(settings.activeProviderID)
        XCTAssertFalse(settings.isModelConfigured)

        let reloaded = AppSettings(defaults: defaults, secrets: secrets)
        XCTAssertTrue(reloaded.providers.isEmpty)
    }

    func testWebSearchSettingsPersist() {
        let secrets = MemorySecretStore()
        let settings = AppSettings(defaults: defaults, secrets: secrets)

        XCTAssertFalse(settings.webSearchEnabled)
        XCTAssertFalse(settings.isWebSearchConfigured)
        XCTAssertNil(settings.makeWebSearchProvider())
        XCTAssertEqual(settings.webSearchProviderKind, .brave)

        settings.webSearchEnabled = true
        settings.setWebSearchCredential("brave-key", for: .brave)

        XCTAssertTrue(settings.isWebSearchConfigured)
        XCTAssertNotNil(settings.makeWebSearchProvider())

        let reloaded = AppSettings(defaults: defaults, secrets: secrets)
        XCTAssertTrue(reloaded.webSearchEnabled)
        XCTAssertEqual(reloaded.webSearchCredential(for: .brave), "brave-key")
        XCTAssertEqual(reloaded.webSearchProviderID, "brave")
    }

    func testUnknownWebSearchProviderFallsBackToDefault() {
        defaults.set("some-retired-provider", forKey: "settings.websearch.provider.v1")
        let settings = AppSettings(defaults: defaults, secrets: MemorySecretStore())

        XCTAssertEqual(settings.webSearchProviderID, WebSearchProviderKind.fallback.rawValue)
        XCTAssertEqual(settings.webSearchProviderKind, .brave)
    }

    func testWebSearchProviderSelectionPersists() {
        let secrets = MemorySecretStore()
        let settings = AppSettings(defaults: defaults, secrets: secrets)

        settings.setWebSearchProvider(.deepseek)

        let reloaded = AppSettings(defaults: defaults, secrets: secrets)
        XCTAssertEqual(reloaded.webSearchProviderKind, .deepseek)
        XCTAssertEqual(reloaded.webSearchProviderID, "deepseek")
    }

    func testSwitchingProviderKeepsEachCredential() {
        let secrets = MemorySecretStore()
        let settings = AppSettings(defaults: defaults, secrets: secrets)

        for kind in WebSearchProviderKind.allCases {
            settings.setWebSearchCredential("key-\(kind.rawValue)", for: kind)
        }

        settings.webSearchEnabled = true
        settings.setWebSearchProvider(.tavily)
        XCTAssertEqual(settings.webSearchCredential(for: .tavily), "key-tavily")
        XCTAssertTrue(settings.isWebSearchConfigured)

        settings.setWebSearchProvider(.deepseek)
        XCTAssertEqual(settings.webSearchCredential(for: .deepseek), "key-deepseek")
        XCTAssertEqual(settings.webSearchCredential(for: .tavily), "key-tavily")

        settings.setWebSearchProvider(.brave)
        XCTAssertEqual(settings.webSearchCredential(for: .brave), "key-brave")
    }

    func testCredentialMirrorIsObservableStateNotAKeychainRead() {
        let secrets = MemorySecretStore()
        let settings = AppSettings(defaults: defaults, secrets: secrets)

        settings.webSearchEnabled = true
        settings.setWebSearchProvider(.tavily)
        XCTAssertFalse(settings.hasWebSearchCredential(for: .tavily))

        settings.setWebSearchCredential("tvly-key", for: .tavily)
        XCTAssertTrue(settings.hasWebSearchCredential(for: .tavily))
        XCTAssertTrue(settings.isWebSearchConfigured)

        // A key written behind the store's back does not flip the mirror. The
        // mirror is what SwiftUI watches, so it only moves through the API...
        secrets.set("nope", for: WebSearchProviderKind.brave.credentialKeyName)
        XCTAssertFalse(settings.hasWebSearchCredential(for: .brave))

        // ...and a fresh instance re-reads the Keychain, so a relaunch sees every
        // key on file, including ones written out of band.
        XCTAssertEqual(
            AppSettings(defaults: defaults, secrets: secrets).configuredWebSearchProviders,
            [.brave, .tavily]
        )
    }

    func testUnconfiguredProviderIsNotReady() {
        let settings = AppSettings(defaults: defaults, secrets: MemorySecretStore())
        settings.webSearchEnabled = true
        settings.setWebSearchProvider(.tavily)

        XCTAssertFalse(settings.isWebSearchConfigured)
        XCTAssertNotNil(
            settings.makeWebSearchProvider(),
            "the session still gets a provider; it reports .notConfigured per request"
        )
    }

    func testWebSearchCredentialsAreStoredPerProvider() {
        let secrets = MemorySecretStore()
        let settings = AppSettings(defaults: defaults, secrets: secrets)
        let keyName = WebSearchProviderKind.brave.credentialKeyName

        settings.setWebSearchCredential("brave-key", for: .brave)

        XCTAssertEqual(keyName, "secret.websearch.brave.apiKey")
        XCTAssertEqual(settings.webSearchCredential(for: .brave), "brave-key")
        XCTAssertEqual(secrets.string(for: keyName), "brave-key")
        XCTAssertTrue(settings.hasWebSearchCredential(for: .brave))

        settings.setWebSearchCredential("", for: .brave)

        XCTAssertFalse(settings.hasWebSearchCredential(for: .brave))
        XCTAssertNil(secrets.string(for: keyName))
    }

    func testAddingProviderPersistsAndActivatesIt() {
        let secrets = MemorySecretStore()
        let settings = AppSettings(defaults: defaults, secrets: secrets)
        var provider = ProviderTemplates.configuration(from: ProviderTemplates.all[0])
        provider.baseURL = "https://api.example.com/v1"
        provider.models = [ProviderModel(id: "model-a")]
        provider.selectedModelIDs = ["model-a"]
        provider.defaultModelID = "model-a"

        settings.saveProvider(provider, apiKey: "secret")

        XCTAssertEqual(settings.providers.count, 1)
        XCTAssertEqual(settings.activeProviderID, provider.id)
        XCTAssertEqual(settings.activeProvider?.name, provider.name)
        XCTAssertTrue(settings.isModelConfigured)

        let reloaded = AppSettings(defaults: defaults, secrets: secrets)
        XCTAssertEqual(reloaded.providers.map(\.id), [provider.id])
        XCTAssertEqual(reloaded.apiKey(for: provider.id), "secret")
    }

    func testStoresAPIKeyPerProvider() {
        let secrets = MemorySecretStore()
        let settings = AppSettings(defaults: defaults, secrets: secrets)
        let first = addProvider(settings, template: ProviderTemplates.all[0], apiKey: "key-a")
        let second = addProvider(settings, template: ProviderTemplates.all[1], apiKey: "key-b")

        XCTAssertEqual(settings.apiKey(for: first.id), "key-a")
        XCTAssertEqual(settings.apiKey(for: second.id), "key-b")

        settings.deleteProvider(id: first.id)
        XCTAssertEqual(settings.apiKey(for: first.id), "")
        XCTAssertEqual(settings.apiKey(for: second.id), "key-b")
    }

    func testDeletingActiveProviderFallsBackToAnother() {
        let settings = AppSettings(defaults: defaults, secrets: MemorySecretStore())
        let first = addProvider(settings, template: ProviderTemplates.all[0])
        let second = addProvider(settings, template: ProviderTemplates.all[1])
        XCTAssertEqual(settings.activeProviderID, first.id)

        settings.deleteProvider(id: first.id)

        XCTAssertEqual(settings.activeProviderID, second.id)
    }

    func testDisablingActiveProviderFallsBack() {
        let settings = AppSettings(defaults: defaults, secrets: MemorySecretStore())
        let first = addProvider(settings, template: ProviderTemplates.all[0])
        let second = addProvider(settings, template: ProviderTemplates.all[1])

        settings.setEnabled(false, for: first.id)

        XCTAssertEqual(settings.activeProviderID, second.id)
    }

    func testSavingDisabledActiveProviderFallsBack() throws {
        let settings = AppSettings(defaults: defaults, secrets: MemorySecretStore())
        let first = addProvider(settings, template: ProviderTemplates.all[0])
        let second = addProvider(settings, template: ProviderTemplates.all[1])
        var updated = try XCTUnwrap(settings.provider(id: first.id))
        updated.isEnabled = false

        settings.saveProvider(updated, apiKey: "")

        XCTAssertEqual(settings.activeProviderID, second.id)
    }

    func testDefaultModelMustBeSelected() throws {
        let settings = AppSettings(defaults: defaults, secrets: MemorySecretStore())
        let provider = addProvider(settings)

        settings.setDefaultModel("not-selected", for: provider.id)
        XCTAssertEqual(settings.provider(id: provider.id)?.defaultModelID, provider.defaultModelID)

        let selected = try XCTUnwrap(provider.selectedModelIDs.first)
        settings.setDefaultModel(selected, for: provider.id)
        XCTAssertEqual(settings.provider(id: provider.id)?.defaultModelID, selected)
    }

    func testAddingCustomModelThroughProviderSave() throws {
        let settings = AppSettings(defaults: defaults, secrets: MemorySecretStore())
        var provider = addProvider(settings)

        let id = try XCTUnwrap(provider.addCustomModel(id: "custom-model"))
        settings.saveProvider(provider, apiKey: "")

        let reloaded = try XCTUnwrap(settings.provider(id: provider.id))
        XCTAssertTrue(reloaded.models.contains { $0.id == id && $0.isCustom })
        XCTAssertTrue(reloaded.selectedModelIDs.contains(id))
    }

    func testDeletingAllProvidersStaysEmpty() {
        let settings = AppSettings(defaults: defaults, secrets: MemorySecretStore())
        let provider = addProvider(settings)
        settings.deleteProvider(id: provider.id)

        let reloaded = AppSettings(defaults: defaults, secrets: MemorySecretStore())
        XCTAssertTrue(reloaded.providers.isEmpty)
        XCTAssertNil(reloaded.activeProvider)
        XCTAssertFalse(reloaded.isModelConfigured)
    }

    func testSelectingDisabledProviderIsRejected() {
        let settings = AppSettings(defaults: defaults, secrets: MemorySecretStore())
        let first = addProvider(settings, template: ProviderTemplates.all[0])
        let second = addProvider(settings, template: ProviderTemplates.all[1])
        settings.setEnabled(false, for: second.id)

        settings.setActiveProvider(second.id)

        XCTAssertEqual(settings.activeProviderID, first.id)
    }

    func testDefaultAgentModePersists() {
        let secrets = MemorySecretStore()
        let settings = AppSettings(defaults: defaults, secrets: secrets)
        XCTAssertEqual(settings.defaultAgentMode, .ask)

        settings.defaultAgentMode = .plan

        let reloaded = AppSettings(defaults: defaults, secrets: secrets)
        XCTAssertEqual(reloaded.defaultAgentMode, .plan)
    }

    func testNetworkSettingsPersist() {
        let secrets = MemorySecretStore()
        let settings = AppSettings(defaults: defaults, secrets: secrets)
        XCTAssertTrue(settings.networkEnabled)
        XCTAssertEqual(settings.networkAllowedHosts, "")

        settings.networkEnabled = false
        settings.networkAllowedHosts = "api.example.com"

        let reloaded = AppSettings(defaults: defaults, secrets: secrets)
        XCTAssertFalse(reloaded.networkEnabled)
        XCTAssertEqual(reloaded.networkAllowedHosts, "api.example.com")
    }
}
