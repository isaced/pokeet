import Foundation

protocol SecretStore: Sendable {
    func string(for key: String) -> String?
    func set(_ value: String, for key: String)
    func delete(_ key: String)
}

extension KeychainStore: SecretStore {}
