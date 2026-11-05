import Foundation

public enum SkillSourceError: Error, Sendable, Equatable, LocalizedError {
    case invalidURL(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let raw):
            raw.isEmpty
                ? "Paste a repository link, such as https://github.com/vercel-labs/skills or owner/repo."
                : "\"\(raw)\" is not a repository link. Paste something like https://github.com/vercel-labs/skills or owner/repo."
        }
    }
}

/// A repository that may hold skills, plus the two filters a pasted link can carry.
///
/// Accepts everything the `skills` CLI accepts, because links are copied from the same
/// places: `owner/repo`, a full HTTPS URL, a `…/tree/<ref>/<path>` link (GitHub and GitLab
/// shapes), and a `#ref` fragment. Anything else is refused up front rather than after a
/// failed clone.
public struct SkillSourceURL: Sendable, Equatable {
    public let url: URL
    public let ref: String?
    public let pathPrefix: String?

    public init(url: URL, ref: String? = nil, pathPrefix: String? = nil) {
        self.url = url
        self.ref = ref
        self.pathPrefix = pathPrefix
    }

    public static func parse(_ raw: String) throws -> SkillSourceURL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else {
            throw SkillSourceError.invalidURL(trimmed)
        }

        // A bare `owner/repo` is the shorthand everyone types; it means GitHub.
        let candidate = trimmed.contains("://") ? trimmed : "https://github.com/\(trimmed)"

        guard var components = URLComponents(string: candidate) else {
            throw SkillSourceError.invalidURL(trimmed)
        }
        guard components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty
        else {
            throw SkillSourceError.invalidURL(trimmed)
        }

        let fragmentRef = nonEmpty(components.fragment)
        components.fragment = nil

        let segments = components.path.split(separator: "/").map(String.init)
        guard segments.count >= 2, !segments[0].isEmpty, !segments[1].isEmpty else {
            throw SkillSourceError.invalidURL(trimmed)
        }

        var repositoryEnd = 1
        var ref: String?
        var pathPrefix: String?

        // `…/tree/<ref>/<path>` on GitHub, `…/-/tree/<ref>/<path>` on GitLab. The dash is
        // the only difference, so one lookup covers both.
        if let treeIndex = segments.firstIndex(of: "tree"), treeIndex >= 2 {
            let hasDash = segments[treeIndex - 1] == "-"
            repositoryEnd = treeIndex - (hasDash ? 2 : 1)
            guard repositoryEnd >= 1 else { throw SkillSourceError.invalidURL(trimmed) }
            if treeIndex + 1 < segments.count { ref = segments[treeIndex + 1] }
            if treeIndex + 2 < segments.count {
                pathPrefix = segments[(treeIndex + 2)...].joined(separator: "/")
            }
        } else if segments.count > repositoryEnd + 1 {
            // `owner/repo/skills/find-skills` — no tree marker, the rest is still a hint.
            pathPrefix = segments[(repositoryEnd + 1)...].joined(separator: "/")
        }

        var repositoryPath = segments[0...repositoryEnd].joined(separator: "/")
        if repositoryPath.hasSuffix(".git") {
            repositoryPath.removeLast(4)
        }
        guard !repositoryPath.isEmpty, let url = URL(string: "https://\(host)/\(repositoryPath)") else {
            throw SkillSourceError.invalidURL(trimmed)
        }

        return SkillSourceURL(
            url: url,
            ref: ref ?? fragmentRef,
            pathPrefix: nonEmpty(pathPrefix)
        )
    }

    /// A filter for the picker: everything under the pasted path, nothing else.
    public func matches(_ skill: Skill) -> Bool {
        guard let pathPrefix else { return true }
        let prefix = pathPrefix.hasSuffix("/") ? pathPrefix : pathPrefix + "/"
        return skill.location == pathPrefix || skill.location.hasPrefix(prefix)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
