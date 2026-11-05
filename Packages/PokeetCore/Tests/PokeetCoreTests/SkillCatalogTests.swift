import Foundation
import Testing
@testable import PokeetCore

struct SkillCatalogTests {
    // MARK: - Discovery

    @Test func loadsProjectSkillFromAgentsDirectory() throws {
        let project = try TestDirectory()
        defer { project.cleanup() }
        try project.write(
            ".agents/skills/pdf-tools/SKILL.md",
            markdown(
                name: "pdf-tools",
                description: "Extract text and tables from PDF files.",
                body: "Read references/formats.md first."
            )
        )

        let catalog = SkillCatalog.load(projectRoot: project.url, userSkillsDirectory: nil)

        #expect(catalog.issues.isEmpty)
        let skill = try #require(catalog.skills.first)
        #expect(catalog.skills.count == 1)
        #expect(skill.name == "pdf-tools")
        #expect(skill.description == "Extract text and tables from PDF files.")
        #expect(skill.location == ".agents/skills/pdf-tools/SKILL.md")
        #expect(skill.directory == ".agents/skills/pdf-tools")
        #expect(skill.source == .project)
        #expect(skill.disablesModelInvocation == false)
    }

    @Test func loadsPokeetAndUserRoots() throws {
        let project = try TestDirectory()
        let user = try TestDirectory()
        defer { project.cleanup(); user.cleanup() }
        try project.write(".pokeet/skills/release/SKILL.md", markdown(name: "release"))
        try user.write("skills/commit/SKILL.md", markdown(name: "commit"))

        let catalog = SkillCatalog.load(projectRoot: project.url, userSkillsDirectory: user.url.appending(path: "skills"))

        #expect(catalog.skills.map(\.name) == ["release", "commit"])
        #expect(catalog.skills.map(\.source) == [.project, .user])
        #expect(catalog.skills.last?.location == "skill://commit/SKILL.md")
        #expect(catalog.skills.last?.directory == "skill://commit")
    }

    @Test func fallsBackToDirectoryNameWhenNameIsMissing() throws {
        let project = try TestDirectory()
        defer { project.cleanup() }
        try project.write(
            ".agents/skills/dir-named/SKILL.md",
            markdown(name: nil, description: "Described.")
        )

        let catalog = SkillCatalog.load(projectRoot: project.url, userSkillsDirectory: nil)

        #expect(catalog.skills.first?.name == "dir-named")
    }

    @Test func discoversNestedSkillDirectories() throws {
        let project = try TestDirectory()
        defer { project.cleanup() }
        try project.write(".agents/skills/pack/writing/SKILL.md", markdown(name: "writing"))

        let catalog = SkillCatalog.load(projectRoot: project.url, userSkillsDirectory: nil)

        #expect(catalog.skills.first?.location == ".agents/skills/pack/writing/SKILL.md")
    }

    @Test func stopsAtTheDepthCap() throws {
        let project = try TestDirectory()
        defer { project.cleanup() }
        try project.write(".agents/skills/a/b/c/d/SKILL.md", markdown(name: "shallow"))
        try project.write(".agents/skills/a/b/c/d/e/SKILL.md", markdown(name: "too-deep"))

        let catalog = SkillCatalog.load(projectRoot: project.url, userSkillsDirectory: nil)

        #expect(catalog.skills.map(\.name) == ["shallow"])
    }

    @Test func skillDirectoryIsALeaf() throws {
        let project = try TestDirectory()
        defer { project.cleanup() }
        try project.write(".agents/skills/outer/SKILL.md", markdown(name: "outer"))
        try project.write(".agents/skills/outer/inner/SKILL.md", markdown(name: "inner"))

        let catalog = SkillCatalog.load(projectRoot: project.url, userSkillsDirectory: nil)

        #expect(catalog.skills.map(\.name) == ["outer"])
    }

    @Test func skipsHeavyAndHiddenDirectories() throws {
        let project = try TestDirectory()
        defer { project.cleanup() }
        for directory in ["node_modules", "Pods", "Vendor", ".build", ".git", ".hidden"] {
            try project.write(".agents/skills/\(directory)/SKILL.md", markdown(name: directory))
        }

        let catalog = SkillCatalog.load(projectRoot: project.url, userSkillsDirectory: nil)

        #expect(catalog.skills.isEmpty)
    }

    @Test func skipsSymlinkedSkillFiles() throws {
        let project = try TestDirectory()
        let outside = try TestDirectory()
        defer { project.cleanup(); outside.cleanup() }
        try outside.write("SKILL.md", markdown(name: "linked", description: "Outside the repo."))
        try FileManager.default.createDirectory(
            at: project.url.appending(path: ".agents/skills/linked"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: project.url.appending(path: ".agents/skills/linked/SKILL.md"),
            withDestinationURL: outside.url.appending(path: "SKILL.md")
        )

        let catalog = SkillCatalog.load(projectRoot: project.url, userSkillsDirectory: nil)

        #expect(catalog.skills.isEmpty)
    }

    @Test func ignoresTopLevelMarkdownFiles() throws {
        let project = try TestDirectory()
        defer { project.cleanup() }
        try project.write(".agents/skills/notes.md", markdown(name: "notes"))

        let catalog = SkillCatalog.load(projectRoot: project.url, userSkillsDirectory: nil)

        #expect(catalog.skills.isEmpty)
    }

    @Test func skipsSkillsIgnoredByGitignore() throws {
        let project = try TestDirectory()
        defer { project.cleanup() }
        try project.write(".gitignore", "private/\n")
        try project.write(".agents/skills/private/SKILL.md", markdown(name: "private"))
        try project.write(".agents/skills/shared/SKILL.md", markdown(name: "shared"))

        let catalog = SkillCatalog.load(projectRoot: project.url, userSkillsDirectory: nil)

        #expect(catalog.skills.map(\.name) == ["shared"])
    }

    @Test func missingProjectDirectoriesAreNotIssues() throws {
        let project = try TestDirectory()
        defer { project.cleanup() }

        let catalog = SkillCatalog.load(projectRoot: project.url, userSkillsDirectory: nil)

        #expect(catalog.isEmpty)
        #expect(catalog.issues.isEmpty)
    }

    // MARK: - Validation

    @Test func missingDescriptionSkipsTheSkill() throws {
        let project = try TestDirectory()
        defer { project.cleanup() }
        try project.write(".agents/skills/broken/SKILL.md", markdown(name: "broken", description: nil))
        try project.write(".agents/skills/also-broken/SKILL.md", "no frontmatter at all\n")

        let catalog = SkillCatalog.load(projectRoot: project.url, userSkillsDirectory: nil)

        #expect(catalog.skills.isEmpty)
        #expect(catalog.issues.count == 2)
        #expect(catalog.issues.allSatisfy { $0.message.contains("description") })
    }

    @Test func invalidNameWarnsButKeepsTheSkill() throws {
        let project = try TestDirectory()
        defer { project.cleanup() }
        try project.write(".agents/skills/loud/SKILL.md", markdown(name: "PDF Tools"))

        let catalog = SkillCatalog.load(projectRoot: project.url, userSkillsDirectory: nil)

        #expect(catalog.skills.map(\.name) == ["PDF Tools"])
        #expect(catalog.issues.contains { $0.message.contains("name") })
    }

    @Test func overlongNameAndDescriptionWarn() throws {
        let project = try TestDirectory()
        defer { project.cleanup() }
        try project.write(
            ".agents/skills/long/SKILL.md",
            markdown(
                name: String(repeating: "a", count: 65),
                description: String(repeating: "b", count: 1_025)
            )
        )

        let catalog = SkillCatalog.load(projectRoot: project.url, userSkillsDirectory: nil)

        #expect(catalog.skills.count == 1)
        #expect(catalog.issues.contains { $0.message.contains("name") })
        #expect(catalog.issues.contains { $0.message.contains("description") })
    }

    @Test func oversizedSkillFileIsSkipped() throws {
        let project = try TestDirectory()
        defer { project.cleanup() }
        try project.write(
            ".agents/skills/huge/SKILL.md",
            markdown(name: "huge", body: String(repeating: "x", count: SkillCatalog.maxSkillBytes))
        )

        let catalog = SkillCatalog.load(projectRoot: project.url, userSkillsDirectory: nil)

        #expect(catalog.skills.isEmpty)
        #expect(catalog.issues.contains { $0.message.contains("larger") })
    }

    @Test func nameCollisionKeepsTheProjectSkill() throws {
        let project = try TestDirectory()
        let user = try TestDirectory()
        defer { project.cleanup(); user.cleanup() }
        try project.write(".agents/skills/shared/SKILL.md", markdown(name: "shared", description: "project"))
        try user.write("skills/shared/SKILL.md", markdown(name: "shared", description: "user"))

        let catalog = SkillCatalog.load(projectRoot: project.url, userSkillsDirectory: user.url.appending(path: "skills"))

        #expect(catalog.skills.count == 1)
        #expect(catalog.skills.first?.description == "project")
        #expect(catalog.issues.contains { $0.message.contains("collision") })
    }

    // MARK: - Prompt section

    @Test func promptSectionCarriesMetadataOnly() throws {
        let project = try TestDirectory()
        defer { project.cleanup() }
        try project.write(
            ".agents/skills/pdf-tools/SKILL.md",
            markdown(name: "pdf-tools", description: "Extract text.", body: "SECRET PROCEDURE")
        )

        let catalog = SkillCatalog.load(projectRoot: project.url, userSkillsDirectory: nil)
        let composed = catalog.compose(with: "Base rules.")

        #expect(composed.hasPrefix("Base rules."))
        #expect(composed.contains("<available_skills>"))
        #expect(composed.contains("<name>pdf-tools</name>"))
        #expect(composed.contains("<description>Extract text.</description>"))
        #expect(composed.contains("<location>.agents/skills/pdf-tools/SKILL.md</location>"))
        #expect(composed.contains("read_file"))
        #expect(!composed.contains("SECRET PROCEDURE"))
    }

    @Test func promptEscapesMarkup() throws {
        let project = try TestDirectory()
        defer { project.cleanup() }
        try project.write(
            ".agents/skills/markup/SKILL.md",
            markdown(name: "markup", description: "<script> & \"quotes\"")
        )

        let catalog = SkillCatalog.load(projectRoot: project.url, userSkillsDirectory: nil)
        let composed = catalog.compose(with: "Base.")

        #expect(composed.contains("&lt;script&gt; &amp; &quot;quotes&quot;"))
        #expect(!composed.contains("<script>"))
    }

    @Test func skillsThatDisableModelInvocationStayOutOfThePrompt() throws {
        let project = try TestDirectory()
        defer { project.cleanup() }
        try project.write(
            ".agents/skills/manual/SKILL.md",
            markdown(name: "manual", description: "Only on request.", disableModelInvocation: true)
        )

        let catalog = SkillCatalog.load(projectRoot: project.url, userSkillsDirectory: nil)
        let composed = catalog.compose(with: "Base.")

        #expect(catalog.skill(named: "manual") != nil)
        #expect(!composed.contains("Only on request."))
        #expect(!composed.contains("<available_skills>"))
    }

    @Test func emptyCatalogLeavesThePromptAlone() {
        let catalog = SkillCatalog(skills: [])

        #expect(catalog.compose(with: "Base.") == "Base.")
        #expect(catalog.isEmpty)
    }

    @Test func promptSectionIsCapped() throws {
        let project = try TestDirectory()
        defer { project.cleanup() }
        for index in 0..<40 {
            try project.write(
                ".agents/skills/skill-\(String(format: "%02d", index))/SKILL.md",
                markdown(name: "skill-\(String(format: "%02d", index))", description: "Short.")
            )
        }

        let catalog = SkillCatalog.load(projectRoot: project.url, userSkillsDirectory: nil)
        let composed = catalog.compose(with: "Base.")

        let listed = composed.components(separatedBy: "<skill>").count - 1
        #expect(catalog.skills.count == 40)
        #expect(listed < 40)
        #expect(listed <= SkillCatalog.maxSkills)
        #expect(catalog.issues.contains { $0.message.contains("cap") })
        // Skills left out of the prompt are still reachable by name.
        #expect(catalog.skill(named: "skill-39") != nil)
    }

    @Test func loadsUserSkillsWithoutAProject() throws {
        let user = try TestDirectory()
        defer { user.cleanup() }
        try user.write("skills/commit/SKILL.md", markdown(name: "commit", description: "Write messages."))
        try user.write("skills/.staging-1/ghost/SKILL.md", markdown(name: "ghost"))

        let catalog = SkillCatalog.load(
            userSkillsDirectory: user.url.appending(path: "skills")
        )

        #expect(catalog.skills.map(\.name) == ["commit"])
        #expect(catalog.skills.first?.location == "skill://commit/SKILL.md")
        #expect(catalog.skills.first?.source == .user)
    }

    // MARK: - Inspection (import path)

    @Test func inspectsAValidSkillFolder() throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("pdf-tools/SKILL.md", markdown(name: "pdf-tools", description: "Extract text."))

        let inspection = SkillCatalog.inspect(
            directory.url.appending(path: "pdf-tools"),
            source: .user
        )

        #expect(inspection.issues.isEmpty)
        let skill = try #require(inspection.skill)
        #expect(skill.name == "pdf-tools")
        #expect(skill.description == "Extract text.")
        #expect(skill.source == .user)
    }

    @Test func inspectsASingleMarkdownFile() throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("standalone.md", markdown(name: "standalone", description: "One file."))

        let inspection = SkillCatalog.inspect(
            directory.url.appending(path: "standalone.md"),
            source: .user
        )

        #expect(inspection.issues.isEmpty)
        #expect(inspection.skill?.name == "standalone")
    }

    @Test func inspectionReportsAStandaloneFileWithoutDescription() throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("bare.md", "just prose\n")

        let inspection = SkillCatalog.inspect(
            directory.url.appending(path: "bare.md"),
            source: .user
        )

        #expect(inspection.skill == nil)
        #expect(inspection.issues.contains { $0.message.contains("description") })
    }

    @Test func inspectionRejectsAFolderWithoutSkillFile() throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("empty/notes.md", "nothing here\n")

        let inspection = SkillCatalog.inspect(
            directory.url.appending(path: "empty"),
            source: .user
        )

        #expect(inspection.skill == nil)
        #expect(inspection.issues.contains { $0.message.contains("SKILL.md") })
    }

    @Test func inspectionKeepsWarningsTheSkillWouldStillLoadWith() throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("loud/SKILL.md", markdown(name: "Loud Name", description: "Yelling."))

        let inspection = SkillCatalog.inspect(
            directory.url.appending(path: "loud"),
            source: .user
        )

        #expect(inspection.skill != nil)
        #expect(inspection.issues.contains { $0.message.contains("name") })
    }

    @Test func inspectionReportsAMissingPath() {
        let missing = FileManager.default.temporaryDirectory
            .appending(path: "pokeet-missing-\(UUID().uuidString)/SKILL.md")

        let inspection = SkillCatalog.inspect(missing, source: .user)

        #expect(inspection.skill == nil)
        #expect(inspection.issues.count == 1)
    }

    // MARK: - Repository scan (remote import)

    @Test func scansARepositoryForEverySkillFile() throws {
        let repo = try TestDirectory()
        defer { repo.cleanup() }
        try repo.write("skills/find-skills/SKILL.md", markdown(name: "find-skills", description: "Find them."))
        try repo.write("skills/pdf-tools/SKILL.md", markdown(name: "pdf-tools", description: "Read PDFs."))
        try repo.write(".agents/skills/nested/SKILL.md", markdown(name: "nested", description: "Also here."))
        try repo.write("README.md", "# repo\n")

        let catalog = SkillCatalog.scanRepository(at: repo.url)

        #expect(catalog.skills.map(\.name) == ["find-skills", "nested", "pdf-tools"])
        #expect(catalog.skills.map(\.location) == [
            "skills/find-skills/SKILL.md",
            ".agents/skills/nested/SKILL.md",
            "skills/pdf-tools/SKILL.md"
        ])
        #expect(catalog.issues.isEmpty)
    }

    @Test func repositoryScanSkipsGitAndHeavyDirectories() throws {
        let repo = try TestDirectory()
        defer { repo.cleanup() }
        try repo.write(".git/skills/x/SKILL.md", markdown(name: "x"))
        try repo.write("node_modules/pkg/SKILL.md", markdown(name: "pkg"))
        try repo.write("skills/real/SKILL.md", markdown(name: "real"))

        let catalog = SkillCatalog.scanRepository(at: repo.url)

        #expect(catalog.skills.map(\.name) == ["real"])
    }

    @Test func repositoryScanRespectsTheDepthCap() throws {
        let repo = try TestDirectory()
        defer { repo.cleanup() }
        try repo.write("a/b/c/d/SKILL.md", markdown(name: "shallow"))
        try repo.write("a/b/c/d/e/SKILL.md", markdown(name: "too-deep"))

        let catalog = SkillCatalog.scanRepository(at: repo.url)

        #expect(catalog.skills.map(\.name) == ["shallow"])
    }

    // MARK: - Source URL parsing

    @Test func parsesOwnerRepoShorthand() throws {
        let source = try SkillSourceURL.parse("vercel-labs/skills")

        #expect(source.url.absoluteString == "https://github.com/vercel-labs/skills")
        #expect(source.ref == nil)
        #expect(source.pathPrefix == nil)
    }

    @Test func parsesAFullRepositoryURL() throws {
        let source = try SkillSourceURL.parse("https://github.com/anthropics/skills.git")

        #expect(source.url.absoluteString == "https://github.com/anthropics/skills")
        #expect(source.ref == nil)
    }

    @Test func parsesATreeURLIntoRefAndPath() throws {
        let source = try SkillSourceURL.parse("https://github.com/vercel-labs/skills/tree/main/skills/find-skills")

        #expect(source.url.absoluteString == "https://github.com/vercel-labs/skills")
        #expect(source.ref == "main")
        #expect(source.pathPrefix == "skills/find-skills")
    }

    @Test func parsesAGitLabTreeURL() throws {
        let source = try SkillSourceURL.parse("https://gitlab.com/group/repo/-/tree/develop/skills/one")

        #expect(source.url.absoluteString == "https://gitlab.com/group/repo")
        #expect(source.ref == "develop")
        #expect(source.pathPrefix == "skills/one")
    }

    @Test func parsesAHashRef() throws {
        let source = try SkillSourceURL.parse("https://github.com/owner/repo#v1.2.0")

        #expect(source.ref == "v1.2.0")
        #expect(source.url.absoluteString == "https://github.com/owner/repo")
    }

    @Test func rejectsWhatIsNotARepository() {
        #expect(throws: SkillSourceError.self) { try SkillSourceURL.parse("") }
        #expect(throws: SkillSourceError.self) { try SkillSourceURL.parse("not a repo") }
        #expect(throws: SkillSourceError.self) { try SkillSourceURL.parse("ftp://example.com/x") }
        #expect(throws: SkillSourceError.self) { try SkillSourceURL.parse("https://github.com/owner") }
    }

    @Test func suggestsTheSkillFolderWhenThePathIsTooDeep() throws {
        let source = try SkillSourceURL.parse("https://github.com/vercel-labs/skills")
        let catalog = SkillCatalog(skills: [])

        #expect(catalog.skills.isEmpty)
        #expect(source.pathPrefix == nil)
    }

    // MARK: - Resolution

    @Test func resolvesUserSkillFiles() throws {
        let project = try TestDirectory()
        let user = try TestDirectory()
        defer { project.cleanup(); user.cleanup() }
        try user.write("skills/pdf-tools/SKILL.md", markdown(name: "pdf-tools", body: "BODY"))
        try user.write("skills/pdf-tools/references/formats.md", "formats")

        let catalog = SkillCatalog.load(projectRoot: project.url, userSkillsDirectory: user.url.appending(path: "skills"))

        let skillURL = try #require(catalog.resolve("skill://pdf-tools/SKILL.md"))
        #expect(skillURL.path.hasSuffix("skills/pdf-tools/SKILL.md"))

        let referenceURL = try #require(catalog.resolve("skill://pdf-tools/references/formats.md"))
        #expect(referenceURL.path.hasSuffix("skills/pdf-tools/references/formats.md"))
    }

    @Test func resolutionRefusesToEscapeTheSkillDirectory() throws {
        let project = try TestDirectory()
        let user = try TestDirectory()
        defer { project.cleanup(); user.cleanup() }
        try user.write("skills/pdf-tools/SKILL.md", markdown(name: "pdf-tools"))
        try user.write("AGENTS.md", "outside")

        let catalog = SkillCatalog.load(projectRoot: project.url, userSkillsDirectory: user.url.appending(path: "skills"))

        #expect(catalog.resolve("skill://pdf-tools/../../AGENTS.md") == nil)
        #expect(catalog.resolve("skill://pdf-tools/..") == nil)
        #expect(catalog.resolve("skill://pdf-tools/") == nil)
        #expect(catalog.resolve("skill://pdf-tools/missing.md") == nil)
        #expect(catalog.resolve("skill://unknown/SKILL.md") == nil)
        #expect(catalog.resolve(".agents/skills/pdf-tools/SKILL.md") == nil)
        #expect(catalog.resolve("/etc/passwd") == nil)
    }

    @Test func readsSkillBodyThroughTheCatalog() throws {
        let project = try TestDirectory()
        let user = try TestDirectory()
        defer { project.cleanup(); user.cleanup() }
        try user.write("skills/pdf-tools/SKILL.md", markdown(name: "pdf-tools", body: "STEP ONE"))

        let catalog = SkillCatalog.load(projectRoot: project.url, userSkillsDirectory: user.url.appending(path: "skills"))
        let text = try catalog.read("skill://pdf-tools/SKILL.md", maxBytes: 10_000)

        #expect(text.contains("STEP ONE"))
    }

    // MARK: - Helpers

    private func markdown(
        name: String? = "sample",
        description: String? = "A sample skill.",
        body: String = "Do the work.",
        disableModelInvocation: Bool = false
    ) -> String {
        var lines = ["---"]
        if let name { lines.append("name: \(name)") }
        if let description { lines.append("description: \(description)") }
        if disableModelInvocation { lines.append("disable-model-invocation: true") }
        lines.append("---")
        lines.append("")
        lines.append(body)
        return lines.joined(separator: "\n") + "\n"
    }
}
