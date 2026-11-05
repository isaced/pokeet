import PokeetCore
import XCTest
@testable import Pokeet

/// The import side of global skills: everything a user can do to the app-level folder
/// without leaving the app. Repository import lands on top of the same store later.
@MainActor
final class SkillsStoreTests: XCTestCase {
    private var root: URL!
    private var skillsDirectory: URL!
    private var store: SkillsStore!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pokeet-skills-store-\(UUID().uuidString)", isDirectory: true)
        skillsDirectory = root.appendingPathComponent("Skills", isDirectory: true)
        try FileManager.default.createDirectory(at: skillsDirectory, withIntermediateDirectories: true)
        store = SkillsStore(directory: skillsDirectory)
    }

    override func tearDown() async throws {
        store = nil
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try await super.tearDown()
    }

    // MARK: - Importing

    func testImportsAFolderAndRenamesItToTheSkillName() async throws {
        let source = try makeFolderSkill(folder: "picked-folder", name: "pdf-tools", description: "Read PDFs.")
        try write("references/formats.md", to: source, content: "formats")

        let skill = try await store.importSkill(from: source)

        XCTAssertEqual(skill.name, "pdf-tools")
        XCTAssertEqual(skill.source, .user)
        let installed = skillsDirectory.appendingPathComponent("pdf-tools/SKILL.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: skillsDirectory.appendingPathComponent("pdf-tools/references/formats.md").path
            ),
            "bundled references have to travel with the skill"
        )
        XCTAssertEqual(store.global.skills.map(\.name), ["pdf-tools"])
    }

    func testImportsASingleMarkdownFile() async throws {
        let source = root.appendingPathComponent("standalone.md")
        try """
        ---
        name: standalone
        description: One file only.
        ---

        BODY
        """.write(to: source, atomically: true, encoding: .utf8)

        let skill = try await store.importSkill(from: source)

        XCTAssertEqual(skill.name, "standalone")
        let installed = skillsDirectory.appendingPathComponent("standalone/SKILL.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: skillsDirectory.appendingPathComponent("standalone/standalone.md").path)
        )
    }

    func testImportRejectsAFolderWithoutSkillFile() async throws {
        let source = try makeFolderSkill(folder: "junk", name: "junk", description: "x")
        try FileManager.default.removeItem(at: source.appendingPathComponent("SKILL.md"))

        await XCTAssertThrowsErrorAsync(try await store.importSkill(from: source)) { error in
            XCTAssertEqual(error as? SkillImportError, .invalid([SkillIssue(
                path: "junk",
                message: "No SKILL.md in this folder — a skill is a folder with a SKILL.md inside"
            )]))
        }
        XCTAssertTrue(store.global.isEmpty)
    }

    func testImportRejectsASkillWithoutDescription() async throws {
        let source = try makeFolderSkill(folder: "bare", name: "bare", description: nil)

        await XCTAssertThrowsErrorAsync(try await store.importSkill(from: source)) { error in
            guard case .invalid(let issues) = error as? SkillImportError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(issues.contains { $0.message.contains("description") })
        }
        XCTAssertTrue(store.global.isEmpty)
    }

    func testImportRejectsSymlinksAndHiddenFiles() async throws {
        let source = try makeFolderSkill(folder: "linked", name: "linked", description: "x")
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent("escape.md"),
            withDestinationURL: root.appendingPathComponent("outside.md")
        )

        await XCTAssertThrowsErrorAsync(try await store.importSkill(from: source)) { error in
            guard case .invalid(let issues) = error as? SkillImportError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(issues.contains { $0.message.contains("symbolic link") })
        }
        XCTAssertTrue(store.global.isEmpty)
    }

    func testImportRejectsTooManyFiles() async throws {
        let source = try makeFolderSkill(folder: "many", name: "many", description: "x")
        for index in 0..<(SkillsStore.maxFiles + 1) {
            try write("refs/\(index).md", to: source, content: "x")
        }

        await XCTAssertThrowsErrorAsync(try await store.importSkill(from: source)) { error in
            guard case .invalid(let issues) = error as? SkillImportError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(issues.contains { $0.message.lowercased().contains("too many files") })
        }
    }

    func testImportRefusesANameThatIsAlreadyTaken() async throws {
        let first = try makeFolderSkill(folder: "one", name: "tools", description: "first")
        _ = try await store.importSkill(from: first)
        let second = try makeFolderSkill(folder: "two", name: "tools", description: "second")

        await XCTAssertThrowsErrorAsync(try await store.importSkill(from: second)) { error in
            XCTAssertEqual(error as? SkillImportError, .nameTaken("tools"))
        }
        let installed = try String(
            contentsOf: skillsDirectory.appendingPathComponent("tools/SKILL.md"),
            encoding: .utf8
        )
        XCTAssertTrue(installed.contains("first"), "the existing skill must not be touched")
    }

    func testReplacingASkillSwapsItsContent() async throws {
        let first = try makeFolderSkill(folder: "one", name: "tools", description: "first")
        _ = try await store.importSkill(from: first)
        let second = try makeFolderSkill(folder: "two", name: "tools", description: "second")

        let skill = try await store.importSkill(from: second, replacing: "tools")

        XCTAssertEqual(skill.description, "second")
        let installed = try String(
            contentsOf: skillsDirectory.appendingPathComponent("tools/SKILL.md"),
            encoding: .utf8
        )
        XCTAssertTrue(installed.contains("second"))
        XCTAssertEqual(store.global.skills.count, 1)
    }

    func testReplacingWithADifferentNameIsRefused() async throws {
        let first = try makeFolderSkill(folder: "one", name: "tools", description: "first")
        _ = try await store.importSkill(from: first)
        let second = try makeFolderSkill(folder: "two", name: "other", description: "second")

        await XCTAssertThrowsErrorAsync(try await store.importSkill(from: second, replacing: "tools")) { error in
            XCTAssertEqual(error as? SkillImportError, .nameMismatch(expected: "tools", found: "other"))
        }
    }

    func testAFailedImportLeavesNoStagingBehind() async throws {
        let source = try makeFolderSkill(folder: "bare", name: "bare", description: nil)

        _ = try? await store.importSkill(from: source)

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: skillsDirectory.path)
        XCTAssertEqual(leftovers, [])
    }

    // MARK: - Deleting

    func testDeletesOnlyTheNamedSkill() async throws {
        _ = try await store.importSkill(from: try makeFolderSkill(folder: "a", name: "one", description: "1"))
        _ = try await store.importSkill(from: try makeFolderSkill(folder: "b", name: "two", description: "2"))

        try await store.delete(named: "one")

        XCTAssertEqual(store.global.skills.map(\.name), ["two"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: skillsDirectory.appendingPathComponent("one").path))
    }

    func testDeleteRefusesAProjectSkill() async throws {
        let project = try makeProject(named: "Demo")
        try FileManager.default.createDirectory(
            at: project.directory.appendingPathComponent(".agents/skills/local", isDirectory: true),
            withIntermediateDirectories: true
        )
        try """
        ---
        name: local
        description: In the repo.
        ---
        """.write(
            to: project.directory.appendingPathComponent(".agents/skills/local/SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        let store = SkillsStore(directory: skillsDirectory, projects: { [project] })
        await store.refresh()
        let local = try XCTUnwrap(store.projects.first?.catalog.skill(named: "local"))

        await XCTAssertThrowsErrorAsync(try await store.delete(local)) { error in
            XCTAssertEqual(error as? SkillImportError, .notRemovable(local.location))
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: project.directory.appendingPathComponent(".agents/skills/local/SKILL.md").path
            )
        )
    }

    // MARK: - Refreshing

    func testRefreshListsProjectSkillsReadOnly() async throws {
        let project = try makeProject(named: "Demo")
        try FileManager.default.createDirectory(
            at: project.directory.appendingPathComponent(".agents/skills/repo-skill", isDirectory: true),
            withIntermediateDirectories: true
        )
        try """
        ---
        name: repo-skill
        description: From the repository.
        ---
        """.write(
            to: project.directory.appendingPathComponent(".agents/skills/repo-skill/SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        let store = SkillsStore(directory: skillsDirectory, projects: { [project] })

        await store.refresh()

        XCTAssertEqual(store.projects.map(\.project.name), ["Demo"])
        XCTAssertEqual(store.projects.first?.catalog.skills.map(\.name), ["repo-skill"])
        XCTAssertTrue(store.global.isEmpty)
    }

    func testProjectSkillsThatShadowAGlobalSkillAreMarked() async throws {
        _ = try await store.importSkill(from: try makeFolderSkill(
            folder: "global",
            name: "shared",
            description: "Global copy."
        ))
        let project = try makeProject(named: "Demo")
        let skillDirectory = project.directory.appendingPathComponent(".agents/skills/shared")
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        try """
        ---
        name: shared
        description: Project copy.
        ---
        """.write(
            to: skillDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        let store = SkillsStore(directory: skillsDirectory, projects: { [project] })

        await store.refresh()

        XCTAssertEqual(store.projects.first?.shadowsGlobal, ["shared"])
        XCTAssertEqual(store.global.skills.map(\.name), ["shared"])
    }

    func testProjectSkillsWithoutAClashShadowNothing() async throws {
        let project = try makeProject(named: "Demo")
        let skillDirectory = project.directory.appendingPathComponent(".agents/skills/local")
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        try """
        ---
        name: local
        description: Only here.
        ---
        """.write(
            to: skillDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        let store = SkillsStore(directory: skillsDirectory, projects: { [project] })

        await store.refresh()

        XCTAssertEqual(store.projects.first?.shadowsGlobal, [])
    }

    func testRefreshIgnoresStagingLeftovers() async throws {
        try FileManager.default.createDirectory(
            at: skillsDirectory.appendingPathComponent(".staging-1/ghost", isDirectory: true),
            withIntermediateDirectories: true
        )
        try """
        ---
        name: ghost
        description: Half-written.
        ---
        """.write(
            to: skillsDirectory.appendingPathComponent(".staging-1/ghost/SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        await store.refresh()

        XCTAssertTrue(store.global.isEmpty)
    }

    // MARK: - Helpers

    private func makeProject(named name: String) throws -> Project {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return Project(directory: directory, remoteHost: nil, isGitRepository: false)
    }

    /// Writes a skill into a source folder outside the skills directory, the way a document
    /// picker hands one over.
    private func makeFolderSkill(folder: String, name: String, description: String?) throws -> URL {
        let directory = root.appendingPathComponent("Picked/\(folder)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var lines = ["---", "name: \(name)"]
        if let description { lines.append("description: \(description)") }
        lines.append(contentsOf: ["---", "", "BODY"])
        try lines.joined(separator: "\n").write(
            to: directory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        return directory
    }

    private func write(_ relativePath: String, to directory: URL, content: String) throws {
        let url = directory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// A clone without a network: writes a fixture tree into the directory it is handed.
private struct FakeRepositoryFetcher: SkillRepositoryFetching {
    let files: [String: String]
    let commit: String?

    init(files: [String: String], commit: String? = "abc123") {
        self.files = files
        self.commit = commit
    }

    func clone(
        _ source: SkillSourceURL,
        token: String?,
        into directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
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
        commit
    }
}

private func repositorySkill(_ name: String, description: String = "From a repo.") -> String {
    """
    ---
    name: \(name)
    description: \(description)
    ---

    BODY
    """
}

extension SkillsStoreTests {
    private func makeRepositoryStore(
        fetcher: any SkillRepositoryFetching = FakeRepositoryFetcher(files: [:]),
        policy: NetworkAccessPolicy = NetworkAccessPolicy()
    ) -> SkillsStore {
        SkillsStore(
            directory: skillsDirectory,
            fetcher: fetcher,
            policy: { policy },
            workingRoot: root.appendingPathComponent("Fetches", isDirectory: true)
        )
    }

    func testImportsSelectedSkillsFromARepository() async throws {
        let fetcher = FakeRepositoryFetcher(files: [
            "skills/find-skills/SKILL.md": repositorySkill("find-skills"),
            "skills/pdf-tools/SKILL.md": repositorySkill("pdf-tools")
        ])
        let store = makeRepositoryStore(fetcher: fetcher)

        let repository = try await store.fetchRepository("vercel-labs/skills")
        let imported = try await store.importSkills(from: repository, names: ["find-skills"])

        XCTAssertEqual(imported.map(\.name), ["find-skills"])
        XCTAssertEqual(store.global.skills.map(\.name), ["find-skills"])
        let provenance = try XCTUnwrap(store.provenance(for: "find-skills"))
        XCTAssertEqual(provenance.repository, "https://github.com/vercel-labs/skills")
        XCTAssertEqual(provenance.commit, "abc123")
        XCTAssertEqual(provenance.path, "skills/find-skills/SKILL.md")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: skillsDirectory.appendingPathComponent(".sources.json").path)
        )
        repository.remove()
    }

    func testRepositoryImportIsRefusedWhenAnySelectionCollides() async throws {
        let store = makeRepositoryStore(fetcher: FakeRepositoryFetcher(files: [
            "skills/find-skills/SKILL.md": repositorySkill("find-skills"),
            "skills/pdf-tools/SKILL.md": repositorySkill("pdf-tools")
        ]))
        _ = try await store.importSkill(from: try makeFolderSkill(
            folder: "existing",
            name: "pdf-tools",
            description: "Already here."
        ))

        let repository = try await store.fetchRepository("vercel-labs/skills")
        await XCTAssertThrowsErrorAsync(try await store.importSkills(
            from: repository,
            names: ["find-skills", "pdf-tools"]
        )) { error in
            XCTAssertEqual(error as? SkillImportError, .nameTaken("pdf-tools"))
        }

        XCTAssertEqual(store.global.skills.map(\.name), ["pdf-tools"], "nothing from the batch should land")
        XCTAssertNil(store.provenance(for: "find-skills"))
        repository.remove()
    }

    func testProvenanceSurvivesAReopen() async throws {
        let fetcher = FakeRepositoryFetcher(files: [
            "skills/find-skills/SKILL.md": repositorySkill("find-skills")
        ])
        let store = makeRepositoryStore(fetcher: fetcher)
        let repository = try await store.fetchRepository("vercel-labs/skills")
        _ = try await store.importSkills(from: repository, names: ["find-skills"])
        repository.remove()

        let reopened = makeRepositoryStore()
        await reopened.refresh()

        XCTAssertEqual(reopened.provenance(for: "find-skills")?.commit, "abc123")
    }

    func testDeletingASkillForgetsItsProvenance() async throws {
        let store = makeRepositoryStore(fetcher: FakeRepositoryFetcher(files: [
            "skills/find-skills/SKILL.md": repositorySkill("find-skills")
        ]))
        let repository = try await store.fetchRepository("vercel-labs/skills")
        _ = try await store.importSkills(from: repository, names: ["find-skills"])
        repository.remove()

        try await store.delete(named: "find-skills")

        XCTAssertNil(store.provenance(for: "find-skills"))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: skillsDirectory.appendingPathComponent(".sources.json").path)
        )
    }

    func testRepositoryFetchHonoursTheNetworkPolicy() async throws {
        let store = makeRepositoryStore(policy: NetworkAccessPolicy(isEnabled: false))

        await XCTAssertThrowsErrorAsync(try await store.fetchRepository("vercel-labs/skills")) { error in
            XCTAssertEqual(error as? SkillFetchError, .networkDisabled)
        }
    }
}

extension SkillsStoreTests {
    func testSavingASkillRewritesItsFile() async throws {
        _ = try await store.importSkill(from: try makeFolderSkill(
            folder: "edit",
            name: "edit-me",
            description: "Before."
        ))
        let before = try String(
            contentsOf: skillsDirectory.appendingPathComponent("edit-me/SKILL.md"),
            encoding: .utf8
        )

        let updated = try await store.saveSkill("edit-me", text: """
        ---
        name: edit-me
        description: After.
        ---

        NEW BODY
        """)

        XCTAssertEqual(updated.description, "After.")
        XCTAssertEqual(store.global.skills.first?.description, "After.")
        let after = try String(
            contentsOf: skillsDirectory.appendingPathComponent("edit-me/SKILL.md"),
            encoding: .utf8
        )
        XCTAssertNotEqual(before, after)
        XCTAssertTrue(after.contains("NEW BODY"))
    }

    func testSavingKeepsBundledFiles() async throws {
        let source = try makeFolderSkill(folder: "bundled", name: "bundled", description: "Before.")
        try write("references/formats.md", to: source, content: "formats")
        _ = try await store.importSkill(from: source)

        _ = try await store.saveSkill("bundled", text: """
        ---
        name: bundled
        description: After.
        ---
        """)

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: skillsDirectory.appendingPathComponent("bundled/references/formats.md").path
            )
        )
    }

    func testSavingWithoutADescriptionIsRefusedAndLeavesTheFileAlone() async throws {
        _ = try await store.importSkill(from: try makeFolderSkill(
            folder: "edit",
            name: "edit-me",
            description: "Before."
        ))
        let path = skillsDirectory.appendingPathComponent("edit-me/SKILL.md")
        let original = try String(contentsOf: path, encoding: .utf8)

        await XCTAssertThrowsErrorAsync(try await store.saveSkill("edit-me", text: "no frontmatter")) { error in
            guard case .invalid = error as? SkillImportError else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), original)
        XCTAssertEqual(store.global.skills.first?.description, "Before.")
    }

    func testSavingUnderADifferentNameIsRefused() async throws {
        _ = try await store.importSkill(from: try makeFolderSkill(
            folder: "edit",
            name: "edit-me",
            description: "Before."
        ))

        await XCTAssertThrowsErrorAsync(try await store.saveSkill("edit-me", text: """
        ---
        name: renamed
        description: After.
        ---
        """)) { error in
            XCTAssertEqual(error as? SkillImportError, .nameMismatch(expected: "edit-me", found: "renamed"))
        }
        XCTAssertEqual(store.global.skills.map(\.name), ["edit-me"])
    }

    func testSavingAnUnknownSkillIsRefused() async throws {
        await XCTAssertThrowsErrorAsync(try await store.saveSkill("ghost", text: "x")) { error in
            XCTAssertEqual(error as? SkillImportError, .notEditable("ghost"))
        }
    }

    func testSavingAProjectSkillIsRefused() async throws {
        let project = try makeProject(named: "Demo")
        let skillDirectory = project.directory.appendingPathComponent(".agents/skills/local")
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        try """
        ---
        name: local
        description: In the repo.
        ---
        """.write(
            to: skillDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        let store = SkillsStore(directory: skillsDirectory, projects: { [project] })
        await store.refresh()

        await XCTAssertThrowsErrorAsync(try await store.saveSkill("local", text: "x")) { error in
            XCTAssertEqual(error as? SkillImportError, .notEditable("local"))
        }
    }
}

/// A fake that can move its remote HEAD between calls, and counts handshakes — the
/// "one check per repository" rule needs something to observe.
private actor MutableRepositoryFetcher: SkillRepositoryFetching {
    private var files: [String: String]
    private var commit: String?
    private var latest: String?
    private(set) var latestCalls: [String] = []
    private var latestFailure: SkillFetchError?

    func setLatestFailureForTesting(_ error: SkillFetchError?) {
        latestFailure = error
    }

    init(files: [String: String], commit: String? = "abc123") {
        self.files = files
        self.commit = commit
        self.latest = commit
    }

    /// A clone taken now would land on the new HEAD, so both move together.
    func setLatest(_ value: String?) {
        latest = value
        commit = value
    }

    func setFiles(_ value: [String: String]) {
        files = value
    }

    func clone(
        _ source: SkillSourceURL,
        token: String?,
        into directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
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
        latestCalls.append(source.url.absoluteString)
        if let latestFailure { throw latestFailure }
        return latest
    }

    func recordedLatestCalls() -> [String] {
        latestCalls
    }
}

extension SkillsStoreTests {
    private func makeUpdateStore(fetcher: MutableRepositoryFetcher) -> SkillsStore {
        SkillsStore(
            directory: skillsDirectory,
            fetcher: fetcher,
            workingRoot: root.appendingPathComponent("Fetches", isDirectory: true)
        )
    }

    private func importFindSkills(_ store: SkillsStore) async throws {
        let repository = try await store.fetchRepository("vercel-labs/skills")
        try await store.importSkills(from: repository, names: ["find-skills"])
        repository.remove()
    }

    func testCheckForUpdatesFindsANewerCommit() async throws {
        let fetcher = MutableRepositoryFetcher(files: [
            "skills/find-skills/SKILL.md": repositorySkill("find-skills")
        ])
        let store = makeUpdateStore(fetcher: fetcher)
        try await importFindSkills(store)
        await fetcher.setLatest("def456")

        await store.checkForUpdates()

        XCTAssertEqual(store.updates["find-skills"]?.latestCommit, "def456")
        XCTAssertEqual(store.updates["find-skills"]?.currentCommit, "abc123")
        XCTAssertTrue(store.updateErrors.isEmpty)
    }

    func testCheckForUpdatesIsQuietWhenNothingMoved() async throws {
        let fetcher = MutableRepositoryFetcher(files: [
            "skills/find-skills/SKILL.md": repositorySkill("find-skills")
        ])
        let store = makeUpdateStore(fetcher: fetcher)
        try await importFindSkills(store)

        await store.checkForUpdates()

        XCTAssertTrue(store.updates.isEmpty)
    }

    func testOneCheckPerRepository() async throws {
        let fetcher = MutableRepositoryFetcher(files: [
            "skills/find-skills/SKILL.md": repositorySkill("find-skills"),
            "skills/pdf-tools/SKILL.md": repositorySkill("pdf-tools")
        ])
        let store = makeUpdateStore(fetcher: fetcher)
        let repository = try await store.fetchRepository("vercel-labs/skills")
        try await store.importSkills(from: repository, names: ["find-skills", "pdf-tools"])
        repository.remove()
        await fetcher.setLatest("def456")

        await store.checkForUpdates()

        let calls = await fetcher.recordedLatestCalls()
        XCTAssertEqual(calls, ["https://github.com/vercel-labs/skills"])
        XCTAssertEqual(Set(store.updates.keys), ["find-skills", "pdf-tools"])
    }

    func testUpdateInstallsTheNewContentAndCommit() async throws {
        let fetcher = MutableRepositoryFetcher(files: [
            "skills/find-skills/SKILL.md": repositorySkill("find-skills")
        ])
        let store = makeUpdateStore(fetcher: fetcher)
        try await importFindSkills(store)
        await fetcher.setLatest("def456")
        await fetcher.setFiles([
            "skills/find-skills/SKILL.md": """
            ---
            name: find-skills
            description: From a repo, v2.
            ---

            NEW BODY
            """
        ])
        await store.checkForUpdates()

        let updated = try await store.update("find-skills")

        XCTAssertEqual(updated.description, "From a repo, v2.")
        let installed = try String(
            contentsOf: skillsDirectory.appendingPathComponent("find-skills/SKILL.md"),
            encoding: .utf8
        )
        XCTAssertTrue(installed.contains("NEW BODY"))
        XCTAssertEqual(store.provenance(for: "find-skills")?.commit, "def456")
        XCTAssertTrue(store.updates.isEmpty)
    }

    func testUpdateRefusesASkillWithNoProvenance() async throws {
        let fetcher = MutableRepositoryFetcher(files: [:])
        let store = makeUpdateStore(fetcher: fetcher)
        _ = try await store.importSkill(from: try makeFolderSkill(
            folder: "local",
            name: "local",
            description: "Not from a repo."
        ))

        await XCTAssertThrowsErrorAsync(try await store.update("local")) { error in
            XCTAssertEqual(error as? SkillImportError, .notImported("local"))
        }
    }

    func testAFailedCheckIsReportedButDoesNotThrow() async throws {
        let fetcher = MutableRepositoryFetcher(files: [
            "skills/find-skills/SKILL.md": repositorySkill("find-skills")
        ])
        let store = makeUpdateStore(fetcher: fetcher)
        try await importFindSkills(store)
        await fetcher.setLatest(nil)
        await fetcher.setLatestFailureForTesting(.cloneFailed("offline"))

        await store.checkForUpdates()

        XCTAssertTrue(store.updates.isEmpty)
        XCTAssertEqual(store.updateErrors.count, 1)
        XCTAssertNotNil(store.lastUpdateCheck)
    }
}

/// `XCTAssertThrowsError` only covers synchronous throws; these flows are async.
@MainActor
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ handler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error to be thrown", file: file, line: line)
    } catch {
        handler(error)
    }
}
