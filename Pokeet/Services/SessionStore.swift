import Foundation
import PokeetCore

struct StoredToolCall: Codable, Sendable, Equatable {
    let id: String
    let name: String
    let arguments: String
}

struct StoredMessage: Codable, Sendable, Equatable {
    let role: String
    let content: String?
    let toolCalls: [StoredToolCall]?
    let toolCallID: String?

    init(_ message: ChatMessage) {
        role = message.role.rawValue
        content = message.content
        toolCalls = message.toolCalls?.map {
            StoredToolCall(id: $0.id, name: $0.name, arguments: $0.arguments)
        }
        toolCallID = message.toolCallID
    }

    var chatMessage: ChatMessage? {
        guard let role = ChatMessage.Role(rawValue: role) else { return nil }

        let calls = toolCalls?.map {
            ToolCall(id: $0.id, name: $0.name, arguments: $0.arguments)
        }
        return ChatMessage(
            role: role,
            content: content,
            toolCalls: calls,
            toolCallID: toolCallID
        )
    }
}

struct StoredBubble: Codable, Sendable, Equatable {
    let id: UUID
    let role: String
    let text: String
}

struct SessionSnapshot: Codable, Sendable, Equatable {
    static let currentVersion = 1

    let version: Int
    let messages: [StoredMessage]
    let bubbles: [StoredBubble]
    let cacheStats: CacheStats?

    init(
        messages: [ChatMessage],
        bubbles: [StoredBubble],
        cacheStats: CacheStats? = nil
    ) {
        version = Self.currentVersion
        self.messages = messages.map { StoredMessage($0) }
        self.bubbles = bubbles
        self.cacheStats = cacheStats
    }

    var restoredMessages: [ChatMessage] {
        messages.compactMap(\.chatMessage)
    }
}

struct SessionStore: Sendable {
    let directory: URL

    func fileURL(projectName: String) -> URL {
        directory.appendingPathComponent("\(projectName).json", isDirectory: false)
    }

    func load(projectName: String) async -> SessionSnapshot? {
        let url = fileURL(projectName: projectName)

        return await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url),
                  let snapshot = try? JSONDecoder().decode(SessionSnapshot.self, from: data),
                  snapshot.version == SessionSnapshot.currentVersion
            else {
                return nil
            }
            return snapshot
        }.value
    }

    func save(_ snapshot: SessionSnapshot, projectName: String) async {
        let url = fileURL(projectName: projectName)

        await Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                // Persistence is best-effort; the in-memory session keeps working.
            }
        }.value
    }

    func remove(projectName: String) async {
        let url = fileURL(projectName: projectName)
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: url)
        }.value
    }
}
