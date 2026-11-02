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

    func testSeedsProvidersAndPersistsThem() {
        let secrets = MemorySecretStore()
        let settings = AppSettings(defaults: defaults, secrets: secrets)

        XCTAssertEqual(settings.providers.count, 4)
        XCTAssertEqual(settings.providers.map(\.name), [
            "OpenAI", "Anthropic", "Gemini", "OpenAI Compatible"
        ])
        XCTAssertEqual(settings.activeProvider?.name, "OpenAI")
        XCTAssertFalse(settings.isModelConfigured)

        let reloaded = AppSettings(defaults: defaults, secrets: secrets)
        XCTAssertEqual(reloaded.providers.map(\.id), settings.providers.map(\.id))
    }

    func testStoresAPIKeyPerProvider() {
        let secrets = MemorySecretStore()
        let settings = AppSettings(defaults: defaults, secrets: secrets)
        let openAI = try! XCTUnwrap(settings.providers.first)
        var updated = openAI
        updated.baseURL = "https://api.example.com/v1"
        updated.selectedModelIDs = ["model-a"]
        updated.defaultModelID = "model-a"
        updated.models = [ProviderModel(id: "model-a")]

        settings.saveProvider(updated, apiKey: "secret-a")

        XCTAssertEqual(settings.apiKey(for: openAI.id), "secret-a")
        XCTAssertEqual(settings.apiKey(for: settings.providers[1].id), "")
        XCTAssertTrue(settings.isModelConfigured)

        let reloaded = AppSettings(defaults: defaults, secrets: secrets)
        XCTAssertEqual(reloaded.apiKey(for: openAI.id), "secret-a")
        XCTAssertTrue(reloaded.isModelConfigured)
    }

    func testDeletingActiveProviderFallsBackAndRemovesKey() throws {
        let secrets = MemorySecretStore()
        let settings = AppSettings(defaults: defaults, secrets: secrets)
        let active = try XCTUnwrap(settings.activeProvider)
        settings.saveProvider(active, apiKey: "key")

        settings.deleteProvider(id: active.id)

        XCTAssertFalse(settings.providers.contains { $0.id == active.id })
        XCTAssertEqual(settings.apiKey(for: active.id), "")
        XCTAssertNotNil(settings.activeProvider)
        XCTAssertNotEqual(settings.activeProviderID, active.id)
    }

    func testDisablingActiveProviderFallsBack() throws {
        let settings = AppSettings(defaults: defaults, secrets: MemorySecretStore())
        let active = try XCTUnwrap(settings.activeProvider)

        settings.setEnabled(false, for: active.id)

        XCTAssertNotEqual(settings.activeProviderID, active.id)
        XCTAssertEqual(settings.activeProvider?.isEnabled, true)
    }

    func testSavingDisabledActiveProviderFallsBack() throws {
        let settings = AppSettings(defaults: defaults, secrets: MemorySecretStore())
        var active = try XCTUnwrap(settings.activeProvider)
        active.isEnabled = false

        settings.saveProvider(active, apiKey: "")

        XCTAssertNotEqual(settings.activeProviderID, active.id)
        XCTAssertEqual(settings.activeProvider?.isEnabled, true)
    }

    func testDefaultModelMustBeSelected() throws {
        let settings = AppSettings(defaults: defaults, secrets: MemorySecretStore())
        let provider = try XCTUnwrap(settings.activeProvider)

        settings.setDefaultModel("not-selected", for: provider.id)
        XCTAssertEqual(settings.provider(id: provider.id)?.defaultModelID, provider.defaultModelID)

        let selected = try XCTUnwrap(provider.selectedModelIDs.first)
        settings.setDefaultModel(selected, for: provider.id)
        XCTAssertEqual(settings.provider(id: provider.id)?.defaultModelID, selected)
    }

    func testAddingCustomModelThroughProviderSave() throws {
        let settings = AppSettings(defaults: defaults, secrets: MemorySecretStore())
        var provider = try XCTUnwrap(settings.activeProvider)

        let id = try XCTUnwrap(provider.addCustomModel(id: "custom-model"))
        settings.saveProvider(provider, apiKey: "")

        let reloaded = try XCTUnwrap(settings.provider(id: provider.id))
        XCTAssertTrue(reloaded.models.contains { $0.id == id && $0.isCustom })
        XCTAssertTrue(reloaded.selectedModelIDs.contains(id))
    }

    func testDeletedProviderDataIsNotReseeded() {
        let settings = AppSettings(defaults: defaults, secrets: MemorySecretStore())
        for provider in settings.providers {
            settings.deleteProvider(id: provider.id)
        }

        let reloaded = AppSettings(defaults: defaults, secrets: MemorySecretStore())
        XCTAssertTrue(reloaded.providers.isEmpty)
        XCTAssertNil(reloaded.activeProvider)
        XCTAssertFalse(reloaded.isModelConfigured)
    }

    func testSelectingDisabledProviderIsRejected() throws {
        let settings = AppSettings(defaults: defaults, secrets: MemorySecretStore())
        let disabled = settings.providers[1]
        settings.setEnabled(false, for: disabled.id)

        settings.setActiveProvider(disabled.id)

        XCTAssertNotEqual(settings.activeProviderID, disabled.id)
    }
}
