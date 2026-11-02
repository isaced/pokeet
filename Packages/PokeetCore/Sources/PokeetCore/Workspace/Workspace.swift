import Foundation

public enum WorkspaceLimits {
    public static let defaultReadBytes = 20_000
    public static let maxReadBytes = 5_000_000
    public static let maxWriteBytes = 200_000
}

public struct WorkspaceEntry: Sendable, Hashable {
    public let path: String
    public let isDirectory: Bool

    public init(path: String, isDirectory: Bool) {
        self.path = path
        self.isDirectory = isDirectory
    }
}

public enum WorkspaceError: Error, Sendable, Equatable, LocalizedError {
    case invalidPath(String)
    case pathEscapesRoot(String)
    case notFound(String)
    case notAFile(String)
    case notADirectory(String)
    case binaryFile(String)
    case fileTooLarge(path: String, limit: Int)
    case staleContent(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPath(let path):
            "Invalid path: \(path)"
        case .pathEscapesRoot(let path):
            "Path escapes the workspace: \(path)"
        case .notFound(let path):
            "File not found: \(path)"
        case .notAFile(let path):
            "Not a regular file: \(path)"
        case .notADirectory(let path):
            "Not a directory: \(path)"
        case .binaryFile(let path):
            "Binary file cannot be read as text: \(path)"
        case .fileTooLarge(let path, let limit):
            "File is too large to read (limit \(limit) bytes): \(path)"
        case .staleContent(let path):
            "File changed on disk since the change was proposed: \(path)"
        case .io(let message):
            message
        }
    }
}

public protocol Workspace: Sendable {
    var root: URL { get }
    func validate(_ relativePath: String) throws
    func read(_ relativePath: String, maxBytes: Int) throws -> String
    func list(_ relativePath: String, recursive: Bool, maxEntries: Int) throws -> [WorkspaceEntry]
    func write(_ relativePath: String, content: String) throws
    func exists(_ relativePath: String) -> Bool
}
