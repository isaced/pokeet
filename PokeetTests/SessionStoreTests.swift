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

    func testRoundtrip() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SessionStore(directory: directory)
        let messages: [ChatMessage] = [
            .system("system"),
            .user("hi"),
            .assistant(nil, toolCalls: [
                ToolCall(id: "call_1", name: "read_file", arguments: "{}")
            ]),
            .tool("content", callID: "call_1"),
            .assistant("done")
        ]
        let bubbles = [
            StoredBubble(id: UUID(), role: "user", text: "hi"),
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

        await store.save(snapshot, projectName: "demo")

        let loaded = await store.load(projectName: "demo")
        XCTAssertEqual(loaded, snapshot)
        XCTAssertEqual(loaded?.restoredMessages, messages)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: store.fileURL(projectName: "demo").path
            )
        )
    }

    func testCorruptSnapshotReturnsNil() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SessionStore(directory: directory)
        let url = store.fileURL(projectName: "broken")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: url)

        let loaded = await store.load(projectName: "broken")
        XCTAssertNil(loaded)
    }

    func testUnknownVersionReturnsNil() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SessionStore(directory: directory)
        let url = store.fileURL(projectName: "future")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(#"{"version":2,"messages":[],"bubbles":[]}"#.utf8).write(to: url)

        let loaded = await store.load(projectName: "future")
        XCTAssertNil(loaded)
    }

    func testRemove() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SessionStore(directory: directory)
        let snapshot = SessionSnapshot(messages: [.system("system")], bubbles: [])
        await store.save(snapshot, projectName: "demo")
        await store.remove(projectName: "demo")

        let loaded = await store.load(projectName: "demo")
        XCTAssertNil(loaded)
    }
}
