import PokeetCore
import XCTest
@testable import Pokeet

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

/// Streams a fixed answer slowly enough that a test can leave the screen mid-flight.
private struct StubModelClient: ModelClient {
    let answer: String
    let chunks: Int
    let delay: Duration?

    init(answer: String, chunks: Int = 1, delay: Duration? = nil) {
        self.answer = answer
        self.chunks = max(1, chunks)
        self.delay = delay
    }

    func complete(_ request: ChatRequest) async throws -> ChatResponse {
        if let delay {
            try await Task.sleep(for: delay)
        }
        return ChatResponse(message: .assistant(answer), finishReason: "stop")
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let pieces = answer.count / chunks
                    if pieces > 0 {
                        var index = answer.startIndex
                        for _ in 0..<(chunks - 1) {
                            let end = answer.index(index, offsetBy: pieces)
                            continuation.yield(.textDelta(String(answer[index..<end])))
                            index = end
                            if let delay { try await Task.sleep(for: delay) }
                        }
                        continuation.yield(.textDelta(String(answer[index...])))
                    } else {
                        continuation.yield(.textDelta(answer))
                    }
                    continuation.yield(.completed(ChatResponse(
                        message: .assistant(answer),
                        finishReason: "stop"
                    )))
                    continuation.finish()
                } catch {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Records what the agent actually sent, so wiring tests can assert on the prompt.
/// Only `complete` is implemented; the protocol's default `stream` wraps it.
private actor RecordingModelClient: ModelClient {
    private(set) var requests: [ChatRequest] = []

    func complete(_ request: ChatRequest) async throws -> ChatResponse {
        requests.append(request)
        return ChatResponse(message: .assistant("Done."), finishReason: "stop")
    }

    func recordedRequests() -> [ChatRequest] {
        requests
    }
}

@MainActor
final class SessionRuntimeTests: XCTestCase {
    private var root: URL!
    private var environment: AppEnvironment!
    private var project: Project!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pokeet-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let projectDirectory = root.appendingPathComponent("Demo", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        project = Project(directory: projectDirectory, remoteHost: nil, isGitRepository: false)

        let defaults = UserDefaults(suiteName: "pokeet-runtime-\(UUID().uuidString)")!
        environment = AppEnvironment(
            settings: AppSettings(defaults: defaults, secrets: MemorySecrets()),
            projects: ProjectStore(documentsURL: root),
            sessions: SessionStore(directory: root.appendingPathComponent("Sessions", isDirectory: true)),
            git: SwiftGitXGitService(),
            scripting: .empty
        )
    }

    override func tearDown() async throws {
        environment = nil
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try await super.tearDown()
    }

    private func makeRuntime(
        sessionID: UUID = UUID(),
        client: any ModelClient
    ) -> SessionRuntime {
        SessionRuntime(
            project: project,
            session: SessionMetadata(id: sessionID, title: "New chat"),
            environment: environment,
            client: client
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

    func testRegistryKeepsOneRuntimePerSession() {
        let session = SessionMetadata()
        let first = environment.runs.runtime(
            for: project,
            session: session,
            environment: environment
        )
        let second = environment.runs.runtime(
            for: project,
            session: session,
            environment: environment
        )
        XCTAssertTrue(first === second)
        XCTAssertTrue(environment.runs.existing(for: project, sessionID: session.id) === first)
    }

    /// The point of the registry: dropping the screen must not drop the run or its transcript.
    func testRunContinuesWhileDetached() async {
        let runtime = makeRuntime(client: StubModelClient(
            answer: "Rendered three diffs and committed them.",
            chunks: 4,
            delay: .milliseconds(60)
        ))
        await runtime.loadInitialState()

        let attachment = runtime.attach()
        XCTAssertTrue(runtime.send(text: "Fix the parser"))
        XCTAssertTrue(runtime.isRunning)

        runtime.detach(attachment)
        XCTAssertTrue(runtime.isDetached)
        XCTAssertTrue(runtime.isRunning, "Detaching must not cancel the run")

        await waitUntil { !runtime.isRunning }

        XCTAssertNil(runtime.errorMessage)
        XCTAssertTrue(runtime.bubbles.contains { $0.role == .user && $0.text == "Fix the parser" })
        XCTAssertTrue(runtime.bubbles.contains {
            $0.role == .assistant && $0.text.contains("Rendered three diffs")
        })

        // Re-attaching shows the same transcript, not a fresh one.
        _ = runtime.attach()
        XCTAssertEqual(runtime.bubbles.first?.text, "Fix the parser")
    }

    func testFinishedRunIsNotMarkedInFlight() async {
        let sessionID = UUID()
        let runtime = makeRuntime(sessionID: sessionID, client: StubModelClient(answer: "Done."))
        await runtime.loadInitialState()
        _ = runtime.attach()
        runtime.send(text: "Hello")
        await waitUntil { !runtime.isRunning }

        let snapshot = await environment.sessions.load(
            projectName: project.name,
            sessionID: sessionID
        )
        XCTAssertEqual(snapshot?.runInFlight, false)
    }

    func testInterruptedHeaderOffersContinuation() async throws {
        let sessionID = UUID()
        let store = environment.sessions
        await store.save(
            SessionSnapshot(
                bubbles: [
                    SessionBubble(id: UUID(), role: "user", text: "Ship it"),
                    SessionBubble(id: UUID(), role: "assistant", text: "Halfway")
                ],
                runInFlight: true
            ),
            messages: [.user("Ship it")],
            projectName: project.name,
            sessionID: sessionID,
            title: "Ship it"
        )

        let runtime = makeRuntime(sessionID: sessionID, client: StubModelClient(answer: "Resumed."))
        await runtime.loadInitialState()
        _ = runtime.attach()

        XCTAssertTrue(runtime.needsContinuation)
        XCTAssertEqual(runtime.bubbles.count, 2)

        XCTAssertTrue(runtime.resume())
        await waitUntil { !runtime.isRunning }

        XCTAssertFalse(runtime.needsContinuation)
        XCTAssertTrue(runtime.bubbles.contains { $0.text.contains("Resumed.") })
    }

    func testDismissContinuationClearsTheFlagOnDisk() async {
        let sessionID = UUID()
        let store = environment.sessions
        await store.save(
            SessionSnapshot(
                bubbles: [SessionBubble(id: UUID(), role: "user", text: "Ship it")],
                runInFlight: true
            ),
            messages: [.user("Ship it")],
            projectName: project.name,
            sessionID: sessionID,
            title: "Ship it"
        )

        let runtime = makeRuntime(sessionID: sessionID, client: StubModelClient(answer: "Done."))
        await runtime.loadInitialState()
        _ = runtime.attach()
        XCTAssertTrue(runtime.needsContinuation)

        runtime.dismissContinuation()
        await waitUntil {
            let snapshot = await store.load(projectName: self.project.name, sessionID: sessionID)
            return snapshot?.runInFlight == false
        }
    }

    /// A cold start needs to flag the interruption from the index alone, without opening
    /// (and loading the history of) every conversation.
    func testRunningSessionIsFlaggedInTheIndex() async {
        let sessionID = UUID()
        let runtime = makeRuntime(sessionID: sessionID, client: StubModelClient(
            answer: "A long answer that keeps the run alive.",
            chunks: 6,
            delay: .milliseconds(80)
        ))
        await runtime.loadInitialState()
        _ = runtime.attach()
        runtime.send(text: "Work on it")
        await waitUntil {
            let list = await self.environment.sessions.list(projectName: self.project.name)
            return list.first(where: { $0.id == sessionID })?.runInFlight == true
        }

        runtime.stop()
        await waitUntil { !runtime.isRunning }
        await waitUntil {
            let list = await self.environment.sessions.list(projectName: self.project.name)
            return list.first(where: { $0.id == sessionID })?.runInFlight == false
        }
    }

    func testStopEndsTheRunWithoutContinuation() async {
        let runtime = makeRuntime(client: StubModelClient(
            answer: "One more paragraph of text.",
            chunks: 8,
            delay: .milliseconds(40)
        ))
        await runtime.loadInitialState()
        _ = runtime.attach()
        runtime.send(text: "Keep going")
        await waitUntil { runtime.bubbles.count > 1 }

        runtime.stop()
        await waitUntil { !runtime.isRunning }

        XCTAssertFalse(runtime.needsContinuation)
        XCTAssertNil(runtime.errorMessage)
        XCTAssertFalse(runtime.isAwaitingApproval)
    }

    /// The project's `.agents/skills` directory has to reach the real session: the
    /// catalog tests prove discovery, this proves the wiring.
    func testProjectSkillsReachTheSession() async throws {
        let skillDirectory = project.directory.appendingPathComponent(
            ".agents/skills/pdf-tools",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        try """
        ---
        name: pdf-tools
        description: Extract text from PDFs.
        ---

        STEP ONE
        """.write(
            to: skillDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        let client = RecordingModelClient()
        let runtime = makeRuntime(client: client)
        await runtime.loadInitialState()
        _ = runtime.attach()
        runtime.send(text: "/skill:pdf-tools extract report.pdf")
        await waitUntil { !(await client.recordedRequests().isEmpty) }

        let requests = await client.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        let system = request.messages.first?.content ?? ""
        XCTAssertTrue(system.contains("<name>pdf-tools</name>"))
        let user = try XCTUnwrap(request.messages.first { $0.role == .user }?.content)
        XCTAssertTrue(user.contains("STEP ONE"))
        XCTAssertTrue(user.hasSuffix("extract report.pdf"))
    }
}
