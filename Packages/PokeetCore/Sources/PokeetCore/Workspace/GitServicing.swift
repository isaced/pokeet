import Foundation

public struct GitRemoteSpec: Sendable, Equatable {
    public let url: URL
    public let token: String?

    public init(url: URL, token: String? = nil) {
        self.url = url
        self.token = token
    }
}

public struct GitAuthor: Sendable, Equatable {
    public let name: String
    public let email: String

    public init(name: String, email: String) {
        self.name = name
        self.email = email
    }
}

public struct GitFileStatus: Sendable, Equatable {
    public let path: String
    public let state: String

    public init(path: String, state: String) {
        self.path = path
        self.state = state
    }
}

public enum GitServiceError: Error, Sendable, Equatable, LocalizedError {
    case invalidRemote(String)
    case destinationExists(String)
    case cloneFailed(String)
    case openFailed(String)
    case authenticationRequired
    case noChanges
    case detachedHead
    case commitFailed(String)
    case pushFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRemote(let message):
            "Invalid repository URL: \(message)"
        case .destinationExists(let name):
            "A project named \(name) already exists."
        case .cloneFailed(let message):
            "Clone failed: \(message)"
        case .openFailed(let message):
            "Could not open repository: \(message)"
        case .authenticationRequired:
            "A git personal access token is required. Add one in Settings."
        case .noChanges:
            "There are no changes to commit."
        case .detachedHead:
            "HEAD is detached. Switch to a branch before pushing."
        case .commitFailed(let message):
            "Commit failed: \(message)"
        case .pushFailed(let message):
            "Push failed: \(message)"
        }
    }
}

public protocol GitServicing: Sendable {
    func clone(
        _ spec: GitRemoteSpec,
        to directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws
    func status(at root: URL) async throws -> [GitFileStatus]
    func commitAll(at root: URL, message: String, author: GitAuthor) async throws -> String
    func push(at root: URL, token: String) async throws
    func currentBranch(at root: URL) async throws -> String
}
