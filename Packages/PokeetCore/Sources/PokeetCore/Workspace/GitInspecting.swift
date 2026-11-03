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

/// A file's content at a revision.
public struct GitBlobContent: Sendable, Equatable {
    public let ref: String
    public let path: String
    public let text: String
    public let sizeBytes: Int
    public let isBinary: Bool

    public init(ref: String, path: String, text: String, sizeBytes: Int, isBinary: Bool) {
        self.ref = ref
        self.path = path
        self.text = text
        self.sizeBytes = sizeBytes
        self.isBinary = isBinary
    }
}

/// A commit with the changes it introduced.
public struct GitCommitDetails: Sendable, Equatable {
    public let hash: String
    public let author: String
    public let date: Date
    public let message: String
    public let diff: String

    public init(hash: String, author: String, date: Date, message: String, diff: String) {
        self.hash = hash
        self.author = author
        self.date = date
        self.message = message
        self.diff = diff
    }
}

public enum GitInspectError: Error, Sendable, Equatable, LocalizedError {
    case unknownRevision(String)
    case notFound(ref: String, path: String)
    case unsupported

    public var errorDescription: String? {
        switch self {
        case .unknownRevision(let ref):
            "Unknown revision '\(ref)'. Use a commit hash, branch, tag, HEAD or HEAD~N."
        case .notFound(let ref, let path):
            "No file at '\(path)' in '\(ref)'."
        case .unsupported:
            "This project's git inspector cannot read history."
        }
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
    /// File content at a revision, e.g. `HEAD~2` + `Sources/App.swift`.
    func blob(at root: URL, ref: String, path: String) async throws -> GitBlobContent
    /// Message and changes for a single commit.
    func commitDetails(at root: URL, ref: String) async throws -> GitCommitDetails
}

public extension GitInspecting {
    /// Inspection is optional: inspectors that cannot count lines report none.
    func diffStat(at root: URL) async throws -> [GitFileDiffStat] {
        []
    }

    func blob(at root: URL, ref: String, path: String) async throws -> GitBlobContent {
        throw GitInspectError.unsupported
    }

    func commitDetails(at root: URL, ref: String) async throws -> GitCommitDetails {
        throw GitInspectError.unsupported
    }
}

