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
            StoredBubble(id: UUID(), role: "user", text: "hi"),
            StoredBubble(
                id: UUID(),
                role: "user",
                text: "look",
                images: [image],
                filePaths: ["Sources/main.swift"]
            ),
            StoredBubble(id: UUID(), role: "reasoning", text: "thinking"),
            StoredBubble(id: UUID(), role: "assistant", text: "done")
        ]
        var cacheStats = CacheStats()
        cacheStats.record(ModelUsage(
            inputTokens: 100,
            outputTokens: 10,
            cachedInputTokens: 60
        ))
        let snapshot = SessionSnapshot(
            messages: messages,
            bubbles: bubbles,
            cacheStats: cacheStats
        )

        await store.save(
            snapshot,
            projectName: "demo",
            sessionID: session.id,
            title: "First task"
        )

        let loaded = await store.load(projectName: "demo", sessionID: session.id)
        XCTAssertEqual(loaded, snapshot)
        XCTAssertEqual(loaded?.restoredMessages, messages)

        let listed = await store.list(projectName: "demo")
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.id, session.id)
        XCTAssertEqual(listed.first?.title, "First task")
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
        let projectDirectory = directory.appendingPathComponent("future", isDirectory: true)
        try Data(#"{"version":2,"messages":[],"bubbles":[]}"#.utf8).write(
            to: projectDirectory.appendingPathComponent("\(session.id.uuidString).json")
        )

        let loaded = await store.load(projectName: "future", sessionID: session.id)
        XCTAssertNil(loaded)
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
            SessionSnapshot(messages: [], bubbles: []),
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
