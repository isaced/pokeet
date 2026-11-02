import Foundation
import Observation
import PokeetCore

@MainActor
@Observable
final class AppSettings {
    private enum Key {
        static let providers = "settings.llm.providers.v1"
        static let activeProviderID = "settings.llm.activeProviderID"
        static let authorName = "settings.authorName"
        static let authorEmail = "settings.authorEmail"
        static let gitToken = "secret.git.token"
        static func apiKey(_ providerID: UUID) -> String {
            "secret.llm.\(providerID.uuidString).apiKey"
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let secrets: any SecretStore

    private(set) var providers: [ProviderConfiguration] {
        didSet { persistProviders() }
    }

    private(set) var activeProviderID: UUID? {
        didSet {
            if let activeProviderID {
                defaults.set(activeProviderID.uuidString, forKey: Key.activeProviderID)
            } else {
                defaults.removeObject(forKey: Key.activeProviderID)
            }
        }
    }

    var authorName: String {
        didSet { defaults.set(authorName, forKey: Key.authorName) }
    }

    var authorEmail: String {
        didSet { defaults.set(authorEmail, forKey: Key.authorEmail) }
    }

    var gitToken: String {
        didSet { storeSecret(gitToken, for: Key.gitToken) }
    }

    init(
        defaults: UserDefaults = .standard,
        secrets: any SecretStore = KeychainStore()
    ) {
        self.defaults = defaults
        self.secrets = secrets

        let loadedProviders: [ProviderConfiguration]
        if let data = defaults.data(forKey: Key.providers),
           let decoded = try? JSONDecoder().decode([ProviderConfiguration].self, from: data) {
            loadedProviders = decoded
        } else {
            loadedProviders = []
        }

        let storedActive = defaults.string(forKey: Key.activeProviderID)
            .flatMap(UUID.init(uuidString:))
        let initialActive: UUID?
        if let storedActive,
           loadedProviders.contains(where: { $0.id == storedActive && $0.isEnabled }) {
            initialActive = storedActive
        } else {
            initialActive = loadedProviders.first(where: \.isEnabled)?.id
        }

        providers = loadedProviders
        activeProviderID = initialActive

        authorName = defaults.string(forKey: Key.authorName) ?? "Pokeet User"
        authorEmail = defaults.string(forKey: Key.authorEmail) ?? "pokeet@localhost"
        gitToken = secrets.string(for: Key.gitToken) ?? ""
    }

    var activeProvider: ProviderConfiguration? {
        if let activeProviderID,
           let provider = providers.first(where: { $0.id == activeProviderID }) {
            return provider
        }
        return providers.first(where: \.isEnabled)
    }

    var enabledProviders: [ProviderConfiguration] {
        providers.filter(\.isEnabled)
    }

    var isModelConfigured: Bool {
        guard let provider = activeProvider, provider.isEnabled else { return false }
        return provider.isConfigured(apiKey: apiKey(for: provider.id))
    }

    var gitAuthor: GitAuthor {
        GitAuthor(name: authorName, email: authorEmail)
    }

    func provider(id: UUID) -> ProviderConfiguration? {
        providers.first { $0.id == id }
    }

    func apiKey(for providerID: UUID) -> String {
        secrets.string(for: Key.apiKey(providerID)) ?? ""
    }

    func saveProvider(_ provider: ProviderConfiguration, apiKey: String) {
        if let index = providers.firstIndex(where: { $0.id == provider.id }) {
            providers[index] = provider
        } else {
            providers.append(provider)
        }

        setAPIKey(apiKey, for: provider.id)

        if !provider.isEnabled, activeProviderID == provider.id {
            activeProviderID = providers.first(where: { $0.isEnabled && $0.id != provider.id })?.id
        } else if provider.isEnabled, activeProviderID == nil {
            activeProviderID = provider.id
        }
    }

    func deleteProvider(id: UUID) {
        providers.removeAll { $0.id == id }
        secrets.delete(Key.apiKey(id))

        if activeProviderID == id {
            activeProviderID = providers.first(where: \.isEnabled)?.id
        }
    }

    func setEnabled(_ isEnabled: Bool, for providerID: UUID) {
        guard let index = providers.firstIndex(where: { $0.id == providerID }) else { return }
        providers[index].isEnabled = isEnabled

        if !isEnabled, activeProviderID == providerID {
            activeProviderID = providers.first(where: \.isEnabled)?.id
        } else if isEnabled, activeProviderID == nil {
            activeProviderID = providerID
        }
    }

    func setActiveProvider(_ providerID: UUID?) {
        guard let providerID,
              providers.contains(where: { $0.id == providerID && $0.isEnabled })
        else {
            activeProviderID = providers.first(where: \.isEnabled)?.id
            return
        }
        activeProviderID = providerID
    }

    func setDefaultModel(_ modelID: String, for providerID: UUID) {
        guard let index = providers.firstIndex(where: { $0.id == providerID }),
              providers[index].selectedModelIDs.contains(modelID)
        else { return }
        providers[index].defaultModelID = modelID
    }

    private func setAPIKey(_ value: String, for providerID: UUID) {
        let key = Key.apiKey(providerID)
        if value.isEmpty {
            secrets.delete(key)
        } else {
            secrets.set(value, for: key)
        }
    }

    private func storeSecret(_ value: String, for key: String) {
        if value.isEmpty {
            secrets.delete(key)
        } else {
            secrets.set(value, for: key)
        }
    }

    private func persistProviders() {
        guard let data = try? JSONEncoder().encode(providers) else { return }
        defaults.set(data, forKey: Key.providers)
    }
}
