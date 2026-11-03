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

/// Line counts for one path that differs from `HEAD`.
public struct GitFileDiffStat: Sendable, Equatable {
    public let path: String
    public let added: Int
    public let removed: Int

    public init(path: String, added: Int, removed: Int) {
        self.path = path
        self.added = added
        self.removed = removed
    }
}

/// Read-only repository inspection used by agent tools.
public protocol GitInspecting: Sendable {
    func isRepository(at root: URL) -> Bool
    func workingTreeStatus(at root: URL) async throws -> [GitFileStatus]
    func diff(at root: URL, path: String?, staged: Bool) async throws -> String
    /// Added and removed line counts for every pending change, staged or not.
    /// Paths without countable text (binaries, oversized files) are omitted.
    func diffStat(at root: URL) async throws -> [GitFileDiffStat]
    func log(at root: URL, limit: Int) async throws -> [GitCommitInfo]
}

public extension GitInspecting {
    /// Inspection is optional: inspectors that cannot count lines report none.
    func diffStat(at root: URL) async throws -> [GitFileDiffStat] {
        []
    }
}

