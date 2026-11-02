import Foundation
import Testing
@testable import PokeetCore

struct ProjectInstructionsTests {
    @Test func prefersAgentsFileOverClaudeFile() throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("AGENTS.md", "agents rules\n")
        try directory.write("CLAUDE.md", "claude rules\n")

        let instructions = ProjectInstructions.load(from: FileWorkspace(root: directory.url))

        #expect(instructions.path == "AGENTS.md")
        #expect(instructions.content?.contains("agents rules") == true)
    }

    @Test func fallsBackToClaudeFile() throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("CLAUDE.md", "claude rules\n")

        let instructions = ProjectInstructions.load(from: FileWorkspace(root: directory.url))

        #expect(instructions.path == "CLAUDE.md")
        #expect(instructions.content?.contains("claude rules") == true)
    }

    @Test func missingOrEmptyFilesProduceNoInstructions() throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("AGENTS.md", "   \n\n")

        let instructions = ProjectInstructions.load(from: FileWorkspace(root: directory.url))

        #expect(instructions.isEmpty)
        #expect(instructions.path == nil)
        #expect(instructions.compose(with: "base") == "base")
    }

    @Test func composesInstructionsAfterTheBasePrompt() {
        let instructions = ProjectInstructions(
            path: "AGENTS.md",
            content: "Use tabs."
        )
        let composed = instructions.compose(with: "Base rules.")

        #expect(composed.hasPrefix("Base rules."))
        #expect(composed.contains("Project instructions from AGENTS.md"))
        #expect(composed.contains("<project_instructions>\nUse tabs.\n</project_instructions>"))
    }

    @Test func truncatesOversizedInstructions() throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write(
            "AGENTS.md",
            String(repeating: "a\n", count: ProjectInstructions.maxBytes)
        )

        let instructions = ProjectInstructions.load(from: FileWorkspace(root: directory.url))

        #expect(instructions.path == "AGENTS.md")
        #expect(instructions.content?.contains("[truncated at \(ProjectInstructions.maxBytes) bytes]") == true)
        #expect((instructions.content?.count ?? 0) < ProjectInstructions.maxBytes + 100)
    }
}
