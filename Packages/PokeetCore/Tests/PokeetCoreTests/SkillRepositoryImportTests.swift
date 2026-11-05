import Foundation
import Testing
@testable import PokeetCore

/// A clone without a network: writes the fixture tree into the directory it is handed, so the
/// orchestration (policy, timeout, scanning, cleanup) can be tested on its own.
private struct FakeRepositoryFetcher: SkillRepositoryFetching {
    let files: [String: String]
    let commit: String?
    let delay: Duration?
    let failure: SkillFetchError?
    let latest: String?
    let latestFailure: SkillFetchError?

    init(
        files: [String: String],
        commit: String? = "abc123",
        delay: Duration? = nil,
        failure: SkillFetchError? = nil,
        latest: String? = nil,
        latestFailure: SkillFetchError? = nil
    ) {
        self.files = files
        self.commit = commit
        self.delay = delay
        self.failure = failure
        self.latest = latest
        self.latestFailure = latestFailure
    }

    func clone(
        _ source: SkillSourceURL,
        token: String?,
        into directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        if let delay { try await Task.sleep(for: delay) }
        if let failure { throw failure }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (path, content) in files {
            let url = directory.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        progress(1)
    }

    func commitSHA(at directory: URL) async throws -> String? {
        commit
    }

    func latestCommit(_ source: SkillSourceURL, token: String?) async throws -> String? {
        if let latestFailure { throw latestFailure }
        return latest
    }
}

private func skillFile(_ name: String, description: String = "A skill.") -> String {
    """
    ---
    name: \(name)
    description: \(description)
    ---

    BODY
    """
}

struct SkillRepositoryImportTests {
    @Test func listsEverySkillInTheClone() async throws {
        let root = try TestDirectory()
        defer { root.cleanup() }
        let fetcher = FakeRepositoryFetcher(files: [
            "skills/find-skills/SKILL.md": skillFile("find-skills"),
            "skills/pdf-tools/SKILL.md": skillFile("pdf-tools"),
            "README.md": "# repo"
        ])

        let repository = try await SkillRepositoryImport.fetch(
            "vercel-labs/skills",
            policy: NetworkAccessPolicy(),
            using: fetcher,
            token: nil,
            in: root.url
        )

        #expect(repository.skills.map(\.name) == ["find-skills", "pdf-tools"])
        #expect(repository.commit == "abc123")
        #expect(repository.source.url.absoluteString == "https://github.com/vercel-labs/skills")
        #expect(FileManager.default.fileExists(atPath: repository.directory.path))

        repository.remove()
        #expect(FileManager.default.fileExists(atPath: repository.directory.path) == false)
    }

    @Test func aPastedFolderLinkNarrowsTheList() async throws {
        let root = try TestDirectory()
        defer { root.cleanup() }
        let fetcher = FakeRepositoryFetcher(files: [
            "skills/find-skills/SKILL.md": skillFile("find-skills"),
            "skills/pdf-tools/SKILL.md": skillFile("pdf-tools")
        ])

        let repository = try await SkillRepositoryImport.fetch(
            "https://github.com/vercel-labs/skills/tree/main/skills/find-skills",
            policy: NetworkAccessPolicy(),
            using: fetcher,
            token: nil,
            in: root.url
        )
        defer { repository.remove() }

        #expect(repository.skills.map(\.name) == ["find-skills", "pdf-tools"])
        #expect(repository.suggested.map(\.name) == ["find-skills"])
        #expect(repository.source.ref == "main")
    }

    @Test func aRepositoryWithoutSkillsIsRefusedAndCleanedUp() async throws {
        let root = try TestDirectory()
        defer { root.cleanup() }
        let fetcher = FakeRepositoryFetcher(files: ["README.md": "# nothing"])

        await #expect(throws: SkillFetchError.self) {
            try await SkillRepositoryImport.fetch(
                "owner/repo",
                policy: NetworkAccessPolicy(),
                using: fetcher,
                token: nil,
                in: root.url
            )
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.url.path)
        #expect(leftovers.isEmpty)
    }

    @Test func refusesWhenNetworkAccessIsOff() async throws {
        let root = try TestDirectory()
        defer { root.cleanup() }
        let fetcher = FakeRepositoryFetcher(files: [:])

        await #expect(throws: SkillFetchError.networkDisabled) {
            try await SkillRepositoryImport.fetch(
                "owner/repo",
                policy: NetworkAccessPolicy(isEnabled: false),
                using: fetcher,
                token: nil,
                in: root.url
            )
        }
    }

    @Test func refusesHostsOutsideTheAllowList() async throws {
        let root = try TestDirectory()
        defer { root.cleanup() }
        let fetcher = FakeRepositoryFetcher(files: [:])

        await #expect(throws: SkillFetchError.hostNotAllowed("github.com")) {
            try await SkillRepositoryImport.fetch(
                "owner/repo",
                policy: NetworkAccessPolicy(allowedHosts: ["gitlab.com"]),
                using: fetcher,
                token: nil,
                in: root.url
            )
        }
        // A subdomain of an allowed host still passes.
        let allowed = NetworkAccessPolicy(allowedHosts: ["github.com"])
        #expect(throws: Never.self) {
            try SkillRepositoryImport.validate(
                SkillSourceURL.parseForTesting(url: URL(string: "https://github.com/o/r")!),
                policy: allowed
            )
        }
    }

    @Test func timesOutAndRemovesTheClone() async throws {
        let root = try TestDirectory()
        defer { root.cleanup() }
        let fetcher = FakeRepositoryFetcher(files: [:], delay: .seconds(5))

        await #expect(throws: SkillFetchError.timedOut) {
            try await SkillRepositoryImport.fetch(
                "owner/repo",
                policy: NetworkAccessPolicy(),
                using: fetcher,
                token: nil,
                in: root.url,
                timeout: .milliseconds(50)
            )
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.url.path)
        #expect(leftovers.isEmpty)
    }

    @Test func surfacesAFailedClone() async throws {
        let root = try TestDirectory()
        defer { root.cleanup() }
        let fetcher = FakeRepositoryFetcher(files: [:], failure: .repositoryNotFound("owner/repo"))

        await #expect(throws: SkillFetchError.repositoryNotFound("owner/repo")) {
            try await SkillRepositoryImport.fetch(
                "owner/repo",
                policy: NetworkAccessPolicy(),
                using: fetcher,
                token: nil,
                in: root.url
            )
        }
    }

    @Test func readsTheRemoteHeadWithoutCloning() async throws {
        let fetcher = FakeRepositoryFetcher(files: [:], latest: "def456")
        let source = try SkillSourceURL.parse("owner/repo")

        let latest = try await SkillRepositoryImport.latestCommit(
            source,
            policy: NetworkAccessPolicy(),
            using: fetcher,
            token: nil
        )

        #expect(latest == "def456")
    }

    @Test func theHeadCheckObeysTheNetworkPolicy() async throws {
        let fetcher = FakeRepositoryFetcher(files: [:], latest: "def456")
        let source = try SkillSourceURL.parse("owner/repo")

        await #expect(throws: SkillFetchError.networkDisabled) {
            try await SkillRepositoryImport.latestCommit(
                source,
                policy: NetworkAccessPolicy(isEnabled: false),
                using: fetcher,
                token: nil
            )
        }
    }

    @Test func refusesAnUnparsableLinkBeforeCloning() async throws {
        let root = try TestDirectory()
        defer { root.cleanup() }
        let fetcher = FakeRepositoryFetcher(files: [:])

        await #expect(throws: SkillSourceError.self) {
            try await SkillRepositoryImport.fetch(
                "not a repo",
                policy: NetworkAccessPolicy(),
                using: fetcher,
                token: nil,
                in: root.url
            )
        }
    }
}

private extension SkillSourceURL {
    static func parseForTesting(url: URL) -> SkillSourceURL {
        SkillSourceURL(url: url)
    }
}
