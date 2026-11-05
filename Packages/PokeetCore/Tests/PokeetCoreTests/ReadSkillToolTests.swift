import Foundation
import Testing
@testable import PokeetCore

/// `read_file` is the only way a skill body reaches the model, so the `skill://`
/// dispatch has to be tested where the model actually calls it: through the tool.
struct ReadSkillToolTests {
    @Test func readsUserSkillBody() async throws {
        let project = try TestDirectory()
        let user = try TestDirectory()
        defer { project.cleanup(); user.cleanup() }
        try user.write("skills/pdf-tools/SKILL.md", frontmatter(body: "STEP ONE\nSTEP TWO"))

        let catalog = SkillCatalog.load(projectRoot: project.url, userSkillsDirectory: user.url.appending(path: "skills"))
        let output = try await ReadFileTool().execute(
            arguments: Data(#"{"path":"skill://pdf-tools/SKILL.md"}"#.utf8),
            context: ToolContext(
                workspace: FileWorkspace(root: project.url),
                skills: catalog
            )
        )

        #expect(output.content.contains("STEP ONE"))
        #expect(output.content.contains("STEP TWO"))
        // Frontmatter is part of the file; only the body matters to the model, but it
        // must not be silently dropped from the transcript either.
        #expect(output.content.contains("description:"))
    }

    @Test func reportsUnknownSkills() async throws {
        let project = try TestDirectory()
        defer { project.cleanup() }

        await #expect(throws: ToolError.self) {
            try await ReadFileTool().execute(
                arguments: Data(#"{"path":"skill://missing/SKILL.md"}"#.utf8),
                context: ToolContext(workspace: FileWorkspace(root: project.url))
            )
        }
    }

    @Test func stillReadsProjectSkillsThroughTheWorkspace() async throws {
        let project = try TestDirectory()
        defer { project.cleanup() }
        try project.write(".agents/skills/pdf-tools/SKILL.md", frontmatter(body: "PROJECT STEP"))

        let catalog = SkillCatalog.load(projectRoot: project.url, userSkillsDirectory: nil)
        let output = try await ReadFileTool().execute(
            arguments: Data(#"{"path":".agents/skills/pdf-tools/SKILL.md"}"#.utf8),
            context: ToolContext(
                workspace: FileWorkspace(root: project.url),
                skills: catalog
            )
        )

        #expect(output.content.contains("PROJECT STEP"))
    }

    private func frontmatter(body: String) -> String {
        """
        ---
        name: pdf-tools
        description: Extract text.
        ---

        \(body)
        """
    }
}
