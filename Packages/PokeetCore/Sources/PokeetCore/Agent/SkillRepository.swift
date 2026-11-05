import Foundation

public enum SkillFetchError: Error, Sendable, Equatable, LocalizedError {
    case networkDisabled
    case hostNotAllowed(String)
    case insecureHost(String)
    case repositoryNotFound(String)
    case cloneFailed(String)
    case timedOut
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .networkDisabled:
            "Network access is off. Turn it on in Settings → Network to import from a repository."
        case .hostNotAllowed(let host):
            "\(host) is not in the allowed hosts list. Add it in Settings → Network, or import the skill from Files instead."
        case .insecureHost(let host):
            "Skills are fetched over HTTPS only (\(host))."
        case .repositoryNotFound(let url):
            "Could not find \(url). Check the name, or add a token in Settings → Git if the repository is private."
        case .cloneFailed(let message):
            "Cloning failed: \(message)"
        case .timedOut:
            "That repository took too long to fetch. Paste a link to the skill folder instead — Pokeet then only needs that part."
        case .cancelled:
            "Fetch cancelled."
        }
    }
}

/// What a clone has to do for the importer: land a repository in a directory, and name the
/// commit it landed on. The transport lives in the app; `PokeetCore` stays free of network code.
public protocol SkillRepositoryFetching: Sendable {
    func clone(
        _ source: SkillSourceURL,
        token: String?,
        into directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws
    func commitSHA(at directory: URL) async throws -> String?
    /// The commit HEAD points at on the remote, without cloning. Used to tell whether an
    /// imported skill has moved on.
    func latestCommit(_ source: SkillSourceURL, token: String?) async throws -> String?
}

/// A clone that has been scanned but not yet imported. It owns its temporary directory:
/// callers import while it exists, then `remove()`.
public struct RemoteSkillRepository: Sendable {
    public let source: SkillSourceURL
    public let directory: URL
    public let commit: String?
    public let skills: [Skill]
    public let issues: [SkillIssue]

    public init(
        source: SkillSourceURL,
        directory: URL,
        commit: String?,
        skills: [Skill],
        issues: [SkillIssue]
    ) {
        self.source = source
        self.directory = directory
        self.commit = commit
        self.skills = skills
        self.issues = issues
    }

    /// Skills the pasted link pointed at, when it carried a path.
    public var suggested: [Skill] {
        skills.filter { source.matches($0) }
    }

    public func skill(named name: String) -> Skill? {
        skills.first { $0.name == name }
    }

    public func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

public enum SkillRepositoryImport {
    /// Validate, clone, scan, and keep the clone alive for the picker.
    ///
    /// The policy check happens before any network call: importing a skill is egress, and it
    /// has to obey the same switch as `http_request` and web search.
    public static func fetch(
        _ rawSource: String,
        policy: NetworkAccessPolicy,
        using fetcher: any SkillRepositoryFetching,
        token: String?,
        in root: URL,
        timeout: Duration = .seconds(90),
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> RemoteSkillRepository {
        let source = try SkillSourceURL.parse(rawSource)
        try validate(source, policy: policy)

        let directory = root.appendingPathComponent("skill-fetch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        do {
            try await withTimeout(timeout) {
                try await fetcher.clone(source, token: token, into: directory, progress: progress)
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }

        let commit = try? await fetcher.commitSHA(at: directory)
        let catalog = SkillCatalog.scanRepository(at: directory)
        let repository = RemoteSkillRepository(
            source: source,
            directory: directory,
            commit: commit,
            skills: catalog.skills,
            issues: catalog.issues
        )

        if catalog.skills.isEmpty {
            repository.remove()
            throw SkillFetchError.cloneFailed(
                "No SKILL.md found. Paste a link to the skill folder if it sits deeper than four levels."
            )
        }
        return repository
    }

    /// Asks the remote for the commit it would hand out now, under the same policy as a clone.
    public static func latestCommit(
        _ source: SkillSourceURL,
        policy: NetworkAccessPolicy,
        using fetcher: any SkillRepositoryFetching,
        token: String?
    ) async throws -> String? {
        try validate(source, policy: policy)
        return try await withTimeout(.seconds(30)) {
            try await fetcher.latestCommit(source, token: token)
        }
    }

    public static func validate(_ source: SkillSourceURL, policy: NetworkAccessPolicy) throws {
        guard policy.isEnabled else { throw SkillFetchError.networkDisabled }
        guard let scheme = source.url.scheme?.lowercased(), scheme == "https" else {
            throw SkillFetchError.insecureHost(source.url.absoluteString)
        }
        guard let host = source.url.host?.lowercased(), !host.isEmpty else {
            throw SkillFetchError.insecureHost(source.url.absoluteString)
        }
        guard !policy.allowedHosts.isEmpty else { return }

        let allowed = policy.allowedHosts.contains { entry in
            let candidate = entry.lowercased().trimmingCharacters(in: .whitespaces)
            return host == candidate || host.hasSuffix("." + candidate)
        }
        guard allowed else { throw SkillFetchError.hostNotAllowed(host) }
    }

    /// Cancels the clone at the deadline. libgit2's transfer callback checks for cancellation,
    /// so the abort happens between objects rather than after the download finishes.
    private static func withTimeout<T: Sendable>(
        _ timeout: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw SkillFetchError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw SkillFetchError.cancelled }
            return result
        }
    }
}
