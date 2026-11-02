import Foundation
import Observation
import PokeetCore

@MainActor
@Observable
final class AppSettings {
    private enum Key {
        static let baseURL = "settings.baseURL"
        static let model = "settings.model"
        static let authorName = "settings.authorName"
        static let authorEmail = "settings.authorEmail"
        static let apiKey = "secret.model.apiKey"
        static let gitToken = "secret.git.token"
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keychain: KeychainStore

    var baseURL: String {
        didSet { defaults.set(baseURL, forKey: Key.baseURL) }
    }

    var model: String {
        didSet { defaults.set(model, forKey: Key.model) }
    }

    var authorName: String {
        didSet { defaults.set(authorName, forKey: Key.authorName) }
    }

    var authorEmail: String {
        didSet { defaults.set(authorEmail, forKey: Key.authorEmail) }
    }

    var apiKey: String {
        didSet { storeSecret(apiKey, for: Key.apiKey) }
    }

    var gitToken: String {
        didSet { storeSecret(gitToken, for: Key.gitToken) }
    }

    init(defaults: UserDefaults = .standard, keychain: KeychainStore = KeychainStore()) {
        self.defaults = defaults
        self.keychain = keychain

        baseURL = defaults.string(forKey: Key.baseURL) ?? "https://api.openai.com/v1"
        model = defaults.string(forKey: Key.model) ?? "gpt-4o-mini"
        authorName = defaults.string(forKey: Key.authorName) ?? "Pokeet User"
        authorEmail = defaults.string(forKey: Key.authorEmail) ?? "pokeet@localhost"
        apiKey = keychain.string(for: Key.apiKey) ?? ""
        gitToken = keychain.string(for: Key.gitToken) ?? ""
    }

    var isModelConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && URL(string: baseURL) != nil
    }

    var gitAuthor: GitAuthor {
        GitAuthor(name: authorName, email: authorEmail)
    }

    private func storeSecret(_ value: String, for key: String) {
        if value.isEmpty {
            keychain.delete(key)
        } else {
            keychain.set(value, for: key)
        }
    }
}
