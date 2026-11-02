import Foundation

public struct GitCommitInfo: Sendable, Equatable {
    public let hash: String
    public let author: String
    public let date: Date
    public let subject: String

    public init(hash: String, author: String, date: Date, subject: String) {
        self.hash = hash
        self.author = author
        self.date = date
        self.subject = subject
    }
}

/// Read-only repository inspection used by agent tools.
public protocol GitInspecting: Sendable {
    func isRepository(at root: URL) -> Bool
    func workingTreeStatus(at root: URL) async throws -> [GitFileStatus]
    func diff(at root: URL, path: String?, staged: Bool) async throws -> String
    func log(at root: URL, limit: Int) async throws -> [GitCommitInfo]
}
