import PokeetCore
import XCTest
@testable import Pokeet

/// The one part of the importer that cannot be faked: libgit2 actually fetching a repository.
/// Gated like the other live tests — run it with `POKEET_LIVE_SKILL_REPO=1` and a network.
final class GitSkillRepositoryFetcherTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pokeet-skill-fetch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try await super.tearDown()
    }

    private func requireLive() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["POKEET_LIVE_SKILL_REPO"] == "1",
            "Set POKEET_LIVE_SKILL_REPO=1 to clone a real repository."
        )
    }

    func testClonesASkillsRepositoryShallowAndListsIt() async throws {
        try requireLive()

        let fetcher = GitSkillRepositoryFetcher()
        let repository = try await SkillRepositoryImport.fetch(
            "vercel-labs/skills",
            policy: NetworkAccessPolicy(),
            using: fetcher,
            token: nil,
            in: root
        )
        defer { repository.remove() }

        XCTAssertEqual(repository.source.url.absoluteString, "https://github.com/vercel-labs/skills")
        XCTAssertNotNil(repository.commit, "provenance needs the commit sha")
        XCTAssertEqual(repository.commit?.count, 40)
        XCTAssertTrue(
            repository.skills.contains { $0.name == "find-skills" },
            "found: \(repository.skills.map(\.name))"
        )

        // Depth 1 is the whole point: the clone must not carry history.
        let gitDirectory = repository.directory.appendingPathComponent(".git", isDirectory: true)
        let packed = gitDirectory.appendingPathComponent("objects/pack")
        let packs = (try? FileManager.default.contentsOfDirectory(atPath: packed.path)) ?? []
        XCTAssertFalse(packs.isEmpty)
        let shallow = gitDirectory.appendingPathComponent("shallow")
        XCTAssertTrue(FileManager.default.fileExists(atPath: shallow.path), "a shallow clone writes .git/shallow")

        let imported = try await SkillsStore(
            directory: root.appendingPathComponent("Skills", isDirectory: true)
        ).importSkills(from: repository, names: ["find-skills"])
        XCTAssertEqual(imported.map(\.name), ["find-skills"])
    }

    func testACommitRefIsCheckedOut() async throws {
        try requireLive()

        let fetcher = GitSkillRepositoryFetcher()
        let repository = try await SkillRepositoryImport.fetch(
            "https://github.com/vercel-labs/skills#main",
            policy: NetworkAccessPolicy(),
            using: fetcher,
            token: nil,
            in: root
        )
        defer { repository.remove() }

        XCTAssertEqual(repository.source.ref, "main")
        XCTAssertFalse(repository.skills.isEmpty)
    }
}
