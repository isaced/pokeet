import Foundation
import Testing
@testable import PokeetCore

struct SkillSessionTests {
    @Test func injectsAvailableSkillsIntoTheSystemPrompt() async throws {
        let project = try TestDirectory()
        defer { project.cleanup() }
        try project.write(
            ".agents/skills/pdf-tools/SKILL.md",
            frontmatter(name: "pdf-tools", description: "Extract text from PDFs.", body: "PROCEDURE")
        )

        let client = ScriptedModelClient([
            ChatResponse(message: .assistant("Done."), finishReason: "stop")
        ])
        let session = AgentSession(
            client: client,
            workspace: FileWorkspace(root: project.url),
            skills: SkillLocations(projectRoot: project.url)
        )

        try await session.send("hi", approval: { _ in [] }, onEvent: { _ in })

        let requests = await client.recordedRequests()
        let system = requests.first?.messages.first?.content ?? ""
        #expect(system.contains("<available_skills>"))
        #expect(system.contains("<name>pdf-tools</name>"))
        #expect(!system.contains("PROCEDURE"))
        #expect(await session.loadedSkills.skills.count == 1)
    }

    @Test func sessionsWithoutSkillsKeepTheOldPrompt() async throws {
        let project = try TestDirectory()
        defer { project.cleanup() }
        try project.write(
            ".agents/skills/pdf-tools/SKILL.md",
            frontmatter(name: "pdf-tools", description: "Extract text from PDFs.")
        )

        let session = AgentSession(
            client: ScriptedModelClient([]),
            workspace: FileWorkspace(root: project.url)
        )

        let history = await session.history
        let system = history.first?.content ?? ""

        #expect(system.contains("<available_skills>") == false)
    }

    @Test func expandsSkillCommandsWithArguments() async throws {
        let project = try TestDirectory()
        defer { project.cleanup() }
        try project.write(
            ".agents/skills/pdf-tools/SKILL.md",
            frontmatter(name: "pdf-tools", description: "Extract text.", body: "STEP ONE")
        )

        let client = ScriptedModelClient([
            ChatResponse(message: .assistant("Done."), finishReason: "stop")
        ])
        let session = AgentSession(
            client: client,
            workspace: FileWorkspace(root: project.url),
            skills: SkillLocations(projectRoot: project.url)
        )

        try await session.send(
            "/skill:pdf-tools extract report.pdf",
            approval: { _ in [] },
            onEvent: { _ in }
        )

        let requests = await client.recordedRequests()
        let user = try #require(requests.first?.messages.first { $0.role == .user }?.content)
        #expect(user.contains(#"<skill name="pdf-tools" location=".agents/skills/pdf-tools/SKILL.md">"#))
        #expect(user.contains("References are relative to .agents/skills/pdf-tools."))
        #expect(user.contains("STEP ONE"))
        #expect(user.hasSuffix("extract report.pdf"))
    }

    @Test func expandsHiddenSkillsThatThePromptWithheld() async throws {
        let project = try TestDirectory()
        defer { project.cleanup() }
        try project.write(
            ".agents/skills/manual/SKILL.md",
            frontmatter(
                name: "manual",
                description: "Only on request.",
                body: "MANUAL STEP",
                disableModelInvocation: true
            )
        )

        let client = ScriptedModelClient([
            ChatResponse(message: .assistant("Done."), finishReason: "stop")
        ])
        let session = AgentSession(
            client: client,
            workspace: FileWorkspace(root: project.url),
            skills: SkillLocations(projectRoot: project.url)
        )

        try await session.send("/skill:manual", approval: { _ in [] }, onEvent: { _ in })

        let requests = await client.recordedRequests()
        let user = try #require(requests.first?.messages.first { $0.role == .user }?.content)
        #expect(user.contains("MANUAL STEP"))
        let system = requests.first?.messages.first?.content ?? ""
        #expect(!system.contains("Only on request."))
    }

    @Test func unknownSkillCommandsSayWhatIsAvailable() async throws {
        let project = try TestDirectory()
        defer { project.cleanup() }
        try project.write(
            ".agents/skills/pdf-tools/SKILL.md",
            frontmatter(name: "pdf-tools", description: "Extract text.")
        )

        let client = ScriptedModelClient([
            ChatResponse(message: .assistant("Done."), finishReason: "stop")
        ])
        let session = AgentSession(
            client: client,
            workspace: FileWorkspace(root: project.url),
            skills: SkillLocations(projectRoot: project.url)
        )

        try await session.send("/skill:missing do it", approval: { _ in [] }, onEvent: { _ in })

        let requests = await client.recordedRequests()
        let user = try #require(requests.first?.messages.first { $0.role == .user }?.content)
        #expect(user.contains("no skill named \"missing\""))
        #expect(user.contains("pdf-tools"))
        #expect(user.contains("/skill:missing do it"))
    }

    @Test func plainMessagesAreLeftAlone() async throws {
        let project = try TestDirectory()
        defer { project.cleanup() }

        let client = ScriptedModelClient([
            ChatResponse(message: .assistant("Done."), finishReason: "stop")
        ])
        let session = AgentSession(
            client: client,
            workspace: FileWorkspace(root: project.url),
            skills: SkillLocations(projectRoot: project.url)
        )

        try await session.send(
            "how do I /skill: this?",
            approval: { _ in [] },
            onEvent: { _ in }
        )

        let requests = await client.recordedRequests()
        let user = try #require(requests.first?.messages.first { $0.role == .user }?.content)
        #expect(user.isEmpty == false)
        #expect(user == "how do I /skill: this?")
    }

    @Test func excludedSkillsLeaveThePromptButStayInvocable() async throws {
        let project = try TestDirectory()
        defer { project.cleanup() }
        try project.write(
            ".agents/skills/pdf-tools/SKILL.md",
            frontmatter(name: "pdf-tools", description: "Extract text.", body: "STEP ONE")
        )

        let client = ScriptedModelClient([
            ChatResponse(message: .assistant("First."), finishReason: "stop"),
            ChatResponse(message: .assistant("Second."), finishReason: "stop")
        ])
        let session = AgentSession(
            client: client,
            workspace: FileWorkspace(root: project.url),
            skills: SkillLocations(projectRoot: project.url),
            excludedSkills: ["pdf-tools"]
        )

        try await session.send("hi", approval: { _ in [] }, onEvent: { _ in })
        try await session.send("/skill:pdf-tools go", approval: { _ in [] }, onEvent: { _ in })

        let requests = await client.recordedRequests()
        let system = requests.first?.messages.first?.content ?? ""
        #expect(system.contains("<name>pdf-tools</name>") == false)
        #expect(system.contains("<available_skills>") == false)
        let user = try #require(requests.last?.messages.last { $0.role == .user }?.content)
        #expect(user.contains("STEP ONE"), "explicit commands still load a disabled skill")
    }

    @Test func setExcludedSkillsRewritesThePrompt() async throws {
        let project = try TestDirectory()
        defer { project.cleanup() }
        try project.write(
            ".agents/skills/pdf-tools/SKILL.md",
            frontmatter(name: "pdf-tools", description: "Extract text.")
        )

        let client = ScriptedModelClient([
            ChatResponse(message: .assistant("Done."), finishReason: "stop")
        ])
        let session = AgentSession(
            client: client,
            workspace: FileWorkspace(root: project.url),
            skills: SkillLocations(projectRoot: project.url)
        )
        await session.setExcludedSkills(["pdf-tools"])

        try await session.send("hi", approval: { _ in [] }, onEvent: { _ in })

        let requests = await client.recordedRequests()
        let system = requests.first?.messages.first?.content ?? ""
        #expect(system.contains("<name>pdf-tools</name>") == false)
        #expect(await session.loadedExcludedSkills == ["pdf-tools"])
    }

    @Test func reloadSkillsPicksUpNewFiles() async throws {
        let project = try TestDirectory()
        defer { project.cleanup() }

        let client = ScriptedModelClient([
            ChatResponse(message: .assistant("First."), finishReason: "stop"),
            ChatResponse(message: .assistant("Second."), finishReason: "stop")
        ])
        let session = AgentSession(
            client: client,
            workspace: FileWorkspace(root: project.url),
            skills: SkillLocations(projectRoot: project.url)
        )
        try await session.send("one", approval: { _ in [] }, onEvent: { _ in })

        try project.write(
            ".agents/skills/late/SKILL.md",
            frontmatter(name: "late", description: "Added later.")
        )
        #expect(await session.loadedSkills.isEmpty)
        await session.reloadSkills()
        #expect(await session.loadedSkills.skills.map(\.name) == ["late"])

        try await session.send("two", approval: { _ in [] }, onEvent: { _ in })

        let requests = await client.recordedRequests()
        let latest = try #require(requests.last?.messages.first?.content)
        #expect(latest.contains("<name>late</name>"))
    }

    @Test func restoringHistoryKeepsTheSkillSection() async throws {
        let project = try TestDirectory()
        defer { project.cleanup() }
        try project.write(
            ".agents/skills/pdf-tools/SKILL.md",
            frontmatter(name: "pdf-tools", description: "Extract text.")
        )

        let session = AgentSession(
            client: ScriptedModelClient([]),
            workspace: FileWorkspace(root: project.url),
            skills: SkillLocations(projectRoot: project.url)
        )
        await session.restore([.system("stale"), .user("hi")])

        let history = await session.history
        #expect(history.first?.content?.contains("<name>pdf-tools</name>") == true)
    }

    private func frontmatter(
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
