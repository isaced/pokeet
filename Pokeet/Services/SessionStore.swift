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
    let images: [ChatImage]?

    init(_ message: ChatMessage) {
        role = message.role.rawValue
        content = message.content
        toolCalls = message.toolCalls?.map {
            StoredToolCall(id: $0.id, name: $0.name, arguments: $0.arguments)
        }
        toolCallID = message.toolCallID
        images = message.images
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
            toolCallID: toolCallID,
            images: images
        )
    }
}

struct StoredBubble: Codable, Sendable, Equatable {
    let id: UUID
    let role: String
    let text: String
    let images: [ChatImage]?
    let filePaths: [String]?

    init(
        id: UUID,
        role: String,
        text: String,
        images: [ChatImage]? = nil,
        filePaths: [String]? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.images = images
        self.filePaths = filePaths
    }
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

struct SessionMetadata: Codable, Sendable, Equatable, Hashable, Identifiable {
    let id: UUID
    var title: String
    var mode: AgentMode?
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String = "New chat",
        mode: AgentMode? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.mode = mode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

actor SessionStore {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    func list(projectName: String) -> [SessionMetadata] {
        readIndex(projectName: projectName)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func create(
        projectName: String,
        title: String = "New chat",
        mode: AgentMode? = nil,
        now: Date = Date()
    ) -> SessionMetadata {
        let metadata = SessionMetadata(title: title, mode: mode, createdAt: now, updatedAt: now)
        var index = readIndex(projectName: projectName)
        index.append(metadata)
        writeIndex(index, projectName: projectName)
        return metadata
    }

    func ensureSession(
        projectName: String,
        sessionID: UUID,
        title: String,
        mode: AgentMode? = nil,
        now: Date = Date()
    ) {
        var index = readIndex(projectName: projectName)
        if let position = index.firstIndex(where: { $0.id == sessionID }) {
            if let mode, index[position].mode != mode {
                index[position].mode = mode
                writeIndex(index, projectName: projectName)
            }
            return
        }

        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        index.append(SessionMetadata(
            id: sessionID,
            title: trimmed.isEmpty ? "New chat" : trimmed,
            mode: mode,
            createdAt: now,
            updatedAt: now
        ))
        writeIndex(index, projectName: projectName)
    }

    func load(projectName: String, sessionID: UUID) -> SessionSnapshot? {
        let url = sessionURL(projectName: projectName, sessionID: sessionID)
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(SessionSnapshot.self, from: data),
              snapshot.version == SessionSnapshot.currentVersion
        else {
            return nil
        }
        return snapshot
    }

    func save(
        _ snapshot: SessionSnapshot,
        projectName: String,
        sessionID: UUID,
        title: String,
        mode: AgentMode? = nil
    ) {
        let now = Date()
        let url = sessionURL(projectName: projectName, sessionID: sessionID)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            return
        }

        var index = readIndex(projectName: projectName)
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let indexPosition = index.firstIndex(where: { $0.id == sessionID }) {
            index[indexPosition].updatedAt = now
            if !trimmedTitle.isEmpty {
                index[indexPosition].title = trimmedTitle
            }
            if let mode {
                index[indexPosition].mode = mode
            }
        } else {
            index.append(SessionMetadata(
                id: sessionID,
                title: trimmedTitle.isEmpty ? "New chat" : trimmedTitle,
                mode: mode,
                createdAt: now,
                updatedAt: now
            ))
        }
        writeIndex(index, projectName: projectName)
    }

    func setMode(projectName: String, sessionID: UUID, mode: AgentMode) {
        var index = readIndex(projectName: projectName)
        guard let indexPosition = index.firstIndex(where: { $0.id == sessionID }),
              index[indexPosition].mode != mode
        else {
            return
        }
        index[indexPosition].mode = mode
        writeIndex(index, projectName: projectName)
    }

    @discardableResult
    func rename(
        projectName: String,
        sessionID: UUID,
        title: String
    ) -> SessionMetadata? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var index = readIndex(projectName: projectName)
        guard let indexPosition = index.firstIndex(where: { $0.id == sessionID }) else {
            return nil
        }
        index[indexPosition].title = trimmed
        writeIndex(index, projectName: projectName)
        return index[indexPosition]
    }

    func delete(projectName: String, sessionID: UUID) {
        let url = sessionURL(projectName: projectName, sessionID: sessionID)
        try? FileManager.default.removeItem(at: url)

        var index = readIndex(projectName: projectName)
        index.removeAll { $0.id == sessionID }
        writeIndex(index, projectName: projectName)
    }

    private func readIndex(projectName: String) -> [SessionMetadata] {
        let url = indexURL(projectName: projectName)
        guard let data = try? Data(contentsOf: url),
              let index = try? JSONDecoder().decode([SessionMetadata].self, from: data)
        else {
            return []
        }
        return index
    }

    private func writeIndex(_ index: [SessionMetadata], projectName: String) {
        let url = indexURL(projectName: projectName)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(index)
            try data.write(to: url, options: .atomic)
        } catch {
            // Session persistence is best-effort; the in-memory session keeps working.
        }
    }

    private func indexURL(projectName: String) -> URL {
        projectDirectory(projectName).appendingPathComponent("sessions.json", isDirectory: false)
    }

    private func sessionURL(projectName: String, sessionID: UUID) -> URL {
        projectDirectory(projectName)
            .appendingPathComponent("\(sessionID.uuidString).json", isDirectory: false)
    }

    private func projectDirectory(_ projectName: String) -> URL {
        var name = projectName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            name = "project"
        }
        return directory.appendingPathComponent(name, isDirectory: true)
    }
}
