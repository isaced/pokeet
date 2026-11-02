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
}
