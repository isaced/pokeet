import CryptoKit
import Foundation
import PokeetCore

struct StoredToolCall: Codable, Sendable, Equatable {
    let id: String
    let name: String
    let arguments: String
}

struct StoredImageRef: Codable, Sendable, Equatable, Hashable {
    let id: String
    let mimeType: String
}

struct StoredMessage: Codable, Sendable, Equatable {
    let role: String
    let content: String?
    let toolCalls: [StoredToolCall]?
    let toolCallID: String?
    let images: [StoredImageRef]?

    init(
        role: String,
        content: String?,
        toolCalls: [StoredToolCall]? = nil,
        toolCallID: String? = nil,
        images: [StoredImageRef]? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.images = images
    }
}

struct StoredBubble: Codable, Sendable, Equatable {
    let id: UUID
    let role: String
    let text: String
    let images: [StoredImageRef]?
    let filePaths: [String]?
    let reasoningDuration: TimeInterval?
    let runDuration: TimeInterval?
    let preview: String?
    let output: String?

    init(
        id: UUID,
        role: String,
        text: String,
        images: [StoredImageRef]? = nil,
        filePaths: [String]? = nil,
        reasoningDuration: TimeInterval? = nil,
        runDuration: TimeInterval? = nil,
        preview: String? = nil,
        output: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.images = images
        self.filePaths = filePaths
        self.reasoningDuration = reasoningDuration
        self.runDuration = runDuration
        self.preview = preview
        self.output = output
    }
}

struct SessionBubble: Sendable, Equatable {
    let id: UUID
    let role: String
    let text: String
    let images: [ChatImage]
    let filePaths: [String]
    let reasoningDuration: TimeInterval?
    let runDuration: TimeInterval?
    let preview: String?
    let output: String?

    init(
        id: UUID,
        role: String,
        text: String,
        images: [ChatImage] = [],
        filePaths: [String] = [],
        reasoningDuration: TimeInterval? = nil,
        runDuration: TimeInterval? = nil,
        preview: String? = nil,
        output: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.images = images
        self.filePaths = filePaths
        self.reasoningDuration = reasoningDuration
        self.runDuration = runDuration
        self.preview = preview
        self.output = output
    }
}

struct SessionSnapshot: Sendable, Equatable {
    let bubbles: [SessionBubble]
    let cacheStats: CacheStats?
    let plan: AgentPlan?
    let planIsExecuting: Bool?
    let appliedChanges: [AppliedChange]?

    init(
        bubbles: [SessionBubble],
        cacheStats: CacheStats? = nil,
        plan: AgentPlan? = nil,
        planIsExecuting: Bool? = nil,
        appliedChanges: [AppliedChange]? = nil
    ) {
        self.bubbles = bubbles
        self.cacheStats = cacheStats
        self.plan = plan
        self.planIsExecuting = planIsExecuting
        self.appliedChanges = appliedChanges
    }
}

struct SessionHeader: Codable, Sendable, Equatable {
    static let currentVersion = 2

    let version: Int
    let bubbles: [StoredBubble]
    let cacheStats: CacheStats?
    let plan: AgentPlan?
    let planIsExecuting: Bool?
    let appliedChanges: [AppliedChange]?
    let updatedAt: Date?

    init(
        version: Int = SessionHeader.currentVersion,
        bubbles: [StoredBubble],
        cacheStats: CacheStats?,
        plan: AgentPlan? = nil,
        planIsExecuting: Bool? = nil,
        appliedChanges: [AppliedChange]? = nil,
        updatedAt: Date?
    ) {
        self.version = version
        self.bubbles = bubbles
        self.cacheStats = cacheStats
        self.plan = plan
        self.planIsExecuting = planIsExecuting
        self.appliedChanges = appliedChanges
        self.updatedAt = updatedAt
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

enum SnapshotImageStore {
    static func store(_ image: ChatImage, in directory: URL) throws -> StoredImageRef {
        let digest = SHA256.hash(data: image.data)
        let id = digest.map { String(format: "%02x", $0) }.joined()
        let url = directory.appendingPathComponent("\(id).img", isDirectory: false)
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try image.data.write(to: url, options: .atomic)
        }
        return StoredImageRef(id: id, mimeType: image.mimeType)
    }

    static func image(for ref: StoredImageRef, in directory: URL) -> ChatImage? {
        let url = directory.appendingPathComponent("\(ref.id).img", isDirectory: false)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return ChatImage(mimeType: ref.mimeType, data: data)
    }
}

enum SessionCompression {
    static func compress(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return Data() }
        return try (data as NSData).compressed(using: .zlib) as Data
    }

    static func decompress(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return Data() }
        return try (data as NSData).decompressed(using: .zlib) as Data
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
        let urls = sessionURLs(projectName: projectName, sessionID: sessionID)
        guard let raw = try? Data(contentsOf: urls.header),
              let data = try? SessionCompression.decompress(raw),
              let header = try? JSONDecoder().decode(SessionHeader.self, from: data),
              header.version == SessionHeader.currentVersion
        else {
            return nil
        }

        let bubbles = header.bubbles.map { stored in
            SessionBubble(
                id: stored.id,
                role: stored.role,
                text: stored.text,
                images: (stored.images ?? []).compactMap {
                    SnapshotImageStore.image(for: $0, in: urls.imagesDirectory)
                },
                filePaths: stored.filePaths ?? [],
                reasoningDuration: stored.reasoningDuration,
                runDuration: stored.runDuration,
                preview: stored.preview,
                output: stored.output
            )
        }
        return SessionSnapshot(
            bubbles: bubbles,
            cacheStats: header.cacheStats,
            plan: header.plan,
            planIsExecuting: header.planIsExecuting,
            appliedChanges: header.appliedChanges
        )
    }

    func loadMessages(projectName: String, sessionID: UUID) -> [ChatMessage]? {
        let urls = sessionURLs(projectName: projectName, sessionID: sessionID)
        guard FileManager.default.fileExists(atPath: urls.messages.path) else {
            return []
        }
        guard let raw = try? Data(contentsOf: urls.messages),
              let data = try? SessionCompression.decompress(raw),
              let stored = try? JSONDecoder().decode([StoredMessage].self, from: data)
        else {
            return nil
        }

        return stored.compactMap { message in
            guard let role = ChatMessage.Role(rawValue: message.role) else {
                return nil
            }
            let images = (message.images ?? []).compactMap {
                SnapshotImageStore.image(for: $0, in: urls.imagesDirectory)
            }
            let calls = message.toolCalls?.map {
                ToolCall(id: $0.id, name: $0.name, arguments: $0.arguments)
            }
            return ChatMessage(
                role: role,
                content: message.content,
                toolCalls: calls,
                toolCallID: message.toolCallID,
                images: images.isEmpty ? nil : images
            )
        }
    }

    func hasLegacySnapshot(projectName: String, sessionID: UUID) -> Bool {
        let urls = sessionURLs(projectName: projectName, sessionID: sessionID)
        return FileManager.default.fileExists(atPath: urls.legacy.path)
    }

    func save(
        _ snapshot: SessionSnapshot,
        messages: [ChatMessage],
        projectName: String,
        sessionID: UUID,
        title: String,
        mode: AgentMode? = nil
    ) {
        let now = Date()
        let urls = sessionURLs(projectName: projectName, sessionID: sessionID)
        do {
            try FileManager.default.createDirectory(
                at: urls.imagesDirectory,
                withIntermediateDirectories: true
            )
            let header = try makeHeader(
                from: snapshot,
                imagesDirectory: urls.imagesDirectory,
                now: now
            )
            try writeCompressed(header, to: urls.header)

            let storedMessages = try messages.map {
                try storedMessage($0, imagesDirectory: urls.imagesDirectory)
            }
            try writeCompressed(storedMessages, to: urls.messages)
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

    func saveCheckpoint(
        _ snapshot: SessionSnapshot,
        projectName: String,
        sessionID: UUID
    ) {
        let urls = sessionURLs(projectName: projectName, sessionID: sessionID)
        do {
            try FileManager.default.createDirectory(
                at: urls.imagesDirectory,
                withIntermediateDirectories: true
            )
            let header = try makeHeader(
                from: snapshot,
                imagesDirectory: urls.imagesDirectory,
                now: Date()
            )
            try writeCompressed(header, to: urls.header)
        } catch {
            return
        }
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
        let urls = sessionURLs(projectName: projectName, sessionID: sessionID)
        try? FileManager.default.removeItem(at: urls.directory)
        try? FileManager.default.removeItem(at: urls.legacy)

        var index = readIndex(projectName: projectName)
        index.removeAll { $0.id == sessionID }
        writeIndex(index, projectName: projectName)
    }

    func deleteProject(projectName: String) {
        guard !projectName.isEmpty else { return }
        try? FileManager.default.removeItem(at: projectDirectory(projectName))
    }

    private func makeHeader(
        from snapshot: SessionSnapshot,
        imagesDirectory: URL,
        now: Date
    ) throws -> SessionHeader {
        let bubbles = try snapshot.bubbles.map { bubble in
            let refs = try bubble.images.map {
                try SnapshotImageStore.store($0, in: imagesDirectory)
            }
            return StoredBubble(
                id: bubble.id,
                role: bubble.role,
                text: bubble.text,
                images: refs.isEmpty ? nil : refs,
                filePaths: bubble.filePaths.isEmpty ? nil : bubble.filePaths,
                reasoningDuration: bubble.reasoningDuration,
                runDuration: bubble.runDuration,
                preview: bubble.preview,
                output: bubble.output
            )
        }
        return SessionHeader(
            bubbles: bubbles,
            cacheStats: snapshot.cacheStats,
            plan: snapshot.plan,
            planIsExecuting: snapshot.planIsExecuting,
            appliedChanges: snapshot.appliedChanges,
            updatedAt: now
        )
    }

    private func storedMessage(
        _ message: ChatMessage,
        imagesDirectory: URL
    ) throws -> StoredMessage {
        let refs = try (message.images ?? []).map {
            try SnapshotImageStore.store($0, in: imagesDirectory)
        }
        return StoredMessage(
            role: message.role.rawValue,
            content: message.content,
            toolCalls: message.toolCalls?.map {
                StoredToolCall(id: $0.id, name: $0.name, arguments: $0.arguments)
            },
            toolCallID: message.toolCallID,
            images: refs.isEmpty ? nil : refs
        )
    }

    private func writeCompressed<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(value)
        let compressed = try SessionCompression.compress(data)
        try compressed.write(to: url, options: .atomic)
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

    private struct URLs {
        let directory: URL
        let header: URL
        let messages: URL
        let imagesDirectory: URL
        let legacy: URL
    }

    private func sessionURLs(projectName: String, sessionID: UUID) -> URLs {
        let projectDirectory = projectDirectory(projectName)
        let sessionDirectory = projectDirectory
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
        return URLs(
            directory: sessionDirectory,
            header: sessionDirectory.appendingPathComponent("header.json.z", isDirectory: false),
            messages: sessionDirectory.appendingPathComponent("messages.json.z", isDirectory: false),
            imagesDirectory: sessionDirectory.appendingPathComponent("images", isDirectory: true),
            legacy: projectDirectory
                .appendingPathComponent("\(sessionID.uuidString).json", isDirectory: false)
        )
    }

    private func indexURL(projectName: String) -> URL {
        projectDirectory(projectName).appendingPathComponent("sessions.json", isDirectory: false)
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
