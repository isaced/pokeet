import PokeetCore
import XCTest
@testable import Pokeet

/// Global (app-level) skills are the half of the feature that has no repository to
/// live in: they sit in the app's own container and must work in every project.
/// These tests go through the real stack — `AppEnvironment` → `SessionRuntime` →
/// `AgentSession` — on the simulator's filesystem, not through a stub catalog.
private final class MemorySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func string(for key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func set(_ value: String, for key: String) {
        lock.lock()
        values[key] = value
        lock.unlock()
    }

    func delete(_ key: String) {
        lock.lock()
        values.removeValue(forKey: key)
        lock.unlock()
    }
}

/// Scripted on purpose: one back-and-forth per response, so a test can assert on the
/// exact prompt the model would have seen.
private actor ScriptedModelClient: ModelClient {
    private var responses: [ChatResponse]
    private(set) var requests: [ChatRequest] = []

    init(_ responses: [ChatResponse]) {
        self.responses = responses
    }

    func complete(_ request: ChatRequest) async throws -> ChatResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            throw ModelError.invalidResponse("Script exhausted")
        }
        return responses.removeFirst()
    }

    func recordedRequests() -> [ChatRequest] {
        requests
    }
}

@MainActor
final class GlobalSkillsTests: XCTestCase {
    private var root: URL!
    private var skillsDirectory: URL!
    private var environment: AppEnvironment!
    private var project: Project!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pokeet-global-skills-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let projectDirectory = root.appendingPathComponent("Demo", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        project = Project(directory: projectDirectory, remoteHost: nil, isGitRepository: false)

        skillsDirectory = root.appendingPathComponent("AppSkills", isDirectory: true)
        environment = AppEnvironment(
            settings: AppSettings(
                defaults: UserDefaults(suiteName: "pokeet-global-skills-\(UUID().uuidString)")!,
                secrets: MemorySecrets()
            ),
            projects: ProjectStore(documentsURL: root),
            sessions: SessionStore(directory: root.appendingPathComponent("Sessions", isDirectory: true)),
            git: SwiftGitXGitService(),
            scripting: .empty,
            skillsDirectory: skillsDirectory
        )
    }

    override func tearDown() async throws {
        environment = nil
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try await super.tearDown()
    }

    // MARK: - Tests

    func testInitializingCreatesTheSkillsDirectory() {
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: skillsDirectory.path),
            "The app has to create the directory, or there is nowhere to put a global skill."
        )
    }

    func testGlobalSkillReachesTheSystemPrompt() async throws {
        try writeGlobalSkill(name: "pdf-tools", description: "Extract text from PDFs.", body: "STEP ONE")

        let client = ScriptedModelClient([
            ChatResponse(message: .assistant("Done."), finishReason: "stop")
        ])
        let runtime = makeRuntime(client: client)
        await runtime.loadInitialState()
        _ = runtime.attach()
        runtime.send(text: "hi")
        await waitUntil { !(await client.recordedRequests().isEmpty) }

        let requests = await client.recordedRequests()
        let system = try XCTUnwrap(requests.first?.messages.first?.content)
        XCTAssertTrue(system.contains("<available_skills>"))
        XCTAssertTrue(system.contains("<name>pdf-tools</name>"))
        XCTAssertTrue(system.contains("<location>skill://pdf-tools/SKILL.md</location>"))
        XCTAssertFalse(system.contains("STEP ONE"))
    }

    /// The whole point of the `skill://` scheme: a model in one project can follow a
    /// procedure that lives outside that project's sandbox, and only that procedure.
    func testGlobalSkillBodyLoadsThroughTheReadFileTool() async throws {
        try writeGlobalSkill(name: "pdf-tools", description: "Extract text.", body: "STEP ONE")

        let client = ScriptedModelClient([
            ChatResponse(
                message: .assistant(nil, toolCalls: [
                    ToolCall(id: "call_1", name: "read_file", arguments: #"{"path":"skill://pdf-tools/SKILL.md"}"#)
                ]),
                finishReason: "tool_calls"
            ),
            ChatResponse(message: .assistant("Read it."), finishReason: "stop")
        ])
        let runtime = makeRuntime(client: client)
        await runtime.loadInitialState()
        _ = runtime.attach()
        runtime.send(text: "follow the pdf skill")
        await waitUntil { await client.recordedRequests().count >= 2 }

        let requests = await client.recordedRequests()
        let toolMessage = try XCTUnwrap(requests[1].messages.last { $0.role == .tool })
        XCTAssertTrue(toolMessage.content?.contains("STEP ONE") == true, "tool result was: \(toolMessage.content ?? "nil")")
        XCTAssertTrue(toolMessage.content?.contains("description:") == true)
    }

    func testSkillCommandReadsAGlobalSkill() async throws {
        try writeGlobalSkill(name: "pdf-tools", description: "Extract text.", body: "STEP ONE")

        let client = ScriptedModelClient([
            ChatResponse(message: .assistant("Done."), finishReason: "stop")
        ])
        let runtime = makeRuntime(client: client)
        await runtime.loadInitialState()
        _ = runtime.attach()
        runtime.send(text: "/skill:pdf-tools extract report.pdf")
        await waitUntil { !(await client.recordedRequests().isEmpty) }

        let requests = await client.recordedRequests()
        let user = try XCTUnwrap(requests.first?.messages.first { $0.role == .user }?.content)
        XCTAssertTrue(user.contains(#"location="skill://pdf-tools/SKILL.md""#))
        XCTAssertTrue(user.contains("STEP ONE"))
        XCTAssertTrue(user.hasSuffix("extract report.pdf"))
    }

    /// Drops a skill where a user would: straight into the app's own directory.
    /// Nothing in the app writes this folder yet, so this is also the shape a
    /// Files.app import (or a simctl copy) has to produce.
    func testSkillDroppedIntoTheAppDirectoryIsDiscovered() async throws {
        try writeGlobalSkill(name: "dropped", description: "Landed on disk.", body: "BODY")

        let catalog = SkillCatalog.load(
            projectRoot: project.directory,
            userSkillsDirectory: environment.skillsDirectory
        )

        XCTAssertEqual(catalog.skills.map(\.name), ["dropped"])
        XCTAssertEqual(catalog.skills.first?.source, .user)
        XCTAssertTrue(catalog.issues.isEmpty)
    }

    /// The default path has to be real and writable on the device, not just a string.
    func testDefaultSkillsDirectoryLivesInTheContainerAndIsWritable() throws {
        let environment = AppEnvironment(
            settings: AppSettings(
                defaults: UserDefaults(suiteName: "pokeet-default-skills-\(UUID().uuidString)")!,
                secrets: MemorySecrets()
            ),
            projects: ProjectStore(documentsURL: root),
            sessions: SessionStore(directory: root.appendingPathComponent("Sessions", isDirectory: true)),
            git: SwiftGitXGitService(),
            scripting: .empty
        )
        let directory = environment.skillsDirectory
        defer {
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent("container-check", isDirectory: true)
            )
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(directory.path.contains("/Library/Application Support/Pokeet/Skills"))

        let skillDirectory = directory.appendingPathComponent("container-check", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        try """
        ---
        name: container-check
        description: Written by a test into the real container.
        ---

        BODY
        """.write(
            to: skillDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        let catalog = SkillCatalog.load(projectRoot: root, userSkillsDirectory: directory)
        XCTAssertEqual(catalog.skills.map(\.name), ["container-check"])
    }

    // MARK: - Helpers

    private func makeRuntime(client: any ModelClient) -> SessionRuntime {
        SessionRuntime(
            project: project,
            session: SessionMetadata(id: UUID(), title: "New chat"),
            environment: environment,
            client: client
        )
    }

    private func writeGlobalSkill(name: String, description: String, body: String) throws {
        let skillDirectory = skillsDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        try """
        ---
        name: \(name)
        description: \(description)
        ---

        \(body)
        """.write(
            to: skillDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for the run to settle", file: file, line: line)
    }
}
