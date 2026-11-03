import PokeetCore
import XCTest
@testable import Pokeet

final class SessionStoreTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pokeet-sessions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func sessionDirectory(
        root: URL,
        project: String,
        sessionID: UUID
    ) -> URL {
        root
            .appendingPathComponent(project, isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }

    func testRoundtripForOneSession() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SessionStore(directory: directory)
        let session = await store.create(projectName: "demo", title: "First task")

        let image = ChatImage(mimeType: "image/png", data: Data("img".utf8))
        let messages: [ChatMessage] = [
            .system("system"),
            .user("hi"),
            ChatMessage(role: .user, content: "look", images: [image]),
            .assistant(nil, toolCalls: [
                ToolCall(id: "call_1", name: "read_file", arguments: "{}")
            ]),
            .tool("content", callID: "call_1"),
            .assistant("done")
        ]
        let bubbles = [
            SessionBubble(id: UUID(), role: "user", text: "hi"),
            SessionBubble(
                id: UUID(),
                role: "user",
                text: "look",
                images: [image],
                filePaths: ["Sources/main.swift"]
            ),
            SessionBubble(id: UUID(), role: "reasoning", text: "thinking"),
            SessionBubble(id: UUID(), role: "assistant", text: "done")
        ]
        var cacheStats = CacheStats()
        cacheStats.record(ModelUsage(
            inputTokens: 100,
            outputTokens: 10,
            cachedInputTokens: 60
        ))
        let snapshot = SessionSnapshot(bubbles: bubbles, cacheStats: cacheStats)

        await store.save(
            snapshot,
            messages: messages,
            projectName: "demo",
            sessionID: session.id,
            title: "First task"
        )

        let loaded = await store.load(projectName: "demo", sessionID: session.id)
        XCTAssertEqual(loaded, snapshot)

        let loadedMessages = await store.loadMessages(projectName: "demo", sessionID: session.id)
        XCTAssertEqual(loadedMessages, messages)

        let listed = await store.list(projectName: "demo")
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.id, session.id)
        XCTAssertEqual(listed.first?.title, "First task")
    }

    func testPlanAndAuditRoundtrip() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SessionStore(directory: directory)
        let session = await store.create(projectName: "demo", title: "Plan")
        let plan = AgentPlan(
            title: "Ship it",
            summary: "Small change",
            steps: [AgentPlan.Step(title: "Edit README", files: ["README.md"])]
        )
        let change = AppliedChange(
            path: "README.md",
            kind: "update",
            didWrite: true,
            addedLines: 2,
            removedLines: 1,
            message: "Applied change to README.md"
        )
        let snapshot = SessionSnapshot(
            bubbles: [SessionBubble(id: UUID(), role: "assistant", text: "Plan")],
            plan: plan,
            planIsExecuting: true,
            appliedChanges: [change]
        )

        await store.save(
            snapshot,
            messages: [],
            projectName: "demo",
            sessionID: session.id,
            title: "Plan"
        )

        let loaded = await store.load(projectName: "demo", sessionID: session.id)
        XCTAssertEqual(loaded?.plan, plan)
        XCTAssertEqual(loaded?.planIsExecuting, true)
        XCTAssertEqual(loaded?.appliedChanges, [change])
    }

    func testImagesAreExternalizedAndDeduplicated() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SessionStore(directory: directory)
        let session = await store.create(projectName: "demo", title: "Images")
        let image = ChatImage(mimeType: "image/jpeg", data: Data("same-image".utf8))

        let snapshot = SessionSnapshot(bubbles: [
            SessionBubble(id: UUID(), role: "user", text: "one", images: [image]),
            SessionBubble(id: UUID(), role: "user", text: "two", images: [image])
        ])
        await store.save(
            snapshot,
            messages: [],
            projectName: "demo",
            sessionID: session.id,
            title: "Images"
        )

        let sessionDirectory = sessionDirectory(
            root: directory,
            project: "demo",
            sessionID: session.id
        )
        let imagesDirectory = sessionDirectory.appendingPathComponent("images")
        let files = try FileManager.default.contentsOfDirectory(
            at: imagesDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(files.filter { $0.pathExtension == "img" }.count, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: sessionDirectory.appendingPathComponent("header.json.z").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: sessionDirectory.appendingPathComponent("messages.json.z").path
            )
        )

        let loaded = await store.load(projectName: "demo", sessionID: session.id)
        XCTAssertEqual(loaded?.bubbles.last?.images, [image])
    }

    func testCheckpointKeepsMessages() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SessionStore(directory: directory)
        let session = await store.create(projectName: "demo", title: "Checkpoint")
        let messages: [ChatMessage] = [.user("hi"), .assistant("hello")]

        let first = SessionSnapshot(bubbles: [
            SessionBubble(id: UUID(), role: "user", text: "hi")
        ])
        await store.save(
            first,
            messages: messages,
            projectName: "demo",
            sessionID: session.id,
            title: "Checkpoint"
        )

        let checkpoint = SessionSnapshot(bubbles: [
            SessionBubble(id: UUID(), role: "user", text: "hi"),
            SessionBubble(id: UUID(), role: "assistant", text: "hello")
        ])
        await store.saveCheckpoint(
            checkpoint,
            projectName: "demo",
            sessionID: session.id
        )

        let loaded = await store.load(projectName: "demo", sessionID: session.id)
        XCTAssertEqual(loaded, checkpoint)
        let loadedMessages = await store.loadMessages(projectName: "demo", sessionID: session.id)
        XCTAssertEqual(loadedMessages, messages)
    }

    func testEnsureSessionCreatesOnlyOnce() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SessionStore(directory: directory)
        let id = UUID()

        await store.ensureSession(projectName: "demo", sessionID: id, title: "Draft")
        await store.ensureSession(projectName: "demo", sessionID: id, title: "Changed")

        let listed = await store.list(projectName: "demo")
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.id, id)
        XCTAssertEqual(listed.first?.title, "Draft")
    }

    func testListSortsByUpdatedAt() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SessionStore(directory: directory)
        let older = await store.create(
            projectName: "demo",
            title: "Older",
            now: Date(timeIntervalSince1970: 100)
        )
        let newer = await store.create(
            projectName: "demo",
            title: "Newer",
            now: Date(timeIntervalSince1970: 200)
        )

        let listed = await store.list(projectName: "demo")
        XCTAssertEqual(listed.map(\.id), [newer.id, older.id])
    }

    func testRenameAndDeleteSession() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SessionStore(directory: directory)
        let session = await store.create(projectName: "demo", title: "Old")

        let renamed = await store.rename(
            projectName: "demo",
            sessionID: session.id,
            title: "  New title  "
        )
        XCTAssertEqual(renamed?.title, "New title")

        await store.delete(projectName: "demo", sessionID: session.id)

        let remaining = await store.list(projectName: "demo")
        let loaded = await store.load(projectName: "demo", sessionID: session.id)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertNil(loaded)
    }

    func testDeleteRemovesSessionDirectory() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SessionStore(directory: directory)
        let session = await store.create(projectName: "demo", title: "Delete")
        await store.save(
            SessionSnapshot(bubbles: [SessionBubble(id: UUID(), role: "user", text: "hi")]),
            messages: [],
            projectName: "demo",
            sessionID: session.id,
            title: "Delete"
        )

        let sessionDirectory = sessionDirectory(
            root: directory,
            project: "demo",
            sessionID: session.id
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionDirectory.path))

        await store.delete(projectName: "demo", sessionID: session.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDirectory.path))
    }

    func testSessionsAreScopedToProject() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SessionStore(directory: directory)
        let first = await store.create(projectName: "one", title: "One")
        let second = await store.create(projectName: "two", title: "Two")

        let firstList = await store.list(projectName: "one")
        let secondList = await store.list(projectName: "two")
        XCTAssertEqual(firstList.map(\.id), [first.id])
        XCTAssertEqual(secondList.map(\.id), [second.id])
    }

    func testCorruptIndexReturnsEmptyList() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SessionStore(directory: directory)
        let projectDirectory = directory.appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectDirectory,
            withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(
            to: projectDirectory.appendingPathComponent("sessions.json")
        )

        let listed = await store.list(projectName: "broken")
        XCTAssertTrue(listed.isEmpty)
    }

    func testUnknownSnapshotVersionReturnsNil() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SessionStore(directory: directory)
        let session = await store.create(projectName: "future")
        let sessionDirectory = sessionDirectory(
            root: directory,
            project: "future",
            sessionID: session.id
        )
        try FileManager.default.createDirectory(
            at: sessionDirectory,
            withIntermediateDirectories: true
        )

        let header = SessionHeader(version: 3, bubbles: [], cacheStats: nil, updatedAt: nil)
        let data = try JSONEncoder().encode(header)
        let compressed = try SessionCompression.compress(data)
        try compressed.write(to: sessionDirectory.appendingPathComponent("header.json.z"))

        let loaded = await store.load(projectName: "future", sessionID: session.id)
        XCTAssertNil(loaded)
    }

    func testLegacySnapshotIsNotLoaded() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SessionStore(directory: directory)
        let session = await store.create(projectName: "legacy", title: "Old")
        let projectDirectory = directory.appendingPathComponent("legacy", isDirectory: true)
        try Data(#"{"version":1,"messages":[],"bubbles":[]}"#.utf8).write(
            to: projectDirectory.appendingPathComponent("\(session.id.uuidString).json")
        )

        let loaded = await store.load(projectName: "legacy", sessionID: session.id)
        let hasLegacy = await store.hasLegacySnapshot(projectName: "legacy", sessionID: session.id)
        XCTAssertNil(loaded)
        XCTAssertTrue(hasLegacy)
    }

    func testSessionModeRoundtripAndSetMode() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SessionStore(directory: directory)
        let session = await store.create(projectName: "modes", title: "Plan", mode: .plan)

        let listed = await store.list(projectName: "modes")
        XCTAssertEqual(listed.first(where: { $0.id == session.id })?.mode, .plan)

        await store.setMode(projectName: "modes", sessionID: session.id, mode: .auto)
        let updated = await store.list(projectName: "modes")
        XCTAssertEqual(updated.first(where: { $0.id == session.id })?.mode, .auto)
    }

    func testSaveUpdatesSessionMode() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SessionStore(directory: directory)
        let session = await store.create(projectName: "modes", title: "Mode", mode: .ask)

        await store.save(
            SessionSnapshot(bubbles: []),
            messages: [],
            projectName: "modes",
            sessionID: session.id,
            title: "Mode",
            mode: .bypass
        )

        let listed = await store.list(projectName: "modes")
        XCTAssertEqual(listed.first(where: { $0.id == session.id })?.mode, .bypass)
    }

    func testLegacySessionIndexWithoutModeDecodes() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SessionStore(directory: directory)
        let projectDirectory = directory.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectDirectory,
            withIntermediateDirectories: true
        )

        let metadata = SessionMetadata(title: "Old chat")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode([metadata])) as? [[String: Any]]
        )
        object[0].removeValue(forKey: "mode")
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: projectDirectory.appendingPathComponent("sessions.json"))

        let listed = await store.list(projectName: "legacy")
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.title, "Old chat")
        XCTAssertNil(listed.first?.mode)
    }
}
