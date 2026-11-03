import Foundation

/// Evaluates the repository's `.gitignore` files so listing and searching skip
/// what git skips. Nested files apply to their own subtree, rules later in the
/// file win, and a leading `!` re-includes a path.
///
/// This is intentionally a subset of git's rules: patterns, `*`/`**`/`?`,
/// trailing `/` for directories, and negation. A path inside an ignored
/// directory stays ignored, which is also how git behaves.
final class IgnoreRules {
    private struct Rule {
        let matcher: GlobMatcher
        let directoryOnly: Bool
        let negated: Bool
    }

    private let root: URL
    private let fileManager: FileManager
    private var cache: [String: [Rule]] = [:]

    init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    /// `path` is workspace-relative and uses `/` separators.
    func isIgnored(_ path: String, isDirectory: Bool) -> Bool {
        guard !path.isEmpty else { return false }

        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return false }

        // Any ignored ancestor makes the whole subtree ignored.
        for depth in 1..<components.count {
            let ancestor = components[0..<depth].joined(separator: "/")
            if matchesRules(ancestor, isDirectory: true) { return true }
        }
        return matchesRules(path, isDirectory: isDirectory)
    }

    private func matchesRules(_ path: String, isDirectory: Bool) -> Bool {
        var ignored = false
        for directory in ancestorDirectories(of: path) {
            guard let relative = relativePath(of: path, in: directory) else { continue }
            for rule in rules(in: directory) {
                guard rule.matcher.matches(relative) else { continue }
                if rule.directoryOnly && !isDirectory { continue }
                ignored = !rule.negated
            }
        }
        return ignored
    }

    /// Root first, then each directory down to the path's parent.
    private func ancestorDirectories(of path: String) -> [String] {
        var directories = [""]
        let components = path.split(separator: "/").map(String.init)
        guard components.count > 1 else { return directories }
        for depth in 1..<components.count {
            directories.append(components[0..<depth].joined(separator: "/"))
        }
        return directories
    }

    private func relativePath(of path: String, in directory: String) -> String? {
        guard !directory.isEmpty else { return path }
        let prefix = directory + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    private func rules(in directory: String) -> [Rule] {
        if let cached = cache[directory] { return cached }

        let base = directory.isEmpty ? root : root.appending(path: directory)
        let file = base.appending(path: ".gitignore")
        var rules: [Rule] = []
        if let text = try? String(contentsOf: file, encoding: .utf8) {
            rules = Self.parse(text, base: directory)
        }
        cache[directory] = rules
        return rules
    }

    private static func parse(_ text: String, base: String) -> [Rule] {
        var rules: [Rule] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasSuffix("\\") { line.removeLast() }

            var negated = false
            if line.hasPrefix("!") {
                negated = true
                line.removeFirst()
            }
            guard !line.isEmpty else { continue }

            var directoryOnly = false
            if line.hasSuffix("/") {
                directoryOnly = true
                line.removeLast()
            }
            guard !line.isEmpty else { continue }

            let anchored = line.hasPrefix("/") || line.contains("/")
            if line.hasPrefix("/") { line.removeFirst() }
            guard !line.isEmpty, let matcher = try? GlobMatcher(pattern: line, anchored: anchored) else {
                continue
            }

            rules.append(Rule(
                matcher: matcher,
                directoryOnly: directoryOnly,
                negated: negated
            ))
        }
        return rules
    }
}
