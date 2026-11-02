import Foundation

public struct FileWorkspace: Workspace {
    public let root: URL
    private let sandbox: PathSandbox

    private static let skippedDirectoryNames: Set<String> = [
        ".git", ".build", ".swiftpm", "node_modules", "deriveddata", "pods"
    ]

    public init(root: URL) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.sandbox = PathSandbox(root: root)
    }

    public func validate(_ relativePath: String) throws {
        _ = try sandbox.resolve(relativePath)
    }

    public func read(_ relativePath: String, maxBytes: Int) throws -> String {
        let url = try sandbox.resolve(relativePath)
        let fileManager = FileManager.default

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw WorkspaceError.notFound(relativePath)
        }
        guard !isDirectory.boolValue else {
            throw WorkspaceError.notAFile(relativePath)
        }

        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        if values?.isRegularFile == false {
            throw WorkspaceError.notAFile(relativePath)
        }
        if let size = values?.fileSize, size > WorkspaceLimits.maxReadBytes {
            throw WorkspaceError.fileTooLarge(path: relativePath, limit: WorkspaceLimits.maxReadBytes)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw WorkspaceError.io(error.localizedDescription)
        }

        guard !data.isEmpty else { return "" }
        guard !data.contains(0) else {
            throw WorkspaceError.binaryFile(relativePath)
        }

        let limit = max(1, maxBytes)
        if data.count > limit {
            let prefix = data.prefix(limit)
            var text = String(decoding: prefix, as: UTF8.self)
            if let lastNewline = text.lastIndex(of: "\n") {
                text = String(text[...lastNewline])
            }
            return text + "\n[truncated at \(limit) bytes]\n"
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw WorkspaceError.binaryFile(relativePath)
        }
        return text
    }

    public func list(_ relativePath: String, recursive: Bool, maxEntries: Int) throws -> [WorkspaceEntry] {
        let directory = try sandbox.resolve(relativePath, allowRoot: true)
        let fileManager = FileManager.default

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw WorkspaceError.notADirectory(relativePath.isEmpty ? "." : relativePath)
        }

        guard maxEntries > 0 else { return [] }
        var entries: [WorkspaceEntry] = []

        if recursive {
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            ) else {
                return []
            }

            while let url = enumerator.nextObject() as? URL {
                guard entries.count < maxEntries else { break }

                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true {
                    continue
                }

                let name = url.lastPathComponent.lowercased()
                let isDirectoryEntry = values?.isDirectory == true
                if isDirectoryEntry && Self.skippedDirectoryNames.contains(name) {
                    enumerator.skipDescendants()
                    continue
                }

                entries.append(WorkspaceEntry(path: workspaceRelativePath(of: url), isDirectory: isDirectoryEntry))
            }
        } else {
            let children = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )

            for url in (children ?? []).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard entries.count < maxEntries else { break }

                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true {
                    continue
                }

                let name = url.lastPathComponent.lowercased()
                let isDirectoryEntry = values?.isDirectory == true
                if isDirectoryEntry && Self.skippedDirectoryNames.contains(name) {
                    continue
                }

                entries.append(WorkspaceEntry(path: workspaceRelativePath(of: url), isDirectory: isDirectoryEntry))
            }
        }

        return entries
    }

    public func write(_ relativePath: String, content: String) throws {
        let url = try sandbox.resolve(relativePath)
        let fileManager = FileManager.default

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw WorkspaceError.notAFile(relativePath)
        }

        guard let data = content.data(using: .utf8) else {
            throw WorkspaceError.io("Content is not valid UTF-8")
        }

        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            throw WorkspaceError.io(error.localizedDescription)
        }
    }

    public func delete(_ relativePath: String) throws {
        let url = try sandbox.resolve(relativePath)
        let fileManager = FileManager.default

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw WorkspaceError.notFound(relativePath)
        }
        guard !isDirectory.boolValue else {
            throw WorkspaceError.notAFile(relativePath)
        }

        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw WorkspaceError.io(error.localizedDescription)
        }
    }

    public func move(_ relativePath: String, to destinationPath: String) throws {
        let source = try sandbox.resolve(relativePath)
        let destination = try sandbox.resolve(destinationPath)
        let fileManager = FileManager.default

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw WorkspaceError.notFound(relativePath)
        }
        guard !isDirectory.boolValue else {
            throw WorkspaceError.notAFile(relativePath)
        }
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw WorkspaceError.staleContent(destinationPath)
        }

        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            throw WorkspaceError.io(error.localizedDescription)
        }
    }

    public func exists(_ relativePath: String) -> Bool {
        guard let url = try? sandbox.resolve(relativePath) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func workspaceRelativePath(of url: URL) -> String {
        let resolved = url.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(root.path + "/") else {
            return url.lastPathComponent
        }
        return String(resolved.path.dropFirst(root.path.count + 1))
    }
}
