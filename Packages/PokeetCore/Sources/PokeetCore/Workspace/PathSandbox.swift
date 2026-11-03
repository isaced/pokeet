import Foundation

public struct PathSandbox: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    }

    public func resolve(_ relativePath: String, allowRoot: Bool = false) throws -> URL {
        if relativePath.isEmpty {
            guard allowRoot else {
                throw WorkspaceError.invalidPath("Path must not be empty")
            }
            return root
        }

        if relativePath.unicodeScalars.contains(where: {
            $0.value == 0 || $0.value < 0x20 || $0.value == 0x7F
        }) {
            throw WorkspaceError.invalidPath(relativePath)
        }

        if relativePath.hasPrefix("/") || relativePath.hasPrefix("~") {
            throw WorkspaceError.invalidPath(relativePath)
        }

        var components: [String] = []
        for component in relativePath.split(separator: "/", omittingEmptySubsequences: false) {
            let part = String(component)
            if part.isEmpty || part == "." {
                continue
            }
            if part == ".." || part.lowercased() == ".git" {
                throw WorkspaceError.pathEscapesRoot(relativePath)
            }
            components.append(part)
        }

        guard !components.isEmpty else {
            // ".", "./" and "//" all mean the workspace root. Reads allow that;
            // writes, deletes and moves keep allowRoot false, so they still fail
            // rather than targeting the repository itself.
            guard allowRoot else {
                throw WorkspaceError.invalidPath(relativePath)
            }
            return root
        }

        let target = root
            .appending(path: components.joined(separator: "/"))
            .standardizedFileURL

        let resolved = resolveExistingPrefix(of: target)

        guard resolved.path == root.path || resolved.path.hasPrefix(root.path + "/") else {
            throw WorkspaceError.pathEscapesRoot(relativePath)
        }

        if resolved.path != root.path {
            let relativeToRoot = resolved.path.dropFirst(root.path.count + 1)
            let containsGitComponent = relativeToRoot
                .split(separator: "/", omittingEmptySubsequences: true)
                .contains { $0.lowercased() == ".git" }
            if containsGitComponent {
                throw WorkspaceError.pathEscapesRoot(relativePath)
            }
        }

        return resolved
    }

    private func resolveExistingPrefix(of url: URL) -> URL {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            return url.resolvingSymlinksInPath()
        }

        var ancestor = url.deletingLastPathComponent()
        var suffix: [String] = [url.lastPathComponent]

        while ancestor.path != "/", !fileManager.fileExists(atPath: ancestor.path) {
            suffix.insert(ancestor.lastPathComponent, at: 0)
            ancestor = ancestor.deletingLastPathComponent()
        }

        let resolvedAncestor = ancestor.resolvingSymlinksInPath()
        return suffix.reduce(resolvedAncestor) { $0.appending(path: $1) }
    }
}
